<?php

/**
 * The installer's /etc/laranode/service-manifest.json says which services Laranode
 * installed (managed:true) and which were already on the host (managed:false). When it
 * exists it is the source of truth: laranode-sleep.sh refuses anything it does not back
 * (defence in depth on top of the registry), and laranode-managed-register.sh only
 * registers what it lists.
 *
 * Helpers (sleepSandbox, runSleep, sleepRegister, sleepUnit) live in tests/Support/sleep-helpers.php.
 */
require_once __DIR__.'/../../Support/sleep-helpers.php';

if (PHP_OS_FAMILY === 'Windows') {
    return;
}

const REGISTER_SCRIPT = __DIR__.'/../../../laranode-scripts/bin/laranode-managed-register.sh';

/** One manifest in the installer's exact one-service-per-line format. */
function writeManifest(array $sbx, array $services, string $dbEngine = 'mysql', string $dbUnit = 'mysql.service'): void
{
    $lines = [];
    foreach ($services as [$unit, $managed, $role]) {
        $lines[] = sprintf('{"unit":"%s","managed":%s,"role":"%s","reason":"t"}', $unit, $managed ? 'true' : 'false', $role);
    }
    file_put_contents("{$sbx['root']}/managed/service-manifest.json",
        '{"version":1,"generated":"2026-11-21T00:00:00Z","host":{"os":"ubuntu 24.04","proxmox":false,"cloudpanel":false},'
        .sprintf('"db":{"engine":"%s","unit":"%s"},', $dbEngine, $dbUnit)."\n\"services\":[\n"
        .implode(",\n", $lines)."\n]}\n");
}

function registerReverbFixture(array $sbx): void
{
    sleepRegister($sbx, 'reverb', ['kind' => 'reverb', 'unit' => 'laranode-reverb.service', 'public_port' => '8080']);
    sleepUnit($sbx, 'laranode-reverb.service', '/usr/bin/php /home/laranode_ln/panel/artisan reverb:start');
}

afterEach(function () {
    if (isset($this->sbx)) {
        exec('rm -rf '.escapeshellarg($this->sbx['root']));
    }
});

// ─── laranode-sleep.sh: manifest gate ─────────────────────────────────────────

test('a registry entry the manifest marks as pre-existing (managed:false) is refused', function () {
    $this->sbx = sleepSandbox();
    registerReverbFixture($this->sbx);
    writeManifest($this->sbx, [['laranode-reverb.service', false, 'reverb']]);
    $r = runSleep($this->sbx, ['reverb', 'enable', '10']);
    expect($r['code'])->toBe(3)->and($r['all'])->toContain('manifest')->and($r['calls'])->toBe('');
});

test('a registry entry the manifest does not list at all is refused', function () {
    $this->sbx = sleepSandbox();
    registerReverbFixture($this->sbx);
    writeManifest($this->sbx, [['apache2.service', true, 'web']]);
    $r = runSleep($this->sbx, ['reverb', 'enable', '10']);
    expect($r['code'])->toBe(3)->and($r['calls'])->toBe('');
});

test('a registry entry the manifest backs (managed:true) proceeds', function () {
    $this->sbx = sleepSandbox();
    registerReverbFixture($this->sbx);
    writeManifest($this->sbx, [['laranode-reverb.service', true, 'reverb']]);
    $r = runSleep($this->sbx, ['reverb', 'enable', '10']);
    expect($r['code'])->toBe(0, $r['all']);
});

test('hostdb is refused when the manifest database is not a Laranode-installed MySQL/MariaDB', function () {
    $this->sbx = sleepSandbox();
    sleepRegister($this->sbx, 'hostdb', ['kind' => 'db', 'engine' => 'mysql', 'unit' => 'mysql.service', 'public_port' => '3306', 'public_socket' => '/run/mysqld/mysqld.sock', 'cnf_dir' => "{$this->sbx['root']}/mysqlconf", 'panel_env' => "{$this->sbx['root']}/panel/.env"]);
    sleepUnit($this->sbx, 'mysql.service', '/usr/sbin/mysqld');
    // DS shape: the database we installed is PostgreSQL 16; a pre-existing MySQL must not be slept
    writeManifest($this->sbx, [['postgresql@16-main.service', true, 'database'], ['mysql.service', false, 'preexisting']], 'pgsql', 'postgresql@16-main.service');
    $r = runSleep($this->sbx, ['hostdb', 'enable', '10']);
    expect($r['code'])->toBe(3)->and($r['all'])->toContain('MySQL/MariaDB')->and($r['calls'])->toBe('');
});

