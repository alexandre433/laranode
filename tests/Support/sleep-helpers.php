<?php

// Shared helpers for the laranode-sleep.sh test files (sandboxed registry + stub systemctl).
use Tests\Support\SleepFixtures;

const SLEEP_SCRIPT = __DIR__.'/../../laranode-scripts/bin/laranode-sleep.sh';

function sleepSandbox(): array
{
    $root = sys_get_temp_dir().'/laranode-sleep-sbx-'.bin2hex(random_bytes(5));
    foreach (['bin', 'managed', 'systemd', 'php', 'units', 'active', 'enabled', 'panel'] as $d) {
        mkdir("{$root}/{$d}", 0755, true);
    }
    mkdir("{$root}/managed/managed.d", 0755, true);
    mkdir("{$root}/managed/sleep", 0755, true);
    file_put_contents("{$root}/bin/systemctl", <<<'SH'
#!/bin/bash
echo "$*" >> "$SBX/calls.log"
case "$1" in
  show)
    # show -p <prop> --value <unit>
    prop="$3"; unit="${@: -1}"
    case "$prop" in
      FragmentPath) echo "$SBX/units/$unit" ;;
      Id) [ -f "$SBX/units/$unit" ] && echo "$unit" || echo "$unit" ;;
      *) echo ;;
    esac ;;
  is-active) [ -e "$SBX/active/$2" ] && { echo active; exit 0; } || { echo inactive; exit 3; } ;;
  is-enabled) [ -e "$SBX/enabled/$2" ] && { echo enabled; exit 0; } || { echo disabled; exit 1; } ;;
  start) touch "$SBX/active/${@: -1}" ;;
  stop) rm -f "$SBX/active/${@: -1}" ;;
  enable) for a in "$@"; do case "$a" in enable|--now|--no-block) ;; *) touch "$SBX/enabled/$a" ;; esac; done ;;
  disable) for a in "$@"; do case "$a" in disable|--now|--no-block) ;; *) rm -f "$SBX/enabled/$a" ;; esac; done ;;
esac
exit 0
SH);
    chmod("{$root}/bin/systemctl", 0755);

    // The installer's manifest is REQUIRED (fail closed). Default: Laranode installed every
    // service it manages. Tests that need another shape overwrite or delete this file.
    file_put_contents("{$root}/managed/service-manifest.json",
        '{"version":1,"generated":"2026-11-21T00:00:00Z","host":{"os":"ubuntu 24.04","proxmox":false,"cloudpanel":false},"db":{"engine":"mysql","unit":"mysql.service"},'."\n\"services\":[\n"
        .'{"unit":"laranode-reverb.service","managed":true,"role":"reverb","reason":"t"},'."\n"
        .'{"unit":"laranode-queue-worker.service","managed":true,"role":"queue","reason":"t"},'."\n"
        .'{"unit":"php8.4-fpm.service","managed":true,"role":"php","reason":"t"},'."\n"
        .'{"unit":"mysql.service","managed":true,"role":"database","reason":"t"}'."\n]}\n");

    return ['root' => $root];
}

function runSleep(array $sbx, array $args, array $extraEnv = []): array
{
    $root = $sbx['root'];
    $env = array_merge([
        'SBX' => $root,
        'PATH' => "{$root}/bin:".getenv('PATH'),
        'LARANODE_SLEEP_TEST' => '1',
        'LARANODE_MANAGED_DIR' => "{$root}/managed",
        'LARANODE_SYSTEMD_DIR' => "{$root}/systemd",
        'LARANODE_PHP_ETC' => "{$root}/php",
        'LARANODE_PANEL_ENV' => "{$root}/panel/.env",
        'HOME' => $root,
    ], $extraEnv);
    $cmd = array_merge(['bash', SLEEP_SCRIPT], $args);
    $proc = proc_open($cmd, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, $env);
    $out = stream_get_contents($pipes[1]);
    $err = stream_get_contents($pipes[2]);
    $code = proc_close($proc);

    return ['code' => $code, 'out' => $out, 'err' => $err, 'all' => $out.$err, 'calls' => @file_get_contents("{$root}/calls.log") ?: ''];
}

function sleepRegister(array $sbx, string $key, array $fields): void
{
    // a Reverb registry entry always carries the address Reverb listens on; pass
    // ['bind_host' => null] to leave it out (an old/hand-written entry).
    if (($fields['kind'] ?? '') === 'reverb' && ! array_key_exists('bind_host', $fields)) {
        $fields['bind_host'] = '0.0.0.0';
    }
    $fields = array_filter($fields, fn ($v) => $v !== null);
    file_put_contents("{$sbx['root']}/managed/managed.d/{$key}.conf", SleepFixtures::render($fields));
}

function sleepUnit(array $sbx, string $unit, string $execStart): void
{
    file_put_contents("{$sbx['root']}/units/{$unit}", "[Service]\nExecStart={$execStart}\n");
}
