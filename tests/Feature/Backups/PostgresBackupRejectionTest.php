<?php

// tests/Feature/Backups/PostgresBackupRejectionTest.php

use App\Models\Backup;
use App\Models\Database as DatabaseModel;
use App\Models\Operation;
use App\Models\User;
use App\Services\Backups\BackupException;
use App\Services\Backups\BackupService;
use Illuminate\Support\Facades\Queue;
use Illuminate\Support\Facades\Storage;

// PostgreSQL backups are not implemented (PostgresBackupDriver::dump() throws and
// RestoreJob always restores via the MySQL path), so the panel must refuse to
// start one rather than failing deep inside a queued job.

test('POST /backups returns 422 for a postgres target', function () {
    Storage::fake('backups');

    $user = User::factory()->create(['role' => 'user']);
    DatabaseModel::factory()->create([
        'user_id' => $user->id,
        'name' => 'pgdb_ln',
        'engine' => 'postgres',
        'db_password' => 'secret',
    ]);

    $this->actingAs($user);

    $response = $this->postJson('/backups', [
        'type' => 'db',
        'target' => 'pgdb_ln',
        'storage' => 'local',
    ]);

    $response->assertStatus(422);
    $response->assertJsonValidationErrors(['target']);
});

test('POST /backups still accepts a mysql target', function () {
    Storage::fake('backups');
    // The engine driver is not stubbed, so keep the job queued rather than run it.
    Queue::fake();

    $user = User::factory()->create(['role' => 'user']);
    DatabaseModel::factory()->create([
        'user_id' => $user->id,
        'name' => 'mysqldb_ln',
        'engine' => 'mysql',
        'db_password' => 'secret',
    ]);

    $this->actingAs($user);

    $response = $this->postJson('/backups', [
        'type' => 'db',
        'target' => 'mysqldb_ln',
        'storage' => 'local',
    ]);

    // The postgres exclusion must not over-exclude mysql targets.
    $response->assertStatus(200);
    $response->assertJsonStructure(['operation_id']);
});

test('POST /backups/schedules returns 422 for a postgres target', function () {
    $user = User::factory()->create(['role' => 'user']);
    DatabaseModel::factory()->create([
        'user_id' => $user->id,
        'name' => 'pgdb_sched_ln',
        'engine' => 'postgres',
        'db_password' => 'secret',
    ]);

    $this->actingAs($user);

    $response = $this->postJson('/backups/schedules', [
        'type' => 'db',
        'target' => 'pgdb_sched_ln',
        'storage' => 'local',
        'cron_expression' => '0 3 * * *',
        'retention_count' => 5,
    ]);

    $response->assertStatus(422);
    $response->assertJsonValidationErrors(['target']);
});

test('BackupService::handle rejects a postgres target on the scheduled/queue path', function () {
    $user = User::factory()->create(['role' => 'user']);
    DatabaseModel::factory()->create([
        'user_id' => $user->id,
        'name' => 'pgdb_service_ln',
        'engine' => 'postgres',
        'db_password' => 'secret',
    ]);

    $service = new BackupService;

    expect(fn () => $service->handle([
        'type' => 'db',
        'target' => 'pgdb_service_ln',
        'storage' => 'local',
    ], $user))->toThrow(BackupException::class);

    // The guard runs before any rows are written or jobs dispatched.
    expect(Operation::where('user_id', $user->id)->count())->toBe(0);
    expect(Backup::where('user_id', $user->id)->count())->toBe(0);
});
