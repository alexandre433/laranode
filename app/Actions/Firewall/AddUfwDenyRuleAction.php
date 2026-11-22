<?php

namespace App\Actions\Firewall;

use RuntimeException;

class AddUfwDenyRuleAction
{
    public function execute(string $ruleSpec): void
    {
        $ruleSpec = trim($ruleSpec);
        if ($ruleSpec === '') {
            throw new RuntimeException('Empty rule spec');
        }

        $parts = preg_split('/\s+/', trim($ruleSpec));
        $parts = array_filter($parts, fn ($v) => $v !== '');
        $proc = UfwCommand::run(array_merge(['deny'], $parts));

        if ($proc->failed()) {
            throw new RuntimeException('UFW deny failed: '.$proc->errorOutput());
        }
    }
}
