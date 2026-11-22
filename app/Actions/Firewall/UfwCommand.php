<?php

namespace App\Actions\Firewall;

use Illuminate\Contracts\Process\ProcessResult;
use Illuminate\Support\Facades\Process;

/**
 * The one way the panel drives ufw: through the root-owned, argument-validating wrapper
 * laranode-ufw.sh (sub-commands status, status-numbered, show-added, enable, disable,
 * allow, deny, delete). There is no sudo grant for the ufw binary itself.
 */
class UfwCommand
{
    /**
     * @param  array<int, string>  $args  wrapper sub-command and its arguments
     * @return array<int, string>
     */
    public static function command(array $args): array
    {
        return array_merge(
            ['sudo', rtrim((string) config('laranode.laranode_bin_path'), '/').'/laranode-ufw.sh'],
            array_values($args),
        );
    }

    /**
     * @param  array<int, string>  $args
     */
    public static function run(array $args): ProcessResult
    {
        return Process::run(self::command($args));
    }
}
