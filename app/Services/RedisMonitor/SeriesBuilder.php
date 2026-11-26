<?php

namespace App\Services\RedisMonitor;

/**
 * Samples -> graph series (throughput ops/s, hit/miss, storage, bandwidth, keys, clients) and the top-commands table.
 * Counters (cmds, hits, miss, rx, tx) only grow until the instance restarts: a pair of samples where a counter dropped,
 * uptime dropped, or the gap is longer than MAX_GAP contributes NO delta (a restart or a collector outage is a hole,
 * never a negative number or a spike).
 */
final class SeriesBuilder
{
    /** window => [span seconds, bucket seconds] */
    public const WINDOWS = ['live' => [900, 5], '1h' => [3600, 120], '6h' => [21600, 180], '1d' => [86400, 300], '7d' => [604800, 1800]];

    public const MAX_GAP = 300;

    public const KEEP = 8 * 86400;

    public static function window(?string $w): string
    {
        return isset(self::WINDOWS[$w]) ? $w : '1d';
    }

    /** Old rows out, new rows in (by ts), only the last KEEP seconds. */
    public static function merge(array $old, array $add, int $now): array
    {
        $m = [];
        foreach ([...$old, ...$add] as $r) {
            $m[(int) $r['ts']] = $r;
        }
        ksort($m);

        return array_values(array_filter($m, fn ($r) => $r['ts'] >= $now - self::KEEP));
    }

    public static function build(array $rows, int $now, string $window = '1d'): array
    {
        $window = self::window($window);
        [$span, $bucket] = self::WINDOWS[$window];
        $start = intdiv($now - $span, $bucket) * $bucket;
        $n = (int) ceil(($now - $start) / $bucket);
        $b = [];
        for ($i = 0; $i < $n; $i++) {
            $b[$i] = ['t' => $start + $i * $bucket, 'secs' => 0, 'cmds' => 0, 'hits' => 0, 'miss' => 0, 'rx' => 0, 'tx' => 0, 'mem' => null, 'max' => null, 'keys' => null, 'cli' => null, 'has' => false];
        }
        $restarts = 0;
        $inWindow = [];
        foreach ($rows as $i => $r) {
            $t = (int) $r['ts'];
            if ($t < $start || $t > $now) {
                continue;
            }
            $inWindow[] = $r;
            $k = min($n - 1, intdiv($t - $start, $bucket));
            $b[$k]['has'] = true;
            $b[$k]['mem'] = $r['mem'] ?? null;
            $b[$k]['max'] = $r['max'] ?? null;
            $b[$k]['keys'] = $r['keys'] ?? null;
            $b[$k]['cli'] = $r['cli'] ?? null;
            $p = $rows[$i - 1] ?? null;
            if (! $p) {
                continue;
            }
            $dt = $r['ts'] - $p['ts'];
            if ($r['cmds'] < $p['cmds'] || $r['up'] < $p['up'] || $r['tx'] < $p['tx'] || $r['rx'] < $p['rx'] || $r['hits'] < $p['hits']) {
                $restarts++;

                continue;
            }
            if ($dt <= 0 || $dt > self::MAX_GAP) {
                continue;
            }
            $b[$k]['secs'] += $dt;
            foreach (['cmds', 'hits', 'miss', 'rx', 'tx'] as $f) {
                $b[$k][$f] += $r[$f] - $p[$f];
            }
        }
        $series = array_map(fn ($x) => [
            't' => $x['t'],
            'ops' => $x['secs'] ? $x['cmds'] / $x['secs'] : null,
            'hits' => $x['secs'] ? $x['hits'] : null, 'miss' => $x['secs'] ? $x['miss'] : null,
            'mem' => $x['mem'], 'max' => $x['max'],
            'rx' => $x['secs'] ? $x['rx'] : null, 'tx' => $x['secs'] ? $x['tx'] : null,
            'bytes' => $x['secs'] ? $x['rx'] + $x['tx'] : null,
            'keys' => $x['keys'], 'cli' => $x['cli'],
        ], $b);
        $sum = fn (string $k) => array_sum(array_column($b, $k));
        $secs = $sum('secs');
        $last = $rows ? $rows[array_key_last($rows)] : null;
        $age = $last ? $now - (int) $last['ts'] : null;
        $hits = $sum('hits');
        $miss = $sum('miss');
        $live = array_filter($b, fn ($x) => $x['has']);

        return [
            'window' => $window, 'start' => $start, 'end' => $now, 'bucket' => $bucket, 'series' => $series,
            'summary' => [
                'samples' => count($inWindow),
                'opsAvg' => $secs ? $sum('cmds') / $secs : null,
                'opsPeak' => max([0, ...array_map(fn ($s) => $s['ops'] ?? 0, $series)]),
                'hits' => $hits, 'miss' => $miss, 'hitRate' => ($hits + $miss) > 0 ? $hits / ($hits + $miss) : null,
                'rx' => $sum('rx'), 'tx' => $sum('tx'), 'bytes' => $sum('rx') + $sum('tx'),
                'memNow' => $last['mem'] ?? null, 'maxNow' => $last['max'] ?? null,
                'memPeak' => max([0, ...array_map(fn ($x) => $x['mem'] ?? 0, $live)]),
                'memPct' => $last && ($last['max'] ?? 0) > 0 ? $last['mem'] / $last['max'] : null,
                'keysNow' => $last['keys'] ?? null, 'cliNow' => $last['cli'] ?? null,
                'blockedNow' => $last['blk'] ?? null, 'evictedNow' => $last['ev'] ?? null,
                'version' => $last['ver'] ?? null, 'uptimeSec' => $last['up'] ?? null,
                'restarts' => $restarts, 'ageSec' => $age, 'stale' => $age === null || $age > 3 * self::MAX_GAP,
            ],
            'dbs' => $last['dbs'] ?? new \stdClass,
            'topCommands' => self::topCommands($inWindow, $last),
        ];
    }

    /**
     * Top commands: lifetime calls from the newest sample that has them, and calls/s over the window when two samples with
     * counters bracket it without a restart in between. Sorted by rate when known, else by calls.
     */
    public static function topCommands(array $inWindow, ?array $last, int $limit = 10): array
    {
        $withCs = array_values(array_filter($inWindow, fn ($r) => ! empty($r['cs'])));
        if (! $withCs) {
            return [];
        }
        $new = $withCs[array_key_last($withCs)];
        $old = $withCs[0];
        $dt = $new['ts'] - $old['ts'];
        $ok = $dt > 0 && $new['up'] >= $old['up'] && $new['cmds'] >= $old['cmds'];
        $total = max(1, array_sum($new['cs']));
        $out = [];
        foreach ($new['cs'] as $cmd => $calls) {
            $rate = null;
            if ($ok && $calls >= ($old['cs'][$cmd] ?? 0)) {
                $rate = ($calls - ($old['cs'][$cmd] ?? 0)) / $dt;
            }
            $out[] = ['cmd' => $cmd, 'calls' => $calls, 'rate' => $rate, 'share' => $calls / $total];
        }
        usort($out, fn ($a, $b) => [$b['rate'] ?? -1, $b['calls']] <=> [$a['rate'] ?? -1, $a['calls']]);

        return array_slice($out, 0, $limit);
    }
}
