<?php

namespace App\Listeners;

use App\Services\Sleep\ManagedRegistry;
use Illuminate\Queue\Events\JobQueued;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Process;

/**
 * When queue sleep is on and the worker is down, a dispatched job wakes it at
 * once (instead of waiting for the 30 s timer). Never breaks dispatching.
 */
class WakeQueueOnJobQueued
{
    public function handle(JobQueued $event): void
    {
        try {
            $registry = ManagedRegistry::fromConfig();
            // a stale entry is refused by the script (exit 3) on every wake: do not even try
            if (! $registry->isManaged('queue') || $registry->isStale('queue') || ! $registry->isEnabled('queue')) {
                return;
            }

            // one wake per burst of dispatches
            if (! Cache::add('laranode.sleep.queue_wake', 1, 5)) {
                return;
            }

            $unit = $registry->entry('queue')['unit'] ?? '';
            if (! preg_match('/^[A-Za-z0-9@:._-]+\.service$/', $unit)) {
                return;
            }
            if (trim(Process::run(['systemctl', 'is-active', $unit])->output()) === 'active') {
                return;
            }

            Process::run(['sudo', config('laranode.laranode_bin_path').'/laranode-sleep.sh', 'queue', 'wake']);
        } catch (\Throwable) {
            // the timer is the fallback; dispatching must never fail because of sleep mode
        }
    }
}
