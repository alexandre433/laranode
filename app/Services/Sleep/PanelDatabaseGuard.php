<?php

namespace App\Services\Sleep;

/**
 * The panel's own database must never sleep. Decides whether the panel's DB
 * connection points at the same instance as the registered hosting database.
 * Unknown/ambiguous => treated as shared (fail closed).
 */
class PanelDatabaseGuard
{
    /** @param array<string, string> $entry registry entry of the hosting DB (kind=db) */
    public function sharesInstance(array $entry): bool
    {
        $name = config('database.default');
        $conn = config("database.connections.{$name}");
        if (! is_array($conn) || empty($conn['driver'])) {
            return true;
        }

        $driver = $conn['driver'];
        if ($driver === 'sqlite') {
            return false;
        }

        $panelFamily = match ($driver) {
            'mysql', 'mariadb' => 'mysql',
            'pgsql' => 'pgsql',
            default => null,
        };
        if ($panelFamily === null) {
            return true;
        }

        $engineFamily = ($entry['engine'] ?? '') === 'postgres' ? 'pgsql' : 'mysql';
        if ($panelFamily !== $engineFamily) {
            return false;
        }

        $socket = (string) ($conn['unix_socket'] ?? '');
        if ($socket !== '' && $socket === ($entry['public_socket'] ?? null)) {
            return true;
        }

        $host = strtolower((string) ($conn['host'] ?? ''));
        if (! in_array($host, ['', 'localhost', '127.0.0.1', '::1'], true)) {
            return false;
        }

        $default = $engineFamily === 'pgsql' ? '5432' : '3306';
        $port = (string) (($conn['port'] ?? '') !== '' ? $conn['port'] : $default);

        return $port === (string) ($entry['public_port'] ?? $default);
    }
}
