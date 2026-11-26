<?php

namespace App\Services\RedisMonitor\Transport;

final class SshTransport extends ProcessTransport
{
    public function __construct(private readonly array $cfg) {}

    protected function command(array $args): array
    {
        $key = $this->cfg['key'] ?? null;
        $known = $this->cfg['known_hosts'] ?? null;
        if (! $key || ! $known || empty($this->cfg['target'])) {
            throw new \RuntimeException('redis monitor ssh is not configured (key, known_hosts, target)');
        }

        return [
            'ssh', '-i', $key,
            '-o', 'BatchMode=yes',
            '-o', 'IdentitiesOnly=yes',
            '-o', 'StrictHostKeyChecking=yes',
            '-o', 'UserKnownHostsFile='.$known,
            '-o', 'ConnectTimeout=8',
            '-o', 'ServerAliveInterval=5',
            $this->cfg['target'],
            'sh', '-s', '--', ...$args,
        ];
    }

    protected function preamble(): string
    {
        // Names of things on the remote box only; the Redis password stays in the remote file.
        $user = preg_replace('/[^A-Za-z0-9_.-]/', '', (string) ($this->cfg['redis_user'] ?? ''));
        $pass = preg_replace('/[^A-Za-z0-9_.\/$-]/', '', (string) ($this->cfg['redis_passfile'] ?? ''));
        $dir = preg_replace('/[^A-Za-z0-9_.\/-]/', '', (string) ($this->cfg['metrics_dir'] ?? ''));

        return "RM_USER={$user}\nRM_PASSFILE=\"{$pass}\"\nRM_METRICS_DIR={$dir}\nexport RM_USER RM_PASSFILE RM_METRICS_DIR";
    }
}
