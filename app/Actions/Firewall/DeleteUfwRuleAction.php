<?php

namespace App\Actions\Firewall;

use Illuminate\Support\Facades\Process;
use RuntimeException;

class DeleteUfwRuleAction
{
    /**
     * Delete a staged rule by its `ufw status numbered` id.
     *
     * Only numeric ids are accepted — the UI only ever sends an integer, and the
     * sudoers grant is scoped to the allowlisted laranode-ufw.sh wrapper, which
     * itself takes a numeric rule number only.
     */
    public function execute(string $id): void
    {
        $id = trim($id);
        if ($id === '' || ! ctype_digit($id)) {
            throw new RuntimeException('UFW delete failed: rule id must be numeric.');
        }

        $proc = Process::run([
            'sudo',
            config('laranode.laranode_bin_path').'/laranode-ufw.sh',
            'delete',
            (string) (int) $id,
        ]);

        if ($proc->failed()) {
            throw new RuntimeException('UFW delete failed: '.$proc->errorOutput());
        }
    }
}
