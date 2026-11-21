<?php

namespace Tests\Support;

/**
 * Builds a throwaway root-owned-style registry directory (the thing the real
 * installer writes to /etc/laranode) for sleep/wake tests.
 */
class SleepFixtures
{
    /**
     * @param  array<string, array<string, string>>  $entries  key => registry fields
     * @param  array<string, array<string, string>>  $states  key => state fields
     */
    public static function registry(array $entries = [], array $states = []): string
    {
        $dir = sys_get_temp_dir().'/laranode-sleep-'.bin2hex(random_bytes(6));
        mkdir($dir.'/managed.d', 0755, true);
        mkdir($dir.'/sleep', 0755, true);

        foreach ($entries as $key => $fields) {
            file_put_contents("{$dir}/managed.d/{$key}.conf", self::render($fields));
        }
        foreach ($states as $key => $fields) {
            file_put_contents("{$dir}/sleep/{$key}.state", self::render($fields));
        }

        return $dir;
    }

    /** @param array<string, string> $fields */
    public static function render(array $fields): string
    {
        $out = '';
        foreach ($fields as $k => $v) {
            $out .= "{$k}={$v}\n";
        }

        return $out;
    }

    /** Registry entries as the installer would write them for a full install. */
    public static function fullInstall(): array
    {
        return [
            'reverb' => ['kind' => 'reverb', 'unit' => 'laranode-reverb.service', 'public_port' => '8080'],
            'queue' => ['kind' => 'queue', 'unit' => 'laranode-queue-worker.service'],
            'fpm' => ['kind' => 'fpm'],
            'hostdb' => [
                'kind' => 'db', 'engine' => 'mysql', 'unit' => 'mysql.service', 'public_port' => '3306',
                'public_socket' => '/var/run/mysqld/mysqld.sock', 'cnf_dir' => '/etc/mysql/conf.d',
            ],
        ];
    }

    public static function cleanup(string $dir): void
    {
        if (str_starts_with($dir, sys_get_temp_dir().'/laranode-sleep-')) {
            exec('rm -rf '.escapeshellarg($dir));
        }
    }
}
