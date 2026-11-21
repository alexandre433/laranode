<?php

namespace App\Actions\Firewall;


class GetUfwStatusAction
{
    public function execute(): string
    {
        $proc = UfwCommand::run(['status']);
        if ($proc->failed()) {
            return 'unknown';
        }
        $out = trim($proc->output());
        $lines = preg_split("/\r?\n/", $out);
        return trim($lines[0] ?? $out);
    }
}
