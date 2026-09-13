<?php

use App\Models\User;
use Illuminate\Support\Facades\Process;

// The firewall must never be enabled without SSH + panel/web allow rules,
// otherwise the operator is locked out of the server. The guard protects the
// HTTP endpoint directly (not just the UI).

function cmdString($process): string
{
    return is_array($process->command) ? implode(' ', $process->command) : (string) $process->command;
}

// All privileged firewall calls go through the allowlisted wrapper; the sudoers
// drop-in grants www-data nothing else.
function ufwWrapper(): string
{
    return config('laranode.laranode_bin_path').'/laranode-ufw.sh';
}

function fakeUfw(string $addedOutput): void
{
    // A closure fake is needed because Laravel's pattern-map matching casts an
    // array command to the literal string "Array", so the wrapper's
    // `show-added` call would never match our array-form Process::run([...]) calls.
    Process::fake(function ($process) use ($addedOutput) {
        return str_contains(cmdString($process), 'laranode-ufw.sh show-added')
            ? Process::result(output: $addedOutput)
            : Process::result(output: 'ok');
    });
}

test('enabling is refused when no SSH rule is staged (no lockout)', function () {
    fakeUfw("Added user rules:\nufw allow 80/tcp\n");

    $admin = User::factory()->isAdmin()->create();

    $response = $this->actingAs($admin)
        ->post(route('firewall.toggle'), ['enabled' => true]);

    $response->assertRedirect(route('firewall.index'));
    $response->assertSessionHas('error');

    // ufw enable must NOT have run
    Process::assertDidntRun(fn ($p) => cmdString($p) === 'sudo '.ufwWrapper().' enable');
});

test('enabling is refused when no panel/web rule is staged', function () {
    fakeUfw("Added user rules:\nufw allow 22/tcp\n");

    $admin = User::factory()->isAdmin()->create();

    $response = $this->actingAs($admin)
        ->post(route('firewall.toggle'), ['enabled' => true]);

    $response->assertSessionHas('error');
    Process::assertDidntRun(fn ($p) => cmdString($p) === 'sudo '.ufwWrapper().' enable');
});

test('enabling succeeds when SSH and web rules are both staged', function () {
    fakeUfw("Added user rules:\nufw allow 22/tcp\nufw allow 80/tcp\n");

    $admin = User::factory()->isAdmin()->create();

    $response = $this->actingAs($admin)
        ->post(route('firewall.toggle'), ['enabled' => true]);

    $response->assertSessionHas('success');
    Process::assertRan(fn ($p) => cmdString($p) === 'sudo '.ufwWrapper().' enable');
});

test('disabling is always allowed regardless of staged rules', function () {
    fakeUfw("Added user rules:\n");

    $admin = User::factory()->isAdmin()->create();

    $response = $this->actingAs($admin)
        ->post(route('firewall.toggle'), ['enabled' => false]);

    $response->assertSessionHas('success');
    $response->assertSessionMissing('error');
});

test('safe setup stages SSH + HTTP + HTTPS allow rules and then enables', function () {
    Process::fake(['*' => Process::result(output: 'ok')]);

    $admin = User::factory()->isAdmin()->create();

    $this->actingAs($admin)
        ->post(route('firewall.safe-setup'))
        ->assertSessionHas('success');

    Process::assertRan(fn ($p) => cmdString($p) === 'sudo '.ufwWrapper().' allow 22/tcp');
    Process::assertRan(fn ($p) => cmdString($p) === 'sudo '.ufwWrapper().' allow 80/tcp');
    Process::assertRan(fn ($p) => cmdString($p) === 'sudo '.ufwWrapper().' allow 443/tcp');
    Process::assertRan(fn ($p) => cmdString($p) === 'sudo '.ufwWrapper().' enable');
});

test('safe setup can restrict SSH to a validated IP', function () {
    Process::fake(['*' => Process::result(output: 'ok')]);

    $admin = User::factory()->isAdmin()->create();

    $this->actingAs($admin)
        ->post(route('firewall.safe-setup'), ['ssh_from_ip' => '203.0.113.7'])
        ->assertSessionHas('success');

    Process::assertRan(fn ($p) => cmdString($p) === 'sudo '.ufwWrapper().' allow from 203.0.113.7 to any port 22 proto tcp');
    // it must NOT also open SSH to the world in that case
    Process::assertDidntRun(fn ($p) => cmdString($p) === 'sudo '.ufwWrapper().' allow 22/tcp');
});

test('safe setup rejects an invalid IP', function () {
    Process::fake(['*' => Process::result(output: 'ok')]);

    $admin = User::factory()->isAdmin()->create();

    $this->actingAs($admin)
        ->post(route('firewall.safe-setup'), ['ssh_from_ip' => 'not-an-ip'])
        ->assertSessionHasErrors('ssh_from_ip');

    Process::assertDidntRun(fn ($p) => cmdString($p) === 'sudo '.ufwWrapper().' enable');
});

test('non-admin cannot run safe setup', function () {
    Process::fake(['*' => Process::result(output: 'ok')]);

    $user = User::factory()->isNotAdmin()->create();

    $this->actingAs($user)
        ->post(route('firewall.safe-setup'))
        ->assertForbidden();
});

// The sudoers grant is scoped to laranode-ufw.sh, so the wrapper is the only
// privileged firewall surface www-data can reach. It must reject anything
// outside its subcommand allowlist and any injected flag, otherwise
// `ufw reset` / `ufw disable --force` would still be reachable through it.
test('the ufw wrapper rejects subcommands outside the allowlist and injected flags', function (array $args) {
    $script = base_path('laranode-scripts/bin/laranode-ufw.sh');

    try {
        $available = Process::run(['bash', '-lc', 'command -v bash'])->successful();
    } catch (\Throwable) {
        $available = false;
    }

    if (! $available) {
        $this->markTestSkipped('bash not available — cannot exercise the ufw wrapper here.');
    }

    $proc = Process::run(array_merge(['bash', $script], $args));

    expect($proc->exitCode())->toBe(1);
    expect($proc->errorOutput())->toContain('ERROR');
})->with([
    'reset subcommand' => [['reset']],
    'default subcommand' => [['default']],
    'unknown subcommand' => [['reload']],
    'flag injection as subcommand' => [['--force']],
    'flag injection in rule token' => [['allow', '--force']],
    'short flag in rule token' => [['allow', '-x']],
    'flag injection in delete' => [['delete', '--force']],
]);
