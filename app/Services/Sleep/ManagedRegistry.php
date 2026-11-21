<?php

namespace App\Services\Sleep;

/**
 * Read-only view of the root-owned registry of services Laranode installed
 * (/etc/laranode/managed.d/<key>.conf) and their sleep state
 * (/etc/laranode/sleep/<key>.state).
 *
 * Only these fixed keys can ever be managed. A service that is not registered
 * (anything pre-existing on the host: shared PostgreSQL, Redis, nginx, ...) is
 * "external" and never managed. A missing registry means nothing is managed.
 */
class ManagedRegistry
{
    public const KEYS = ['reverb', 'queue', 'hostdb', 'fpm'];

    public function __construct(private string $dir) {}

    public static function fromConfig(): self
    {
        return new self((string) config('laranode.managed_dir', '/etc/laranode'));
    }

    /** @return array<string, string>|null */
    public function entry(string $key): ?array
    {
        if (! in_array($key, self::KEYS, true)) {
            return null;
        }

        return $this->parse("{$this->dir}/managed.d/{$key}.conf");
    }

    /** @return array<string, string> */
    public function state(string $key): array
    {
        if (! in_array($key, self::KEYS, true)) {
            return [];
        }

        return $this->parse("{$this->dir}/sleep/{$key}.state") ?? [];
    }

    public function isManaged(string $key): bool
    {
        return $this->entry($key) !== null;
    }

    /** Kept only so `disable` can restore a service that is still asleep (see laranode-managed-register.sh). */
    public function isStale(string $key): bool
    {
        return ($this->entry($key)['stale'] ?? '') === '1';
    }

    public function isEnabled(string $key): bool
    {
        return ($this->state($key)['enabled'] ?? '') === '1';
    }

    /** @return list<string> */
    public function keys(): array
    {
        return array_values(array_filter(self::KEYS, fn (string $k) => $this->isManaged($k)));
    }

    /** @return array<string, string>|null null when the file is missing/unreadable */
    private function parse(string $path): ?array
    {
        if (! is_file($path) || ! is_readable($path)) {
            return null;
        }

        $out = [];
        foreach (file($path, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
            if (preg_match('/^\s*([a-z_]+)\s*=\s*(.*?)\s*$/', $line, $m)) {
                $out[$m[1]] = $m[2];
            }
        }

        return $out;
    }
}
