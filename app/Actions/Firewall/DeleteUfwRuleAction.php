<?php

namespace App\Actions\Firewall;

use RuntimeException;

class DeleteUfwRuleAction
{
    public function execute(string $idOrSpec): void
    {
        $idOrSpec = trim($idOrSpec);
        if ($idOrSpec === '') {
            throw new RuntimeException('Empty rule id/spec');
        }
        if (ctype_digit($idOrSpec)) {
            $args = ['delete', (string) (int) $idOrSpec];
        } else {
            // e.g. "allow 22/tcp": the wrapper validates every token and answers ufw's prompt itself
            $args = array_merge(['delete'], preg_split('/\s+/', $idOrSpec));
        }
        $proc = UfwCommand::run($args);
        if ($proc->failed()) {
            throw new RuntimeException('UFW delete failed: ' . $proc->errorOutput());
        }
    }
}
