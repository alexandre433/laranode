<?php

use App\Jobs\OperationJob;
use App\Models\Operation;
use App\Models\User;
use App\Notifications\OperationFinishedNotification;
use Illuminate\Support\Facades\Notification;

// ---- Inline test-double subclasses ----

class NotifySucceedingJob extends OperationJob
{
    protected function run(callable $emit): int
    {
        $emit('working');

        return 0;
    }
}

class NotifyThrowingJob extends OperationJob
{
    protected function run(callable $emit): int
    {
        throw new \RuntimeException('job boom');
    }
}

// ---- Tests ----

test('notifyUser set on success -> OperationFinishedNotification dispatched', function () {
    Notification::fake();

    $user = User::factory()->create();
    $op = Operation::create(['user_id' => $user->id, 'type' => 'test.op']);

    $job = new NotifySucceedingJob($op);
    $job->notifyUser = $user;
    $job->handle();

    Notification::assertSentTo($user, OperationFinishedNotification::class);
});

test('notifyUser set on failure -> notification dispatched AND exception propagates', function () {
    Notification::fake();

    $user = User::factory()->create();
    $op = Operation::create(['user_id' => $user->id, 'type' => 'test.op']);

    $job = new NotifyThrowingJob($op);
    $job->notifyUser = $user;

    expect(fn () => $job->handle())->toThrow(\RuntimeException::class, 'job boom');

    Notification::assertSentTo($user, OperationFinishedNotification::class);
});

test('notifyUser null -> Notification::assertNothingSent', function () {
    Notification::fake();

    $user = User::factory()->create();
    $op = Operation::create(['user_id' => $user->id, 'type' => 'test.op']);

    $job = new NotifySucceedingJob($op);
    // notifyUser intentionally not set (null by default)
    $job->handle();

    Notification::assertNothingSent();
});
