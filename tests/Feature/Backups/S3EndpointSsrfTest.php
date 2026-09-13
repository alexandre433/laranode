<?php

// tests/Feature/Backups/S3EndpointSsrfTest.php

use App\Models\Database as DatabaseModel;
use App\Models\User;
use Illuminate\Support\Facades\Queue;
use Illuminate\Support\Facades\Storage;

// s3_endpoint lets a user point the backup disk at an arbitrary host, so it must
// not accept an internal address (169.254.169.254 metadata, RFC-1918, loopback).
// Requests use IP literals so gethostbyname() needs no DNS resolution.

function makeBackupRequestUser(): array
{
    $user = User::factory()->create(['role' => 'user']);
    DatabaseModel::factory()->create([
        'user_id' => $user->id,
        'name' => 's3ssrf_ln',
        'engine' => 'mysql',
        'db_password' => 'secret',
    ]);

    return [$user, [
        'type' => 'db',
        'target' => 's3ssrf_ln',
        'storage' => 's3',
        's3_key' => 'AKIAIOSFODNN7EXAMPLE',
        's3_secret' => 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
        's3_region' => 'us-east-1',
        's3_bucket' => 'my-backups',
    ]];
}

test('POST /backups returns 422 for a non-public s3_endpoint', function (string $endpoint) {
    Storage::fake('backups');
    Queue::fake();

    [$user, $payload] = makeBackupRequestUser();
    $this->actingAs($user);

    $response = $this->postJson('/backups', $payload + ['s3_endpoint' => $endpoint]);

    $response->assertStatus(422);
    $response->assertJsonValidationErrors(['s3_endpoint']);
})->with([
    'cloud metadata over http' => ['http://169.254.169.254'],
    'loopback over https' => ['https://127.0.0.1:9000'],
    'rfc1918 over https' => ['https://10.0.0.5'],
]);

test('POST /backups/schedules returns 422 for a non-public s3_endpoint', function () {
    Queue::fake();

    [$user, $payload] = makeBackupRequestUser();
    $this->actingAs($user);

    $response = $this->postJson('/backups/schedules', $payload + [
        's3_endpoint' => 'https://192.168.1.10',
        'cron_expression' => '0 2 * * *',
        'retention_count' => 7,
    ]);

    $response->assertStatus(422);
    $response->assertJsonValidationErrors(['s3_endpoint']);
});

test('POST /backups accepts a public https s3_endpoint', function () {
    Storage::fake('backups');
    Queue::fake();

    [$user, $payload] = makeBackupRequestUser();
    $this->actingAs($user);

    // 93.184.216.34 is example.com's public IP — an IP literal keeps this DNS-free.
    $response = $this->postJson('/backups', $payload + ['s3_endpoint' => 'https://93.184.216.34']);

    $response->assertStatus(200);
});