test('hostdb is refused when the manifest marks the database pre-existing', function () {
    $this->sbx = sleepSandbox();
    sleepRegister($this->sbx, 'hostdb', ['kind' => 'db', 'engine' => 'mysql', 'unit' => 'mysql.service', 'public_port' => '3306', 'public_socket' => '/run/mysqld/mysqld.sock', 'cnf_dir' => "{$this->sbx['root']}/mysqlconf", 'panel_env' => "{$this->sbx['root']}/panel/.env"]);
    writeManifest($this->sbx, [['mysql.service', false, 'database']]);
    foreach ([['hostdb', 'enable', '10'], ['hostdb', 'wake'], ['hostdb', 'sleep']] as $args) {
        expect(runSleep($this->sbx, $args)['code'])->toBe(3, implode(' ', $args));
    }
});

test('no manifest fails CLOSED: a registry alone never authorises touching a service', function () {
    $this->sbx = sleepSandbox();
    registerReverbFixture($this->sbx);
    unlink("{$this->sbx['root']}/managed/service-manifest.json");
    foreach ([['reverb', 'enable', '10'], ['reverb', 'wake'], ['reverb', 'sleep'], ['reverb', 'disable']] as $args) {
        $r = runSleep($this->sbx, $args);
        expect($r['code'])->toBe(3, implode(' ', $args))->and($r['all'])->toContain('manifest')->and($r['calls'])->toBe('');
    }
});

test('a missing or unbacking manifest never traps a service asleep: disable (only) still works', function () {
    foreach (['manifest deleted' => null, 'service flipped to managed:false' => [['laranode-reverb.service', false, 'reverb']]] as $why => $after) {
        $this->sbx = sleepSandbox();
        registerReverbFixture($this->sbx);
        expect(runSleep($this->sbx, ['reverb', 'enable', '10'])['code'])->toBe(0);
        $m = "{$this->sbx['root']}/managed/service-manifest.json";
        $after === null ? unlink($m) : writeManifest($this->sbx, $after);
        // everything that turns sleep ON or pokes the service stays refused (fail closed) ...
        foreach ([['reverb', 'enable', '10'], ['reverb', 'wake'], ['reverb', 'sleep']] as $args) {
            expect(runSleep($this->sbx, $args)['code'])->toBe(3, "{$why}: ".implode(' ', $args));
        }
        // ... but disable only restores the originals, so it must go through
        $off = runSleep($this->sbx, ['reverb', 'disable']);
        expect($off['code'])->toBe(0, "{$why}: ".$off['all'])
            ->and(glob("{$this->sbx['root']}/systemd/*"))->toBe([])
            ->and(file_exists("{$this->sbx['root']}/managed/sleep/reverb.state"))->toBeFalse();
        exec('rm -rf '.escapeshellarg($this->sbx['root']));
    }
});

test('disable without a manifest is still refused when sleep was never enabled (nothing to restore)', function () {
    $this->sbx = sleepSandbox();
    registerReverbFixture($this->sbx);
    unlink("{$this->sbx['root']}/managed/service-manifest.json");
    $r = runSleep($this->sbx, ['reverb', 'disable']);
    expect($r['code'])->toBe(3)->and($r['calls'])->toBe('');
});

// ─── laranode-managed-register.sh: derives the registry from the manifest ───────

