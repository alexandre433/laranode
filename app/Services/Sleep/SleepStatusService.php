<?php

namespace App\Services\Sleep;

use Illuminate\Support\Facades\Process;

/**
 * Builds the Power page model. Read-only: plain `systemctl is-active`, never sudo.
 */
class SleepStatusService
{
    private const META = [
        'reverb' => ['label' => 'Reverb websockets', 'idle' => true, 'manual' => true, 'default_idle' => 10],
        'queue' => ['label' => 'Queue worker', 'idle' => false, 'manual' => true, 'default_idle' => null],
        'hostdb' => ['label' => 'Hosting database', 'idle' => true, 'manual' => true, 'default_idle' => 15],
        'fpm' => ['label' => 'PHP-FPM workers (site pools)', 'idle' => true, 'manual' => false, 'default_idle' => 5],
    ];

    public function __construct(
        private ManagedRegistry $registry,
        private PanelDatabaseGuard $guard,
    ) {}

    /** @return array{services: list<array<string, mixed>>, external: list<array<string, string>>} */
    public function handle(): array
    {
        $services = [];
        foreach (ManagedRegistry::KEYS as $key) {
            $services[] = $this->row($key);
        }

        return ['services' => $services, 'external' => $this->external()];
    }

    /** Why this key cannot be put to sleep right now, or null. */
    public function blockReason(string $key): ?string
    {
        $entry = $this->registry->entry($key);
        if ($entry === null) {
            return 'external';
        }
        if ($key === 'hostdb') {
            if (($entry['engine'] ?? '') === 'postgres' || ! in_array($entry['engine'] ?? '', ['mysql', 'mariadb'], true)) {
                return 'unsupported_engine';
            }
            if ($this->guard->sharesInstance($entry)) {
                return 'panel_db';
            }
            // Recorded by laranode-managed-register.sh (root can read the AppArmor profile list, the
            // panel cannot). The script re-checks at run time; this is only the early, honest answer.
            if (($entry['apparmor'] ?? 'none') !== 'none') {
                return 'apparmor';
            }
        }

        return null;
    }

    /** @return array<string, mixed> */
    private function row(string $key): array
    {
        $meta = self::META[$key];
        $entry = $this->registry->entry($key);
        $state = $this->registry->state($key);
        $enabled = ($state['enabled'] ?? '') === '1';
        $reason = $this->blockReason($key);

        if ($entry === null) {
            $status = 'external';
        } elseif ($key === 'fpm') {
            $status = $enabled ? 'ondemand' : 'running';
        } else {
            $active = $this->isActive($entry['unit'] ?? '');
            $status = $active ? 'running' : ($enabled ? 'sleeping' : 'stopped');
        }

        $idle = isset($state['idle_minutes']) ? (int) $state['idle_minutes'] : $meta['default_idle'];

        return [
            'key' => $key,
            'label' => $meta['label'],
            'managed' => $entry !== null,
            'enabled' => $enabled,
            'state' => $status,
            'idle_minutes' => $idle,
            'default_idle_minutes' => $meta['default_idle'],
            'can_sleep' => $reason === null,
            'reason' => $reason,
            'supports_idle' => $meta['idle'],
            'supports_manual' => $meta['manual'],
            'memory_mb' => null,
        ];
    }

    private function isActive(string $unit): bool
    {
        if (! preg_match('/^[A-Za-z0-9@:._-]+\.service$/', $unit)) {
            return false;
        }

        return trim(Process::run(['systemctl', 'is-active', $unit])->output()) === 'active';
    }

    /**
     * Engines/services present on the host that Laranode does NOT own. Shown so
     * the admin can see exactly what sleep mode never touches.
     *
     * @return list<array{service: string, label: string}>
     */
    private function external(): array
    {
        $owned = [];
        foreach (['reverb', 'queue', 'hostdb'] as $key) {
            if ($unit = ($this->registry->entry($key)['unit'] ?? null)) {
                $owned[] = preg_replace('/\.service$/', '', $unit);
            }
        }

        $out = [];
        foreach ((array) config('laranode.sleep_external_candidates', []) as $svc) {
            if (in_array($svc, $owned, true)) {
                continue;
            }
            if (trim(Process::run(['systemctl', 'is-active', "{$svc}.service"])->output()) === 'active') {
                $out[] = ['service' => $svc, 'label' => $svc];
            }
        }

        return $out;
    }
}
