<?php

/**
 * Controller + service behaviour: admin-only, registry-gated, guard-checked,
 * and the ONLY privileged path is `sudo laranode-sleep.sh <key> <action> [idle]`.
 */

use App\Models\Operation;
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

beforeEach(function () {
    Process::fake(['*' => Process::result(output: 'ok')]);
    $this->dir = SleepFixtures::registry(SleepFixtures::fullInstall());
    config(['laranode.managed_dir' => $this->dir, 'laranode.laranode_bin_path' => '/opt/ln/bin']);
    // panel on sqlite: hostdb is free to sleep
    config(['database.default' => 'sqlite']);
});

afterEach(fn () => SleepFixtures::cleanup($this->dir));

function powerAdmin(): User
{
    return User::factory()->create(['role' => 'admin']);
}

function sleepScriptRan(string ...$args): bool
{
    $expected = array_merge(['sudo', '/opt/ln/bin/laranode-sleep.sh'], $args);
    $ran = false;
    Process::assertRan(function ($p) use ($expected, &$ran) {
        if ($p->command === $expected) {
            $ran = true;
        }

        return true;
    });

    return $ran;
}

test('non-admin cannot toggle: 403, script never runs', function () {
    $u = User::factory()->create(['role' => 'user']);
    $this->actingAs($u)->postJson('/admin/power/action', ['key' => 'reverb', 'action' => 'enable', 'idle_minutes' => 10])
        ->assertForbidden();
    $this->actingAs($u)->getJson('/admin/power/status')->assertForbidden();
    $this->actingAs($u)->get('/admin/power')->assertForbidden();
    Process::assertNothingRan();
});

test('guest is rejected', function () {
    $this->postJson('/admin/power/action', ['key' => 'reverb', 'action' => 'enable', 'idle_minutes' => 10])->assertUnauthorized();
});

test('admin enable reverb runs exactly the allowlisted script with typed args', function () {
    $this->actingAs(powerAdmin())->postJson('/admin/power/action', ['key' => 'reverb', 'action' => 'enable', 'idle_minutes' => 10])
        ->assertOk()->assertJsonPath('ok', true);

    expect(sleepScriptRan('reverb', 'enable', '10'))->toBeTrue();
});

test('wake and sleep take no idle argument', function () {
    $a = powerAdmin();
    $this->actingAs($a)->postJson('/admin/power/action', ['key' => 'reverb', 'action' => 'wake'])->assertOk();
    $this->actingAs($a)->postJson('/admin/power/action', ['key' => 'reverb', 'action' => 'sleep'])->assertOk();
    expect(sleepScriptRan('reverb', 'wake'))->toBeTrue()
        ->and(sleepScriptRan('reverb', 'sleep'))->toBeTrue();
});

test('every action is recorded as an Operation for audit', function () {
    $a = powerAdmin();
    $this->actingAs($a)->postJson('/admin/power/action', ['key' => 'queue', 'action' => 'enable'])->assertOk();
    $op = Operation::latest('id')->first();
    expect($op->type)->toBe('power.enable')->and($op->target)->toBe('queue')
        ->and($op->status)->toBe('succeeded')->and($op->user_id)->toBe($a->id);
});

test('failed script is reported and audited as failed', function () {
    Process::fake(['*' => Process::result(errorOutput: 'boom', exitCode: 1)]);
    $this->actingAs(powerAdmin())->postJson('/admin/power/action', ['key' => 'reverb', 'action' => 'wake'])
        ->assertStatus(500)->assertJsonPath('ok', false);
    expect(Operation::latest('id')->first()->status)->toBe('failed');
});

test('unknown key is a validation error and nothing runs', function () {
    foreach (['postgresql', 'mysql', '../x', 'reverb;id', ''] as $key) {
        $this->actingAs(powerAdmin())->postJson('/admin/power/action', ['key' => $key, 'action' => 'enable', 'idle_minutes' => 5])
            ->assertStatus(422);
    }
    Process::assertNothingRan();
});

