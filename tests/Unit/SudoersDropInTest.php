<?php

// Guards the sudoers drop-ins in laranode-scripts/etc/sudoers.d/.
//
// www-data may only run commands that some drop-in explicitly authorizes, so a
// panel script missing from every drop-in silently fails in production
// ("sudo: a password is required"), while a drop-in granting a whole binary
// hands www-data far more than the panel needs. Both classes of bug shipped
// once already: laranode-cron granted the wrong runas user, and laranode-ufw
// granted the raw /usr/sbin/ufw binary. These tests fail if either comes back.

const SUDOERS_DIR = __DIR__.'/../../laranode-scripts/etc/sudoers.d';
const BIN_DIR = __DIR__.'/../../laranode-scripts/bin';

// Run by an admin over SSH, never through the panel — intentionally not authorized.
const ADMIN_ONLY_SCRIPTS = [
    'laranode-installer.sh',
    'laranode-upgrade.sh',
];

function dropInNames(): array
{
    return array_map('basename', glob(SUDOERS_DIR.'/*') ?: []);
}

function dropInContents(string $name): string
{
    return file_get_contents(SUDOERS_DIR.'/'.$name);
}

/** Absolute paths the drop-ins authorize www-data to run. */
function authorizedCommandPaths(): array
{
    $paths = [];
    foreach (dropInNames() as $name) {
        foreach (explode("\n", dropInContents($name)) as $line) {
            if (preg_match('/^www-data\s+ALL=\([^)]*\)\s+NOPASSWD:\s*(\S+)/', trim($line), $m)) {
                $paths[] = $m[1];
            }
        }
    }

    return $paths;
}

it('authorizes every panel script through some sudoers drop-in', function () {
    $authorized = array_map('basename', authorizedCommandPaths());

    $uncovered = [];
    foreach (glob(BIN_DIR.'/*.sh') as $script) {
        $name = basename($script);
        if (! in_array($name, ADMIN_ONLY_SCRIPTS, true) && ! in_array($name, $authorized, true)) {
            $uncovered[] = $name;
        }
    }

    expect($uncovered)->toBe([]);
});

it('never authorizes a panel path that is not in the repo', function () {
    $repoRoot = realpath(__DIR__.'/../..');
    $prefix = '/home/laranode_ln/panel';

    $missing = [];
    foreach (authorizedCommandPaths() as $path) {
        if (! str_starts_with($path, $prefix.'/')) {
            continue; // system binaries such as /usr/sbin/a2dissite
        }
        if (! file_exists($repoRoot.'/'.str_replace('\\', '/', substr($path, strlen($prefix) + 1)))) {
            $missing[] = $path;
        }
    }

    expect($missing)->toBe([]);
});

it('grants the cron script root, because crontab -u requires it', function () {
    // laranode-cron.sh runs `crontab -u <user>`, which only root may do. A
    // (www-data) runas makes every cron write fail on a real install.
    expect(dropInContents('laranode-cron'))
        ->toContain('www-data ALL=(ALL) NOPASSWD:')
        ->not->toContain('ALL=(www-data)');
});

it('never grants www-data the raw ufw binary', function () {
    $contents = dropInContents('laranode-ufw');

    expect($contents)->toContain('laranode-ufw.sh')
        ->and(preg_match('#^www-data\s+ALL=.*NOPASSWD:\s*/usr/sbin/ufw\s*$#m', $contents))->toBe(0);
});
