<?php

use App\Models\User;
use Illuminate\Support\Facades\Process;
use Tests\Support\SleepFixtures;

afterEach(fn () => isset($this->dir) && SleepFixtures::cleanup($this->dir));

function statusRows($test): array
{
    return collect($test->actingAs(User::factory()->create(['role' => 'admin']))->getJson('/admin/power/status')->assertOk()->json('services'))->keyBy('key')->all();
}

test('unmanaged keys report external and cannot sleep', function () {
    Process::fake(['*' => Process::result(output: 'active')]);
    $this->dir = SleepFixtures::registry();
    config(['laranode.managed_dir' => $this->dir, 'database.default' => 'sqlite']);
    $rows = statusRows($this);
    expect($rows['reverb'])->toMatchArray(['managed' => false, 'state' => 'external', 'can_sleep' => false]);
});

test('managed + enabled + real unit inactive = sleeping; active = running', function () {
    $this->dir = SleepFixtures::registry(SleepFixtures::fullInstall(), ['reverb' => ['enabled' => '1', 'idle_minutes' => '9']]);
    config(['laranode.managed_dir' => $this->dir, 'database.default' => 'sqlite']);

    Process::fake(['systemctl is-active laranode-reverb.service' => Process::result(output: "inactive\n", exitCode: 3), '*' => Process::result(output: "active\n")]);
    $r = statusRows($this)['reverb'];
    expect($r)->toMatchArray(['managed' => true, 'enabled' => true, 'state' => 'sleeping', 'idle_minutes' => 9, 'can_sleep' => true]);

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
    $this->dir = SleepFixtures::registry(SleepFixtures::fullInstall());
    config(['laranode.managed_dir' => $this->dir, 'database.default' => 'mysql', 'database.connections.mysql' => ['driver' => 'mysql', 'host' => '127.0.0.1', 'port' => '3306']]);
    Process::fake(['*' => Process::result(output: "active\n")]);
    expect(statusRows($this)['hostdb'])->toMatchArray(['can_sleep' => false, 'reason' => 'panel_db']);
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
