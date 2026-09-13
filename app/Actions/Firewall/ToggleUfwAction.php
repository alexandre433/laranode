<?php

namespace App\Actions\Firewall;

use Illuminate\Support\Facades\Process;
use RuntimeException;

class ToggleUfwAction
{
    public function execute(bool $enable): string
    {
        // The wrapper passes --force for both directions (disable would otherwise prompt).
        $proc = Process::run([
            'sudo',
            config('laranode.laranode_bin_path').'/laranode-ufw.sh',
            $enable ? 'enable' : 'disable',
        ]);
        if ($proc->failed()) {
            throw new RuntimeException('UFW toggle failed: '.$proc->errorOutput());
        }

        return trim($proc->output());
    }
}
