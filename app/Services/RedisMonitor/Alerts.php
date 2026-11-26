<?php

namespace App\Services\RedisMonitor;

/**
 * Storage warnings: used_memory / maxmemory crossing 50, 75, 80, 90, 95 %. Fires ONCE per instance per upward crossing
 * (a jump over several lines fires only the highest). Re-arms after usage falls REARM points below the line that fired.
 * maxmemory 0 = no limit = no alert.
 */
final class Alerts
{
    public const THRESHOLDS = [50, 75, 80, 90, 95];

    public const REARM = 5;

    public const ACTIVE_SECS = 86400;

    public static function highest(float $pct): int
    {
        $h = 0;
        foreach (self::THRESHOLDS as $t) {
            if ($pct >= $t) {
                $h = $t;
            }
        }

        return $h;
    }

    /**
     * @param  array<int, array{port:int, mem:int, max:int}>  $instances  newest sample each
     * @return array{0: array, 1: list<array>} [new state, fired events]
     */
    public static function evaluate(array $state, array $instances, int $now): array
    {
        $next = $state;
        $fired = [];
        foreach ($instances as $i) {
            if (($i['max'] ?? 0) <= 0) {
                continue;
            }
            $pct = $i['mem'] / $i['max'] * 100;
            $cur = self::highest($pct);
            $level = $state[$i['port']]['level'] ?? 0;
            if ($cur > $level) {
                $fired[] = ['id' => "{$i['port']}-{$cur}-{$now}", 'port' => $i['port'], 'threshold' => $cur, 'pct' => $pct, 'at' => $now];
                $next[$i['port']] = ['level' => $cur];
            } elseif ($cur < $level && $pct < $level - self::REARM) {
                $next[$i['port']] = ['level' => $cur];
            } elseif (! isset($next[$i['port']])) {
                $next[$i['port']] = ['level' => $level];
            }
        }

        return [$next, $fired];
    }

    /** Events of the last 24 h, newest per instance, newest first. */
    public static function active(array $events, int $now): array
    {
        $latest = [];
        foreach ($events as $e) {
            if ($now - $e['at'] <= self::ACTIVE_SECS && (! isset($latest[$e['port']]) || $e['at'] >= $latest[$e['port']]['at'])) {
                $latest[$e['port']] = $e;
            }
        }
        usort($latest, fn ($a, $b) => $b['at'] <=> $a['at']);

        return $latest;
    }
}
