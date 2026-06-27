<?php

use App\Models\CronJob;
use App\Models\User;
use App\Services\CronJobs\CreateCronJobException;
use App\Services\CronJobs\CreateCronJobService;
use App\Services\CronJobs\DeleteCronJobException;
use App\Services\CronJobs\DeleteCronJobService;
use Illuminate\Support\Facades\Process;

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

function makeCronJobRow(User $user, string $schedule = '* * * * *', string $suffix = ''): CronJob
{
    return CronJob::create([
        'user_id' => $user->id,
        'schedule' => $schedule,
        'command' => 'php /home/'.$user->systemUsername.'/artisan inspire'.$suffix,
        'active' => true,
    ]);
}

// ─────────────────────────────────────────────────────────────────────────────
// CreateCronJobService
// ─────────────────────────────────────────────────────────────────────────────

test('CreateCronJobService calls laranode-cron.sh set with system username and tmp file', function () {
    Process::fake();

    $user = User::factory()->isNotAdmin()->create(['username' => 'alice']);
    makeCronJobRow($user);

    (new CreateCronJobService)->handle($user);

    Process::assertRan(function ($process) use ($user) {
        $command = $process->command;

        // command is an array: [sudo, .../laranode-cron.sh, set, systemUsername, tmpFile]
        return is_array($command)
            && str_ends_with($command[1] ?? '', 'laranode-cron.sh')
            && ($command[2] ?? '') === 'set'
            && ($command[3] ?? '') === $user->systemUsername;
    });
});

test('CreateCronJobService only passes active jobs to the script', function () {
    $capturedContent = null;

    Process::fake(function ($invocation) use (&$capturedContent) {
        $command = $invocation->command;
        // 5th arg is the tmp file path
        $tmpFile = $command[4] ?? null;
        if ($tmpFile && file_exists($tmpFile)) {
            $capturedContent = file_get_contents($tmpFile);
        }

        return Process::result(exitCode: 0);
    });

    $user = User::factory()->isNotAdmin()->create(['username' => 'bob']);
    $active = makeCronJobRow($user, '* * * * *', '_active');
    $inactive = CronJob::create([
        'user_id' => $user->id,
        'schedule' => '0 2 * * *',
        'command' => 'php /home/'.$user->systemUsername.'/artisan foo',
        'active' => false,
    ]);

    (new CreateCronJobService)->handle($user);

    expect($capturedContent)->toContain($active->command)
        ->and($capturedContent)->not->toContain($inactive->command);
});

test('CreateCronJobService throws CreateCronJobException when script fails', function () {
    Process::fake([
        '*' => Process::result(output: '', errorOutput: 'script error', exitCode: 1),
    ]);

    $user = User::factory()->isNotAdmin()->create(['username' => 'charlie']);
    makeCronJobRow($user);

    expect(fn () => (new CreateCronJobService)->handle($user))
        ->toThrow(CreateCronJobException::class);
});

test('CreateCronJobService cleans up tmp file even on failure', function () {
    $tmpFilePath = null;

    Process::fake(function ($invocation) use (&$tmpFilePath) {
        $command = $invocation->command;
        $tmpFilePath = $command[4] ?? null;

        return Process::result(exitCode: 1);
    });

    $user = User::factory()->isNotAdmin()->create(['username' => 'dave']);
    makeCronJobRow($user);

    try {
        (new CreateCronJobService)->handle($user);
    } catch (CreateCronJobException) {
        // expected
    }

    expect($tmpFilePath)->not->toBeNull()
        ->and(file_exists($tmpFilePath))->toBeFalse('temp file should be deleted after failure');
});

// ─────────────────────────────────────────────────────────────────────────────
// DeleteCronJobService
// ─────────────────────────────────────────────────────────────────────────────

test('DeleteCronJobService calls laranode-cron.sh set with remaining jobs (excluding deleted)', function () {
    $capturedContent = null;

    Process::fake(function ($invocation) use (&$capturedContent) {
        $command = $invocation->command;
        $tmpFile = $command[4] ?? null;
        if ($tmpFile && file_exists($tmpFile)) {
            $capturedContent = file_get_contents($tmpFile);
        }

        return Process::result(exitCode: 0);
    });

    $user = User::factory()->isNotAdmin()->create(['username' => 'eve']);
    $jobToKeep = makeCronJobRow($user, '0 1 * * *', '_keep');
    $jobToDelete = makeCronJobRow($user, '0 2 * * *', '_delete');

    (new DeleteCronJobService)->handle($user, $jobToDelete);

    expect($capturedContent)->toContain($jobToKeep->command)
        ->and($capturedContent)->not->toContain($jobToDelete->command);
});

test('DeleteCronJobService passes correct system username to script', function () {
    Process::fake();

    $user = User::factory()->isNotAdmin()->create(['username' => 'frank']);
    $job = makeCronJobRow($user);

    (new DeleteCronJobService)->handle($user, $job);

    Process::assertRan(function ($process) use ($user) {
        $command = $process->command;

        return is_array($command)
            && str_ends_with($command[1] ?? '', 'laranode-cron.sh')
            && ($command[2] ?? '') === 'set'
            && ($command[3] ?? '') === $user->systemUsername;
    });
});

test('DeleteCronJobService throws DeleteCronJobException when script fails', function () {
    Process::fake([
        '*' => Process::result(output: '', errorOutput: 'script error', exitCode: 1),
    ]);

    $user = User::factory()->isNotAdmin()->create(['username' => 'grace']);
    $job = makeCronJobRow($user);

    expect(fn () => (new DeleteCronJobService)->handle($user, $job))
        ->toThrow(DeleteCronJobException::class);
});

test('DeleteCronJobService excludes inactive jobs from the sync', function () {
    $capturedContent = null;

    Process::fake(function ($invocation) use (&$capturedContent) {
        $command = $invocation->command;
        $tmpFile = $command[4] ?? null;
        if ($tmpFile && file_exists($tmpFile)) {
            $capturedContent = file_get_contents($tmpFile);
        }

        return Process::result(exitCode: 0);
    });

    $user = User::factory()->isNotAdmin()->create(['username' => 'henry']);
    $activeJob = makeCronJobRow($user, '0 3 * * *', '_active');
    $inactiveJob = CronJob::create([
        'user_id' => $user->id,
        'schedule' => '0 4 * * *',
        'command' => 'php /home/'.$user->systemUsername.'/artisan inactive',
        'active' => false,
    ]);
    $jobToDelete = makeCronJobRow($user, '0 5 * * *', '_delete');

    (new DeleteCronJobService)->handle($user, $jobToDelete);

    // Only the active job that's NOT being deleted should appear
    expect($capturedContent)->toContain($activeJob->command)
        ->and($capturedContent)->not->toContain($inactiveJob->command)
        ->and($capturedContent)->not->toContain($jobToDelete->command);
});
