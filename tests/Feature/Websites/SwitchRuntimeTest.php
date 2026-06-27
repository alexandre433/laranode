<?php

// tests/Feature/Websites/SwitchRuntimeTest.php

use App\Jobs\SwitchRuntimeOperationJob;
use App\Models\Operation;
use App\Models\PhpVersion;
use App\Models\User;
use App\Models\Website;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Process;
use Illuminate\Support\Facades\Queue;

/**
 * Helper: create a website owned by a user with a real PHP version row.
 */
function makeWebsiteFor(User $owner): Website
{
    $php = PhpVersion::firstOrCreate(['version' => '8.4'], ['active' => true, 'is_default' => true]);

    return $owner->websites()->create([
        'url' => 'example-rt.test',
        'document_root' => '/public',
        'php_version_id' => $php->id,
        'runtime' => 'php-fpm',
        'runtime_port' => null,
    ]);
}

// ── Authorization ─────────────────────────────────────────────────────────────

test('unauthenticated user is redirected to login', function () {
    $site = makeWebsiteFor(User::factory()->create());

    $this->postJson(route('websites.runtime.switch', $site), ['runtime' => 'frankenphp'])
        ->assertUnauthorized();
});

test('non-owner gets 403', function () {
    Event::fake();
    $owner = User::factory()->create();
    $other = User::factory()->create();
    $site = makeWebsiteFor($owner);

    $this->actingAs($other)
        ->postJson(route('websites.runtime.switch', $site), ['runtime' => 'frankenphp'])
        ->assertForbidden();
});

// ── Validation ────────────────────────────────────────────────────────────────

test('runtime=swoole is rejected with 422', function () {
    $owner = User::factory()->create();
    $site = makeWebsiteFor($owner);

    $this->actingAs($owner)
        ->postJson(route('websites.runtime.switch', $site), ['runtime' => 'swoole'])
        ->assertUnprocessable();
});

test('empty runtime is rejected with 422', function () {
    $owner = User::factory()->create();
    $site = makeWebsiteFor($owner);

    $this->actingAs($owner)
        ->postJson(route('websites.runtime.switch', $site), ['runtime' => ''])
        ->assertUnprocessable();
});

test('missing runtime is rejected with 422', function () {
    $owner = User::factory()->create();
    $site = makeWebsiteFor($owner);

    $this->actingAs($owner)
        ->postJson(route('websites.runtime.switch', $site), [])
        ->assertUnprocessable();
});

test('runtime=../etc/passwd is rejected with 422', function () {
    $owner = User::factory()->create();
    $site = makeWebsiteFor($owner);

    $this->actingAs($owner)
        ->postJson(route('websites.runtime.switch', $site), ['runtime' => '../etc/passwd'])
        ->assertUnprocessable();
});

test('runtime="; rm -rf /" is rejected with 422', function () {
    $owner = User::factory()->create();
    $site = makeWebsiteFor($owner);

    $this->actingAs($owner)
        ->postJson(route('websites.runtime.switch', $site), ['runtime' => '; rm -rf /'])
        ->assertUnprocessable();
});

// ── Happy path ────────────────────────────────────────────────────────────────

test('owner switching to frankenphp returns 200 JSON with operation_id, operation succeeds, runtime saved', function () {
    Event::fake();
    Process::fake(['*' => Process::result(output: '', exitCode: 0)]);

    $owner = User::factory()->create();
    $site = makeWebsiteFor($owner);

    $response = $this->actingAs($owner)
        ->postJson(route('websites.runtime.switch', $site), ['runtime' => 'frankenphp']);

    $response->assertOk()->assertJsonStructure(['operation_id']);

    $op = Operation::findOrFail($response->json('operation_id'));
    // Under QUEUE_CONNECTION=sync the job runs inline.
    expect($op->type)->toBe('runtime.switch')
        ->and($op->user_id)->toBe($owner->id)
        ->and($op->status)->toBe('succeeded');

    expect($site->fresh()->runtime)->toBe('frankenphp');
    expect($site->fresh()->runtime_port)->toBeInt()->toBeGreaterThanOrEqual(9100)->toBeLessThanOrEqual(9499);
});

// ── Script failure paths ──────────────────────────────────────────────────────

test('laranode-runtime-install.sh exit 1 marks operation failed and leaves runtime unchanged', function () {
    Event::fake();

    // install script fails, all others succeed
    Process::fake(function ($process) {
        $cmd = is_array($process->command) ? implode(' ', $process->command) : (string) $process->command;
        if (str_contains($cmd, 'laranode-runtime-install.sh')) {
            return Process::result(output: '', errorOutput: 'install failed', exitCode: 1);
        }

        return Process::result(output: '', exitCode: 0);
    });

    $php = PhpVersion::firstOrCreate(['version' => '8.4'], ['active' => true, 'is_default' => true]);
    $owner = User::factory()->create();
    $site = $owner->websites()->create([
        'url' => 'installfail.test',
        'document_root' => '/public',
        'php_version_id' => $php->id,
        'runtime' => 'php-fpm',
    ]);
    $site->load('user');

    $op = Operation::create([
        'user_id' => $owner->id,
        'type' => 'runtime.switch',
        'target' => $site->url,
        'status' => 'queued',
    ]);

    expect(fn () => (new SwitchRuntimeOperationJob($op, $site, 'frankenphp'))->handle())
        ->toThrow(\Exception::class);

    expect($op->fresh()->status)->toBe('failed');
    expect($site->fresh()->runtime)->toBe('php-fpm');
});

test('laranode-vhost-switch.sh exit 1 marks operation failed and leaves runtime unchanged', function () {
    Event::fake();

    $php = PhpVersion::firstOrCreate(['version' => '8.4'], ['active' => true, 'is_default' => true]);
    $owner = User::factory()->create();
    $failSite = $owner->websites()->create([
        'url' => 'vhostfail.test',
        'document_root' => '/public',
        'php_version_id' => $php->id,
        'runtime' => 'php-fpm',
    ]);
    $failSite->load('user');

    // vhost-switch fails, all others succeed
    Process::fake(function ($process) {
        $cmd = is_array($process->command) ? implode(' ', $process->command) : (string) $process->command;
        if (str_contains($cmd, 'laranode-vhost-switch.sh')) {
            return Process::result(output: '', errorOutput: 'vhost fail', exitCode: 1);
        }

        return Process::result(output: '', exitCode: 0);
    });

    $op = Operation::create([
        'user_id' => $owner->id,
        'type' => 'runtime.switch',
        'target' => $failSite->url,
        'status' => 'queued',
    ]);

    expect(fn () => (new SwitchRuntimeOperationJob($op, $failSite, 'frankenphp'))->handle())
        ->toThrow(\Exception::class);

    expect($op->fresh()->status)->toBe('failed');
    expect($failSite->fresh()->runtime)->toBe('php-fpm');
});

// ── PHP version guard ─────────────────────────────────────────────────────────

test('PATCH website with frankenphp runtime redirects back with errors (not JSON 422)', function () {
    $owner = User::factory()->create();
    $php = PhpVersion::firstOrCreate(['version' => '8.4'], ['active' => true, 'is_default' => true]);

    $site = $owner->websites()->create([
        'url' => 'franken.test',
        'document_root' => '/public',
        'php_version_id' => $php->id,
        'runtime' => 'frankenphp',
        'runtime_port' => 9100,
    ]);

    $response = $this->actingAs($owner)
        ->patch(route('websites.update', $site), ['php_version_id' => $php->id]);

    $response->assertRedirect();
    $response->assertSessionHasErrors('runtime');
    expect($site->fresh()->php_version_id)->toBe($php->id);
});
