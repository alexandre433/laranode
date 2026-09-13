<?php

// tests/Feature/Websites/InstallRuntimeServiceTest.php
//
// Graceful degradation when an alternative runtime (FrankenPHP) is absent from
// the host. ensureInstalled() must raise the domain InstallRuntimeException
// with an actionable message instead of letting a bare process failure escape,
// and the failure must reach the user as a failed operation with visible output.

use App\Jobs\SwitchRuntimeOperationJob;
use App\Models\Operation;
use App\Models\PhpVersion;
use App\Models\User;
use App\Services\Websites\InstallRuntimeException;
use App\Services\Websites\InstallRuntimeService;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Process;

test('InstallRuntimeService does not throw when the runtime install script succeeds', function () {
    Process::fake(['*' => Process::result(output: 'FrankenPHP installed successfully.', exitCode: 0)]);

    $lines = [];

    (new InstallRuntimeService)->ensureInstalled('frankenphp', function (string $line) use (&$lines) {
        $lines[] = $line;
    });

    expect($lines)->toBe(['Installing frankenphp runtime...']);
});

test('InstallRuntimeService surfaces the script stderr in the InstallRuntimeException', function () {
    Process::fake(['*' => Process::result(
        output: '',
        errorOutput: 'curl: (6) Could not resolve host: github.com',
        exitCode: 1,
    )]);

    $exception = null;

    try {
        (new InstallRuntimeService)->ensureInstalled('frankenphp', fn () => null);
    } catch (InstallRuntimeException $e) {
        $exception = $e;
    }

    expect($exception)->toBeInstanceOf(InstallRuntimeException::class);
    expect($exception->getMessage())
        ->toContain('Failed to install frankenphp runtime')
        ->toContain('Could not resolve host');
});

test('InstallRuntimeService gives an actionable message when the install script fails silently', function () {
    // laranode-runtime-install.sh runs with `set -e` and silent curl, so a failed
    // download aborts it with empty stderr. The exception must still say something
    // useful rather than dangling after a colon.
    Process::fake(['*' => Process::result(output: '', errorOutput: '', exitCode: 1)]);

    $exception = null;

    try {
        (new InstallRuntimeService)->ensureInstalled('frankenphp', fn () => null);
    } catch (InstallRuntimeException $e) {
        $exception = $e;
    }

    expect($exception)->toBeInstanceOf(InstallRuntimeException::class);
    expect($exception->getMessage())
        ->toContain('Failed to install frankenphp runtime')
        ->toContain('exit code 1')
        ->toContain('no error output');
});

test('absent FrankenPHP fails the runtime switch operation with the error visible in its output', function () {
    Event::fake();

    // The install script fails; every other privileged call would succeed.
    Process::fake(function ($process) {
        $cmd = is_array($process->command) ? implode(' ', $process->command) : (string) $process->command;

        if (str_contains($cmd, 'laranode-runtime-install.sh')) {
            return Process::result(output: '', errorOutput: '', exitCode: 1);
        }

        return Process::result(output: '', exitCode: 0);
    });

    $php = PhpVersion::firstOrCreate(['version' => '8.4'], ['active' => true, 'is_default' => true]);
    $owner = User::factory()->create();
    $site = $owner->websites()->create([
        'url' => 'nofranken.test',
        'document_root' => '/public',
        'php_version_id' => $php->id,
        'runtime' => 'php-fpm',
        'runtime_port' => null,
    ]);
    $site->load('user');

    $op = Operation::create([
        'user_id' => $owner->id,
        'type' => 'runtime.switch',
        'target' => $site->url,
        'status' => 'queued',
    ]);

    expect(fn () => (new SwitchRuntimeOperationJob($op, $site, 'frankenphp'))->handle())
        ->toThrow(InstallRuntimeException::class);

    $op->refresh();

    expect($op->status)->toBe('failed')
        ->and($op->output)->toContain('ERROR: Failed to install frankenphp runtime')
        ->and($op->output)->toContain('no error output');

    // Site keeps serving on its previous runtime — no half-applied state.
    expect($site->fresh()->runtime)->toBe('php-fpm')
        ->and($site->fresh()->runtime_port)->toBeNull();
});
