<?php

namespace App\Actions\Firewall;

use RuntimeException;

class ToggleUfwAction
{
    public function execute(bool $enable): string
    {
        if ($enable) {
            $proc = UfwCommand::run(['enable']);
        } else {
            $proc = UfwCommand::run(['disable']);
        }
        if ($proc->failed()) {
            throw new RuntimeException('UFW toggle failed: '.$proc->errorOutput());
        }

        return trim($proc->output());
    }
}
