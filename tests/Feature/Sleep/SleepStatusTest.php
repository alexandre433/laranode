<?php

use App\Models\User;
use Illuminate\Support\Facades\Process;
use Tests\Support\SleepFixtures;

// These tests re-point the panel DB connection; restore it so RefreshDatabase can roll back.
beforeEach(function () {
    $this->origDbDefault = config('database.default');
    $this->origDbConnections = config('database.connections');
});
afterEach(function () {
    config(['database.default' => $this->origDbDefault, 'database.connections' => $this->origDbConnections]);
});

afterEach(fn () => isset($this->dir) && SleepFixtures::cleanup($this->dir));

function statusRows($test, ?User $admin = null): array
{
    return collect($test->actingAs($admin ?? User::factory()->create(['role' => 'admin']))->getJson('/admin/power/status')->assertOk()->json('services'))->keyBy('key')->all();
}

test('unmanaged keys report external and cannot sleep', function () {
    Process::fake(['*' => Process::result(output: 'active')]);
    $this->dir = SleepFixtures::registry();
    config(['laranode.managed_dir' => $this->dir, 'database.default' => 'sqlite']);
    $rows = statusRows($this);
    expect($rows['reverb'])->toMatchArray(['managed' => false, 'state' => 'external', 'can_sleep' => false]);
});

test('managed + enabled + real unit inactive = sleeping', function () {
    $this->dir = SleepFixtures::registry(SleepFixtures::fullInstall(), ['reverb' => ['enabled' => '1', 'idle_minutes' => '9']]);
    config(['laranode.managed_dir' => $this->dir, 'database.default' => 'sqlite']);

    Process::fake(['*is-active*laranode-reverb.service*' => Process::result(output: "inactive\n", exitCode: 3), '*' => Process::result(output: "active\n")]);
    $r = statusRows($this)['reverb'];
    expect($r)->toMatchArray(['managed' => true, 'enabled' => true, 'state' => 'sleeping', 'idle_minutes' => 9, 'can_sleep' => true]);
});

test('managed + enabled + real unit active = running', function () {
    $this->dir = SleepFixtures::registry(SleepFixtures::fullInstall(), ['reverb' => ['enabled' => '1', 'idle_minutes' => '9']]);
    config(['laranode.managed_dir' => $this->dir, 'database.default' => 'sqlite']);
    Process::fake(['*' => Process::result(output: "active\n")]);
    expect(statusRows($this)['reverb']['state'])->toBe('running');
});

test('managed but sleep off: enabled false, state follows the unit', function () {
    $this->dir = SleepFixtures::registry(SleepFixtures::fullInstall());
    config(['laranode.managed_dir' => $this->dir, 'database.default' => 'sqlite']);
    Process::fake(['*' => Process::result(output: "active\n")]);
    expect(statusRows($this)['queue'])->toMatchArray(['enabled' => false, 'state' => 'running']);
});

test('hostdb shares the panel DB: cannot sleep, reason panel_db', function () {
    $admin = User::factory()->create(['role' => 'admin']);
    $this->dir = SleepFixtures::registry(SleepFixtures::fullInstall());
    config(['laranode.managed_dir' => $this->dir, 'database.default' => 'mysql', 'database.connections.mysql' => ['driver' => 'mysql', 'host' => '127.0.0.1', 'port' => '3306']]);
    Process::fake(['*' => Process::result(output: "active\n")]);
    expect(statusRows($this, $admin)['hostdb'])->toMatchArray(['can_sleep' => false, 'reason' => 'panel_db']);
});

test('pre-existing engines the registry does not own are listed as external, never managed', function () {
    $this->dir = SleepFixtures::registry(['reverb' => SleepFixtures::fullInstall()['reverb']]);
    config(['laranode.managed_dir' => $this->dir, 'database.default' => 'sqlite']);
    Process::fake(['*' => Process::result(output: "active\n")]);
    $a = User::factory()->create(['role' => 'admin']);
    $ext = collect($this->actingAs($a)->getJson('/admin/power/status')->json('external'))->pluck('service')->all();
    expect($ext)->toContain('postgresql')->and($ext)->toContain('mysql');
});

test('status read never calls sudo', function () {
    $this->dir = SleepFixtures::registry(SleepFixtures::fullInstall());
    config(['laranode.managed_dir' => $this->dir, 'database.default' => 'sqlite']);
    Process::fake(['*' => Process::result(output: "active\n")]);
    statusRows($this);
    Process::assertNotRan(fn ($p) => in_array('sudo', (array) $p->command, true));
});

test('hostdb on a host whose AppArmor profile blocks the moved socket: cannot sleep, reason apparmor', function () {
    $admin = User::factory()->create(['role' => 'admin']);
    $entries = SleepFixtures::fullInstall();
    $entries['hostdb']['apparmor'] = 'enforced';
    $this->dir = SleepFixtures::registry($entries);
    config(['laranode.managed_dir' => $this->dir, 'database.default' => 'sqlite']);
    Process::fake(['*' => Process::result(output: "active\n")]);
    expect(statusRows($this, $admin)['hostdb'])->toMatchArray(['can_sleep' => false, 'reason' => 'apparmor']);
});

test('AppArmor on but unverifiable at register time is blocked too; "none" is free to sleep', function () {
    $admin = User::factory()->create(['role' => 'admin']);
    foreach (['unknown' => false, 'none' => true] as $verdict => $canSleep) {
        $entries = SleepFixtures::fullInstall();
        $entries['hostdb']['apparmor'] = $verdict;
        $this->dir = SleepFixtures::registry($entries);
        config(['laranode.managed_dir' => $this->dir, 'database.default' => 'sqlite']);
        Process::fake(['*' => Process::result(output: "active\n")]);
        expect(statusRows($this, $admin)['hostdb']['can_sleep'])->toBe($canSleep, $verdict);
        SleepFixtures::cleanup($this->dir);
    }
});
