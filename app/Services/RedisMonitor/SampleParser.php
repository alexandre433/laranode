<?php

namespace App\Services\RedisMonitor;

/** Raw remote output -> samples. A sample is one row: the shape the DS collector writes, plus `cs` (command => calls). */
final class SampleParser
{
    public const KEEP_COMMANDS = 25;

    /**
     * LIVE output ("#ts <epoch>", "#<port>", INFO lines) -> [port => sample]
     *
     * @return array<int, array<string, mixed>>
     */
    public static function parseLive(string $out): array
    {
        $res = [];
        $ts = null;
        $cur = null;
        $kv = [];
        $flush = function () use (&$res, &$cur, &$kv, &$ts) {
            if ($cur !== null && isset($kv['uptime_in_seconds']) && $ts !== null) {
                $keys = 0;
                $dbs = [];
                $cs = [];
                foreach ($kv as $k => $v) {
                    if (preg_match('/^db(\d+)$/', $k, $m)) {
                        preg_match('/keys=(\d+)/', $v, $n);
                        $dbs[$m[1]] = (int) ($n[1] ?? 0);
                        $keys += $dbs[$m[1]];
                    } elseif (str_starts_with($k, 'cmdstat_')) {
                        preg_match('/calls=(\d+)/', $v, $n);
                        $cs[strtolower(substr($k, 8))] = (int) ($n[1] ?? 0);
                    }
                }
                arsort($cs);
                $num = fn (string $k) => (int) ($kv[$k] ?? 0);
                $res[$cur] = [
                    'ts' => (int) floor($ts), 'port' => $cur, 'ver' => (string) ($kv['redis_version'] ?? ''),
                    'up' => $num('uptime_in_seconds'), 'ops' => $num('instantaneous_ops_per_sec'),
                    'cmds' => $num('total_commands_processed'), 'hits' => $num('keyspace_hits'), 'miss' => $num('keyspace_misses'),
                    'mem' => $num('used_memory'), 'max' => $num('maxmemory'),
                    'rx' => $num('total_net_input_bytes'), 'tx' => $num('total_net_output_bytes'),
                    'cli' => $num('connected_clients'), 'blk' => $num('blocked_clients'), 'ev' => $num('evicted_keys'),
                    'keys' => $keys, 'dbs' => $dbs, 'cs' => array_slice($cs, 0, self::KEEP_COMMANDS, true),
                ];
            }
            $kv = [];
        };
        foreach (preg_split('/\r?\n/', $out) as $l) {
            if (preg_match('/^#ts ([\d.]+)/', $l, $m)) {
                $ts = (float) $m[1];

                continue;
            }
            if (preg_match('/^#(\d+)$/', $l, $m)) {
                $flush();
                $cur = (int) $m[1];

                continue;
            }
            $i = strpos($l, ':');
            if ($cur !== null && $i > 0) {
                $kv[substr($l, 0, $i)] = trim(substr($l, $i + 1));
            }
        }
        $flush();

        return $res;
    }

    /** jsonl text -> rows sorted by ts, duplicates dropped, torn lines ignored. */
    public static function parseJsonl(string $text): array
    {
        $rows = [];
        foreach (preg_split('/\r?\n/', $text) as $l) {
            if (! str_starts_with($l, '{')) {
                continue;
            }
            $r = json_decode($l, true);
            if (is_array($r) && isset($r['ts'], $r['cmds']) && is_numeric($r['ts']) && is_numeric($r['cmds'])) {
                $rows[(int) $r['ts']] = $r;
            }
        }
        ksort($rows);

        return array_values($rows);
    }

    /** PULL output ("#<port>" then jsonl lines) -> [port => rows] */
    public static function parsePull(string $out): array
    {
        $res = [];
        $cur = null;
        foreach (preg_split('/\r?\n/', $out) as $l) {
            if (preg_match('/^#(\d+)$/', $l, $m)) {
                $cur = (int) $m[1];
                $res[$cur] = '';

                continue;
            }
            if ($cur !== null && str_starts_with($l, '{')) {
                $res[$cur] .= $l."\n";
            }
        }

        return array_map(fn ($t) => self::parseJsonl($t), $res);
    }
}
