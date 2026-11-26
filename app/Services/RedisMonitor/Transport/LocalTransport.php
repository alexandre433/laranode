<?php

namespace App\Services\RedisMonitor\Transport;

final class LocalTransport extends ProcessTransport
{
    public function __construct(private readonly array $cfg) {}

    protected function command(array $args): array
    {
        return ['sh', '-s', '--', ...$args];
    }

    protected function preamble(): string
    {
        $user = preg_replace('/[^A-Za-z0-9_.-]/', '', (string) ($this->cfg['redis_user'] ?? ''));
        $pass = preg_replace('/[^A-Za-z0-9_.\/-]/', '', (string) ($this->cfg['redis_passfile'] ?? ''));

        return "RM_USER={$user}\nRM_PASSFILE={$pass}\nexport RM_USER RM_PASSFILE";
    }
}
