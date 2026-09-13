<?php

// The docker lab (local-dev) exists so panel features can be exercised without a
// VPS, which only works if it provisions the SAME privileged plumbing the real
// installer does. When the two drift, the lab passes where production fails —
// exactly how the laranode-cron sudoers bug shipped: the installer granted
// runas (www-data) while the lab's legacy wildcard granted (ALL).
//
// These tests read both provisioning scripts and fail if they disagree about the
// sudoers drop-ins or the systemd units.

const INSTALLER = __DIR__.'/../../laranode-scripts/bin/laranode-installer.sh';
const ENTRYPOINT = __DIR__.'/../../local-dev/entrypoint-setup.sh';

/** Names in the first `for drop in <names>; do` loop of a script. */
function sudoersDropInsInstalledBy(string $script): array
{
    preg_match('/for\s+drop\s+in\s+([^;]+);\s*do/', file_get_contents($script), $m);

    return isset($m[1]) ? preg_split('/\s+/', trim($m[1])) : [];
}

/** Template files the script copies into /etc/systemd/system. */
function systemdUnitsInstalledBy(string $script): array
{
    preg_match_all(
        '#cp\s+(?:-\w+\s+)*\S*templates/([\w.-]+)"?\s+/etc/systemd/system/#',
        file_get_contents($script),
        $m
    );

    return array_values(array_unique($m[1]));
}

it('installs the same sudoers drop-ins in the lab as on a real host', function () {
    $installer = sudoersDropInsInstalledBy(INSTALLER);
    $lab = sudoersDropInsInstalledBy(ENTRYPOINT);

    expect($installer)->not->toBe([])
        ->and($lab)->toBe($installer);
});

it('installs the same systemd units in the lab as on a real host', function () {
    $installer = systemdUnitsInstalledBy(INSTALLER);
    $lab = systemdUnitsInstalledBy(ENTRYPOINT);

    expect($installer)->not->toBe([])
        ->and($lab)->toBe($installer);
});

it('ships a scheduler unit and timer, and the installer enables the timer', function () {
    $installer = systemdUnitsInstalledBy(INSTALLER);

    expect($installer)->toContain('laranode-scheduler.service')
        ->and($installer)->toContain('laranode-scheduler.timer')
        ->and(file_get_contents(INSTALLER))->toContain('systemctl enable --now laranode-scheduler.timer');

    // The schedule's everyMinute() job needs a minutely tick, and the oneshot
    // service must run as the user that owns the panel files.
    $timer = file_get_contents(__DIR__.'/../../laranode-scripts/templates/laranode-scheduler.timer');
    $service = file_get_contents(__DIR__.'/../../laranode-scripts/templates/laranode-scheduler.service');

    expect($timer)->toContain('OnCalendar=minutely')
        ->and($service)->toContain('artisan schedule:run')
        ->and($service)->toContain('User=laranode_ln');
});

it('does not hide the drop-ins behind a wildcard rule in the lab', function () {
    // A broad `$BIN/*.sh` grant makes the lab pass where production fails.
    expect(file_get_contents(ENTRYPOINT))->not->toContain('NOPASSWD: $BIN/*.sh');
});