function runRegister(array $sbx, array $keys, array $extraEnv = []): array
{
    $root = $sbx['root'];
    file_put_contents("{$root}/units/laranode-reverb.service", "[Service]\nExecStart=x\n");
    file_put_contents("{$root}/units/laranode-queue-worker.service", "[Service]\nExecStart=x\n");
    $env = array_merge([
        'SBX' => $root,
        'PATH' => "{$root}/bin:".getenv('PATH'),
        'LARANODE_MANAGED_DIR' => "{$root}/managed",
        'LARANODE_UNIT_DIR' => "{$root}/units",
        'LARANODE_PANEL_ENV' => "{$root}/panel/.env",
        'HOME' => $root,
    ], $extraEnv);
    $proc = proc_open(array_merge(['bash', REGISTER_SCRIPT], $keys), [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, $env);
    $all = stream_get_contents($pipes[1]).stream_get_contents($pipes[2]);
    $code = proc_close($proc);

    return ['code' => $code, 'all' => $all, 'has' => fn (string $k) => file_exists("{$root}/managed/managed.d/{$k}.conf")];
}

function skipUnlessRoot(): void
{
    if (! function_exists('posix_geteuid') || posix_geteuid() !== 0) {
        test()->markTestSkipped('register script is root-only; covered by the systemd matrix (tests/system/sleep)');
    }
}

test('register: only keys the manifest lists as managed:true are registered', function () {
    skipUnlessRoot();
    $this->sbx = sleepSandbox();
    writeManifest($this->sbx, [['laranode-reverb.service', true, 'reverb'], ['laranode-queue-worker.service', true, 'queue'], ['php8.4-fpm.service', false, 'php']]);
    $r = runRegister($this->sbx, ['reverb', 'queue', 'fpm', 'hostdb']);
    expect($r['code'])->toBe(0)
        ->and($r['has']('reverb'))->toBeTrue()
        ->and($r['has']('queue'))->toBeTrue()
        ->and($r['has']('fpm'))->toBeFalse('pre-existing PHP-FPM must not be registered')
        ->and($r['has']('hostdb'))->toBeFalse('no managed database in the manifest');
});

test('register: a pre-existing MySQL next to a Laranode-installed PostgreSQL is never registered', function () {
    skipUnlessRoot();
    $this->sbx = sleepSandbox();
    writeManifest($this->sbx, [['postgresql@16-main.service', true, 'database'], ['mysql.service', false, 'preexisting']], 'pgsql', 'postgresql@16-main.service');
    $r = runRegister($this->sbx, ['hostdb']);
    expect($r['has']('hostdb'))->toBeFalse()->and($r['all'])->toContain('not MySQL/MariaDB');
});

test('register: a service that is now skipped loses its STALE registry entry', function () {
    skipUnlessRoot();
    $this->sbx = sleepSandbox();
    writeManifest($this->sbx, [['laranode-reverb.service', true, 'reverb'], ['laranode-queue-worker.service', true, 'queue']]);
    file_put_contents("{$this->sbx['root']}/panel/.env", "REVERB_SERVER_HOST=127.0.0.1\n");
    $first = runRegister($this->sbx, ['reverb', 'queue']);
    expect($first['has']('reverb'))->toBeTrue()->and($first['has']('queue'))->toBeTrue();
    // Reverb is now bound somewhere we cannot mirror (IPv6) and the queue is no longer Laranode's
    file_put_contents("{$this->sbx['root']}/panel/.env", "REVERB_SERVER_HOST=::1\n");
    writeManifest($this->sbx, [['laranode-reverb.service', true, 'reverb'], ['laranode-queue-worker.service', false, 'queue']]);
    $second = runRegister($this->sbx, ['reverb', 'queue']);
    expect($second['has']('reverb'))->toBeFalse('stale bind_host=127.0.0.1 entry must go')
        ->and($second['has']('queue'))->toBeFalse('manifest no longer backs the queue');
});

test('register: without a manifest NOTHING is registered, not even with the old LARANODE_DB_INSTALLED_BY_US=1', function () {
    skipUnlessRoot();
    $this->sbx = sleepSandbox();
    unlink("{$this->sbx['root']}/managed/service-manifest.json");
    $r = runRegister($this->sbx, ['reverb', 'queue', 'fpm', 'hostdb'], ['LARANODE_DB_INSTALLED_BY_US' => '1']);
    expect($r['has']('reverb'))->toBeFalse()->and($r['has']('queue'))->toBeFalse()
        ->and($r['has']('fpm'))->toBeFalse()->and($r['has']('hostdb'))->toBeFalse()
        ->and($r['all'])->toContain('manifest');
});
