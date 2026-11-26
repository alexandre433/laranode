<?php

namespace App\Services\RedisMonitor;

use App\Services\RedisMonitor\Transport\FixtureTransport;
use App\Services\RedisMonitor\Transport\LocalTransport;
use App\Services\RedisMonitor\Transport\SshTransport;
use App\Services\RedisMonitor\Transport\Transport;

/**
 * Orchestrates polling and storage. Everything the web request reads lives in files under `dir`:
 *   <port>.jsonl      history (collector rows pulled from the box + one own sample per pull)
 *   live-<port>.json  last 16 min of 5 s samples, only filled while a page watches the Live window
 *   watch             touched by the page; the scheduler tick polls every 5 s while it is fresh
 *   status.json, alerts.json, alerts-state.json
 * The web process never talks to the remote box: only the scheduler (user laranode_ln, which owns the ssh key) does.
 */
class RedisMonitor
{
    public const LIVE_KEEP = 960;

    public const WATCH_FRESH = 90;

    public const PULL_EVERY = 270;

    public function __construct(private ?Transport $transport = null, private ?string $dir = null) {}

    public function dir(): string
    {
        $d = $this->dir ?? storage_path('app/redis-monitor');
        if (! is_dir($d)) {
            @mkdir($d, 0775, true);
        }

        return $d;
    }

    /** @return array<int, array{label:string, tls:bool}> */
    public function instances(): array
    {
        return config('redis_monitor.instances');
    }

    public function transport(): Transport
    {
        if ($this->transport) {
            return $this->transport;
        }

        return $this->transport = match (config('redis_monitor.transport')) {
            'local' => new LocalTransport(config('redis_monitor.local')),
            'fixture' => new FixtureTransport((string) config('redis_monitor.fixture_dir')),
            default => new SshTransport(config('redis_monitor.ssh')),
        };
    }

    // ---- storage -------------------------------------------------------------------------------------------------

    private function path(string $name): string
    {
        return $this->dir().'/'.$name;
    }

    private function writeAtomic(string $name, string $data): void
    {
        $tmp = $this->path($name.'.tmp'.getmypid());
        file_put_contents($tmp, $data);
        @chmod($tmp, 0664);
        rename($tmp, $this->path($name));
    }

    private function readJson(string $name, mixed $default): mixed
    {
        $t = @file_get_contents($this->path($name));
        $v = $t === false ? null : json_decode($t, true);

        return $v ?? $default;
    }

    public function rows(int $port): array
    {
        return SampleParser::parseJsonl((string) @file_get_contents($this->path("$port.jsonl")));
    }

    private function writeRows(int $port, array $rows): void
    {
        $this->writeAtomic("$port.jsonl", implode("\n", array_map('json_encode', $rows))."\n");
    }

    public function liveRows(int $port): array
    {
        return $this->readJson("live-$port.json", []);
    }

    public function status(): ?array
    {
        return $this->readJson('status.json', null);
    }

    public function alerts(int $now): array
    {
        return Alerts::active($this->readJson('alerts.json', []), $now);
    }

    // ---- watch flag (web) ----------------------------------------------------------------------------------------

    public function touchWatch(): void
    {
        @touch($this->path('watch'));
        @chmod($this->path('watch'), 0664);
    }

    public function isWatched(int $now): bool
    {
        $m = @filemtime($this->path('watch'));

        return $m !== false && $now - $m <= self::WATCH_FRESH;
    }

    // ---- polling (scheduler) -------------------------------------------------------------------------------------

    private function liveArgs(): array
    {
        return array_map(fn ($p, $i) => $p.':'.($i['tls'] ? 1 : 0), array_keys($this->instances()), $this->instances());
    }

    /** One LIVE poll: [port => sample]. */
    public function poll(): array
    {
        return SampleParser::parseLive($this->transport()->run('live', RemoteScripts::LIVE, $this->liveArgs()));
    }

    /** Incremental history pull + one own sample per instance + storage alerts. Returns the status it wrote. */
    public function pull(int $now): array
    {
        $status = ['at' => $now, 'ok' => false, 'added' => 0, 'error' => null];
        try {
            $have = [];
            foreach (array_keys($this->instances()) as $p) {
                $have[$p] = $this->rows($p);
            }
            $args = array_map(fn ($p) => $p.':'.(empty($have[$p]) ? 0 : (int) end($have[$p])['ts']), array_keys($have));
            $got = SampleParser::parsePull($this->transport()->run('pull', RemoteScripts::PULL, $args));
            $own = $this->poll();
            foreach ($have as $p => $rows) {
                $add = [...($got[$p] ?? []), ...(isset($own[$p]) ? [$own[$p]] : [])];
                $status['added'] += count($add);
                if ($add) {
                    $this->writeRows($p, SeriesBuilder::merge($rows, $add, $now));
                }
            }
            $status['ok'] = true;
            $this->checkAlerts($now);
        } catch (\Throwable $e) {
            $status['error'] = substr($e->getMessage(), 0, 300);
        }
        $this->writeAtomic('status.json', json_encode($status));

        return $status;
    }

    public function checkAlerts(int $now): array
    {
        $inst = [];
        foreach (array_keys($this->instances()) as $p) {
            $r = $this->rows($p);
            $l = $r ? end($r) : null;
            if ($l && $now - $l['ts'] < 900) {
                $inst[] = ['port' => $p, 'mem' => $l['mem'], 'max' => $l['max']];
            }
        }
        [$state, $fired] = Alerts::evaluate($this->readJson('alerts-state.json', []), $inst, $now);
        $this->writeAtomic('alerts-state.json', json_encode($state));
        if ($fired) {
            $this->writeAtomic('alerts.json', json_encode(array_slice([...$this->readJson('alerts.json', []), ...$fired], -50)));
        }

        return $fired;
    }

    public function pushLive(array $samples, int $now): void
    {
        foreach ($samples as $p => $s) {
            $rows = $this->liveRows($p);
            if (! $rows || $s['ts'] > end($rows)['ts']) {
                $rows[] = $s;
            }
            $rows = array_values(array_filter($rows, fn ($r) => $r['ts'] >= $now - self::LIVE_KEEP));
            $this->writeAtomic("live-$p.json", json_encode($rows));
        }
    }

    /**
     * Scheduler entry (every minute). While a page watches the Live window: poll every `interval` s for ~55 s.
     * Otherwise: one history pull when the last one is older than PULL_EVERY.
     *
     * @param  callable(int):void|null  $sleep  test seam
     */
    public function tick(?callable $clock = null, ?callable $sleep = null, int $interval = 5, int $budget = 55): string
    {
        $clock ??= fn () => time();
        $sleep ??= fn (int $s) => sleep($s);
        $start = $clock();
        $did = 'idle';
        if ($this->isWatched($start)) {
            $did = 'live';
            while ($clock() - $start < $budget) {
                try {
                    $this->pushLive($this->poll(), $clock());
                } catch (\Throwable $e) {
                    $this->writeAtomic('live-error.json', json_encode(['at' => $clock(), 'error' => substr($e->getMessage(), 0, 200)]));
                }
                $sleep($interval);
                if (! $this->isWatched($clock())) {
                    break;
                }
            }
        }
        $s = $this->status();
        if (! $s || $clock() - $s['at'] >= self::PULL_EVERY) {
            $this->pull($clock());
            $did .= '+pull';
        }

        return $did;
    }

    // ---- read side (web) -----------------------------------------------------------------------------------------

    public function series(int $port, string $window, int $now): array
    {
        $rows = $window === 'live' ? $this->liveRows($port) : $this->rows($port);

        return SeriesBuilder::build($rows, $now, $window);
    }
}