test('unknown action and bad idle values are validation errors', function () {
    $a = powerAdmin();
    foreach ([['reverb', 'restart', 5], ['reverb', '--help', 5], ['reverb', 'enable', 0], ['reverb', 'enable', 1441], ['reverb', 'enable', 'abc'], ['reverb', 'enable', null]] as [$k, $act, $idle]) {
        $this->actingAs($a)->postJson('/admin/power/action', ['key' => $k, 'action' => $act, 'idle_minutes' => $idle])->assertStatus(422);
    }
    Process::assertNothingRan();
});

test('key not in the registry is refused (external service, never managed)', function () {
    SleepFixtures::cleanup($this->dir);
    $this->dir = SleepFixtures::registry(['reverb' => SleepFixtures::fullInstall()['reverb']]); // no hostdb
    config(['laranode.managed_dir' => $this->dir]);

    $this->actingAs(powerAdmin())->postJson('/admin/power/action', ['key' => 'hostdb', 'action' => 'enable', 'idle_minutes' => 10])
        ->assertStatus(403)->assertJsonPath('ok', false);
    Process::assertNothingRan();
});

test('missing registry refuses every key (DS before Laranode registers anything)', function () {
    config(['laranode.managed_dir' => '/nonexistent/laranode-'.uniqid()]);
    foreach (['reverb', 'queue', 'hostdb', 'fpm'] as $k) {
        $this->actingAs(powerAdmin())->postJson('/admin/power/action', ['key' => $k, 'action' => 'enable', 'idle_minutes' => 10])->assertStatus(403);
    }
    Process::assertNothingRan();
});

test('hostdb sleep is refused when the panel DB is the same instance', function () {
    $admin = powerAdmin();
    config(['database.default' => 'mysql', 'database.connections.mysql' => ['driver' => 'mysql', 'host' => '127.0.0.1', 'port' => '3306']]);
    $this->actingAs($admin)->postJson('/admin/power/action', ['key' => 'hostdb', 'action' => 'enable', 'idle_minutes' => 10])
        ->assertStatus(409)->assertJsonPath('reason', 'panel_db');
    Process::assertNothingRan();
});

test('hostdb with a postgres engine is refused', function () {
    SleepFixtures::cleanup($this->dir);
    $e = SleepFixtures::fullInstall();
    $e['hostdb'] = ['kind' => 'db', 'engine' => 'postgres', 'unit' => 'postgresql@16-main.service', 'public_port' => '5432'];
    $this->dir = SleepFixtures::registry($e);
    config(['laranode.managed_dir' => $this->dir]);
    $this->actingAs(powerAdmin())->postJson('/admin/power/action', ['key' => 'hostdb', 'action' => 'enable', 'idle_minutes' => 10])
        ->assertStatus(409)->assertJsonPath('reason', 'unsupported_engine');
    Process::assertNothingRan();
});

test('fpm rejects wake/sleep (nothing to hold)', function () {
    $a = powerAdmin();
    $this->actingAs($a)->postJson('/admin/power/action', ['key' => 'fpm', 'action' => 'wake'])->assertStatus(422);
    $this->actingAs($a)->postJson('/admin/power/action', ['key' => 'fpm', 'action' => 'sleep'])->assertStatus(422);
    Process::assertNothingRan();
});

test('hostdb sleep is refused (nothing runs) when the registry records an AppArmor profile that blocks it', function () {
    SleepFixtures::cleanup($this->dir);
    $e = SleepFixtures::fullInstall();
    $e['hostdb']['apparmor'] = 'enforced';
    $this->dir = SleepFixtures::registry($e);
    config(['laranode.managed_dir' => $this->dir, 'database.default' => 'sqlite']);
    $this->actingAs(powerAdmin())->postJson('/admin/power/action', ['key' => 'hostdb', 'action' => 'enable', 'idle_minutes' => 10])
        ->assertStatus(409)->assertJsonPath('reason', 'apparmor')->assertJsonPath('message', fn ($m) => str_contains($m, 'AppArmor'));
    Process::assertNothingRan();
});
