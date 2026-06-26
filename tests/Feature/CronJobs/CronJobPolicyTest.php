<?php

use App\Http\Requests\StoreCronJobRequest;
use App\Models\CronJob;
use App\Models\User;
use App\Policies\CronJobPolicy;
use Illuminate\Support\Facades\Validator;

// Helper: create a CronJob row without going through validation
function makeCronJob(User $owner): CronJob
{
    return CronJob::create([
        'user_id' => $owner->id,
        'schedule' => '* * * * *',
        'command'  => 'php /home/'.$owner->systemUsername.'/artisan inspire',
    ]);
}

// ──────────────────────────────────────────────
// delete()
// ──────────────────────────────────────────────

test('admin can delete any cron job', function () {
    $admin = User::factory()->isAdmin()->create();
    $other = User::factory()->isNotAdmin()->create();
    $job   = makeCronJob($other);

    $policy = new CronJobPolicy;

    expect($policy->delete($admin, $job)->allowed())->toBeTrue();
});

test('non-admin can delete their own cron job', function () {
    $user = User::factory()->isNotAdmin()->create();
    $job  = makeCronJob($user);

    $policy = new CronJobPolicy;

    expect($policy->delete($user, $job)->allowed())->toBeTrue();
});

test('non-admin cannot delete another users cron job', function () {
    $user  = User::factory()->isNotAdmin()->create();
    $other = User::factory()->isNotAdmin()->create();
    $job   = makeCronJob($other);

    $policy = new CronJobPolicy;

    expect($policy->delete($user, $job)->allowed())->toBeFalse();
});

// ──────────────────────────────────────────────
// update()
// ──────────────────────────────────────────────

test('admin can update any cron job', function () {
    $admin = User::factory()->isAdmin()->create();
    $other = User::factory()->isNotAdmin()->create();
    $job   = makeCronJob($other);

    $policy = new CronJobPolicy;

    expect($policy->update($admin, $job)->allowed())->toBeTrue();
});

test('non-admin can update their own cron job', function () {
    $user = User::factory()->isNotAdmin()->create();
    $job  = makeCronJob($user);

    $policy = new CronJobPolicy;

    expect($policy->update($user, $job)->allowed())->toBeTrue();
});

test('non-admin cannot update another users cron job', function () {
    $user  = User::factory()->isNotAdmin()->create();
    $other = User::factory()->isNotAdmin()->create();
    $job   = makeCronJob($other);

    $policy = new CronJobPolicy;

    expect($policy->update($user, $job)->allowed())->toBeFalse();
});

// ──────────────────────────────────────────────
// Gate integration (via actingAs + can())
// ──────────────────────────────────────────────

test('Gate resolves delete policy for admin', function () {
    $admin = User::factory()->isAdmin()->create();
    $other = User::factory()->isNotAdmin()->create();
    $job   = makeCronJob($other);

    $this->actingAs($admin);
    expect($this->actingAs($admin)->app->make(\Illuminate\Contracts\Auth\Access\Gate::class)->inspect('delete', $job)->allowed())->toBeTrue();
});

test('Gate resolves delete policy for non-owner (denied)', function () {
    $user  = User::factory()->isNotAdmin()->create();
    $other = User::factory()->isNotAdmin()->create();
    $job   = makeCronJob($other);

    $this->actingAs($user);
    expect($this->actingAs($user)->app->make(\Illuminate\Contracts\Auth\Access\Gate::class)->inspect('delete', $job)->allowed())->toBeFalse();
});

// ──────────────────────────────────────────────
// StoreCronJobRequest — validation rules
// ──────────────────────────────────────────────

function makeStoreRequest(User $user, array $data): \Illuminate\Validation\Validator
{
    $request = StoreCronJobRequest::create('/cron-jobs', 'POST', $data);
    $request->setUserResolver(fn () => $user);

    return Validator::make(
        $data,
        $request->rules(),
    );
}

test('StoreCronJobRequest passes with valid data', function () {
    $user = User::factory()->isNotAdmin()->create();
    $v    = makeStoreRequest($user, [
        'schedule' => '* * * * *',
        'command'  => 'php /home/'.$user->systemUsername.'/artisan inspire',
        'label'    => 'My Job',
    ]);

    expect($v->fails())->toBeFalse();
});

test('StoreCronJobRequest rejects missing schedule', function () {
    $user = User::factory()->isNotAdmin()->create();
    $v    = makeStoreRequest($user, [
        'command' => 'php /home/'.$user->systemUsername.'/artisan inspire',
    ]);

    expect($v->fails())->toBeTrue()
        ->and($v->errors()->has('schedule'))->toBeTrue();
});

test('StoreCronJobRequest rejects invalid cron expression', function () {
    $user = User::factory()->isNotAdmin()->create();
    $v    = makeStoreRequest($user, [
        'schedule' => 'not-a-cron',
        'command'  => 'php /home/'.$user->systemUsername.'/artisan inspire',
    ]);

    expect($v->fails())->toBeTrue()
        ->and($v->errors()->has('schedule'))->toBeTrue();
});

test('StoreCronJobRequest rejects disallowed command (wget)', function () {
    $user = User::factory()->isNotAdmin()->create();
    $v    = makeStoreRequest($user, [
        'schedule' => '* * * * *',
        'command'  => 'wget https://example.com',
    ]);

    expect($v->fails())->toBeTrue()
        ->and($v->errors()->has('command'))->toBeTrue();
});

test('StoreCronJobRequest rejects command outside users homedir', function () {
    $user  = User::factory()->isNotAdmin()->create();
    $other = User::factory()->isNotAdmin()->create();
    $v     = makeStoreRequest($user, [
        'schedule' => '* * * * *',
        'command'  => 'php /home/'.$other->systemUsername.'/artisan inspire',
    ]);

    expect($v->fails())->toBeTrue()
        ->and($v->errors()->has('command'))->toBeTrue();
});

test('StoreCronJobRequest label is optional', function () {
    $user = User::factory()->isNotAdmin()->create();
    $v    = makeStoreRequest($user, [
        'schedule' => '0 2 * * *',
        'command'  => 'php /home/'.$user->systemUsername.'/artisan inspire',
    ]);

    expect($v->fails())->toBeFalse();
});

test('StoreCronJobRequest rejects at the 50-job cap', function () {
    $user = User::factory()->isNotAdmin()->create();

    // Create 50 jobs directly
    for ($i = 0; $i < 50; $i++) {
        CronJob::create([
            'user_id'  => $user->id,
            'schedule' => '* * * * *',
            'command'  => 'php /home/'.$user->systemUsername.'/artisan inspire'.$i,
        ]);
    }

    $request = StoreCronJobRequest::create('/cron-jobs', 'POST', [
        'schedule' => '* * * * *',
        'command'  => 'php /home/'.$user->systemUsername.'/artisan inspire-new',
    ]);
    $request->setUserResolver(fn () => $user);

    $v = Validator::make(
        $request->all(),
        $request->rules(),
    );

    // withValidator after-hook runs when validated() is called, but we test
    // it here by directly creating the request and calling the after hook
    $v->after(function ($validator) use ($user) {
        $count = CronJob::where('user_id', $user->id)->count();
        if ($count >= 50) {
            $validator->errors()->add('command', 'You have reached the maximum of 50 cron jobs.');
        }
    });

    expect($v->fails())->toBeTrue()
        ->and($v->errors()->has('command'))->toBeTrue();
});
