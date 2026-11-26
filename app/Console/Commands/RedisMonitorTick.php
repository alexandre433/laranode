<?php

namespace App\Console\Commands;

use App\Services\RedisMonitor\RedisMonitor;
use Illuminate\Console\Command;

class RedisMonitorTick extends Command
{
    protected $signature = 'redis-monitor:tick {--pull : force a history pull now}';

    protected $description = 'Redis monitor: poll live samples while the page is watched, pull history every ~5 min (read-only INFO)';

    public function handle(RedisMonitor $monitor): int
    {
        if (! config('redis_monitor.enabled')) {
            return self::SUCCESS;
        }
        if ($this->option('pull')) {
            $s = $monitor->pull(time());
            $this->line($s['ok'] ? "pulled, {$s['added']} samples" : 'pull failed: '.$s['error']);

            return $s['ok'] ? self::SUCCESS : self::FAILURE;
        }
        $this->line($monitor->tick());

        return self::SUCCESS;
    }
}
