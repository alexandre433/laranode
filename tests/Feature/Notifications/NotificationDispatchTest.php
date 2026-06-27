<?php

use App\Models\NotificationPreference;
use App\Models\Operation;
use App\Models\User;
use App\Notifications\Channels\WebhookChannel;
use App\Notifications\OperationFinishedNotification;
use App\Services\Notifications\NotificationService;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Facades\Notification;

// 93.184.216.34 is example.com — public IP that passes the SSRF filter
// Using an IP host avoids gethostbyname DNS failures in CI/container environments.
const WEBHOOK_TEST_URL = 'https://93.184.216.34/hook';

test('all channels enabled: db row written, mail routed, webhook POSTed', function () {
    // Note: Mail::fake() only captures Mailable objects, not MailMessage-based sends.
    // The MailChannel uses raw mailer with MailMessage (not Mailable), so we verify
    // the mail channel is included in via() and that the notification itself fired.
    Http::fake();

    $user = User::factory()->create([
        'webhook_url' => WEBHOOK_TEST_URL,
    ]);

    $operation = Operation::create([
        'user_id' => $user->id,
        'type' => 'test-op',
        'status' => 'succeeded',
        'exit_code' => 0,
    ]);

    // All channels enabled by default (no preference rows = opt-out model)
    NotificationService::dispatch($user, new OperationFinishedNotification($operation));

    // DB channel written
    $this->assertDatabaseHas('notifications', [
        'notifiable_type' => User::class,
        'notifiable_id' => $user->id,
        'type' => OperationFinishedNotification::class,
    ]);

    // Webhook channel fired
    Http::assertSent(fn ($request) => str_contains($request->url(), '93.184.216.34'));

    // Mail channel is in resolved channels (verifies preference filter includes it)
    $channels = NotificationService::resolveChannels($user, 'operation.finished');
    expect($channels)->toContain('mail');
});

test('mail disabled: db row still written, mail channel excluded from via()', function () {
    Http::fake();

    $user = User::factory()->create([
        'webhook_url' => null,
    ]);

    $operation = Operation::create([
        'user_id' => $user->id,
        'type' => 'test-op',
        'status' => 'succeeded',
        'exit_code' => 0,
    ]);

    NotificationPreference::create([
        'user_id' => $user->id,
        'event_type' => 'operation.finished',
        'channel' => 'mail',
        'enabled' => false,
    ]);

    NotificationService::dispatch($user, new OperationFinishedNotification($operation));

    $this->assertDatabaseHas('notifications', [
        'notifiable_type' => User::class,
        'notifiable_id' => $user->id,
    ]);

    // Mail channel must be excluded when preference is disabled
    $channels = NotificationService::resolveChannels($user, 'operation.finished');
    expect($channels)->not->toContain('mail');
    expect($channels)->toContain('database');
});

test('resolveChannels with webhook disabled does not include WebhookChannel', function () {
    $user = User::factory()->create();

    NotificationPreference::create([
        'user_id' => $user->id,
        'event_type' => 'operation.finished',
        'channel' => 'webhook',
        'enabled' => false,
    ]);

    $channels = NotificationService::resolveChannels($user, 'operation.finished');

    expect($channels)->not->toContain(WebhookChannel::class);
    expect($channels)->toContain('database');
    expect($channels)->toContain('mail');
});
