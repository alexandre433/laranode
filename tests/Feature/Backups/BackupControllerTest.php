<?php

// tests/Feature/Backups/BackupControllerTest.php

use App\Actions\Backup\TarFilesAction;
use App\Backup\BackupEngineManager;
use App\Contracts\Backup\BackupEngineDriver;
use App\Events\OperationUpdated;
use App\Models\Backup;
use App\Models\Database as DatabaseModel;
use App\Models\Operation;
use App\Models\ScheduledBackup;
use App\Models\User;
use App\Models\Website;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Storage;

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Bind a fake BackupEngineManager whose driver creates and returns a real temp file.
 */
function bindFakeDumpDriverForController(string $content = 'fake-dump-data'): void
{
    $fakeDriver = new class($content) implements BackupEngineDriver
    {
        public function __construct(private string $content) {}

        public function dump(string $dbName, string $dbUser, string $cnfFile, callable $emit): string
        {
            $path = tempnam(sys_get_temp_dir(), 'laranode-ctrl-dump-').'.sql.gz';
            file_put_contents($path, $this->content);
            $emit('Dump done (fake).');

            return $path;
        }
    };

    $fakeManager = new class($fakeDriver) extends BackupEngineManager
    {
        public function __construct(private BackupEngineDriver $driver) {}

        public function for(?string $engine): BackupEngineDriver
        {
            return $this->driver;
        }
    };

    app()->instance(BackupEngineManager::class, $fakeManager);
}

/**
 * Bind a fake TarFilesAction that creates a real temp file.
 */
function bindFakeTarFilesActionForController(string $content = 'fake-tar-data'): void
{
    $fake = new class($content) extends TarFilesAction
    {
        public function __construct(private string $content) {}

        public function execute(Website $website, string $tempPath, callable $emit): string
        {
            file_put_contents($tempPath, $this->content);
            $emit('Archive done (fake).');

            return $tempPath;
        }
    };

    app()->instance(TarFilesAction::class, $fake);
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 1: POST /backups returns operation_id; operation ends succeeded (sync queue)
// ─────────────────────────────────────────────────────────────────────────────

test('POST /backups returns operation_id for owner and operation ends succeeded', function () {
    Storage::fake('backups');
    Event::fake([OperationUpdated::class]);
    bindFakeDumpDriverForController();

    $user = User::factory()->create(['role' => 'user']);
    DatabaseModel::factory()->create([
        'user_id' => $user->id,
        'name' => 'mydb_ctrl',
        'db_password' => 'secret',
    ]);

    $this->actingAs($user);

    $response = $this->postJson('/backups', [
        'type' => 'db',
        'target' => 'mydb_ctrl',
        'storage' => 'local',
    ]);

    $response->assertStatus(200);
    $response->assertJsonStructure(['operation_id']);

    $operationId = $response->json('operation_id');
    $operation = Operation::find($operationId);
    expect($operation)->not->toBeNull();
    // With QUEUE_CONNECTION=sync the job runs inline — operation completes.
    expect($operation->status)->toBe('succeeded');
});

// ─────────────────────────────────────────────────────────────────────────────
// Test 2: POST /backups returns 422 when target DB does not belong to requesting user
// ─────────────────────────────────────────────────────────────────────────────

test('POST /backups returns 422 when target DB does not belong to requesting user', function () {
    Storage::fake('backups');

    $owner = User::factory()->create(['role' => 'user']);
    $other = User::factory()->create(['role' => 'user']);

    DatabaseModel::factory()->create([
        'user_id' => $owner->id,
        'name' => 'owners_db',
        'db_password' => 'secret',
    ]);

    $this->actingAs($other);

    $response = $this->postJson('/backups', [
        'type' => 'db',
        'target' => 'owners_db',
        'storage' => 'local',
    ]);

    $response->assertStatus(422);
    $response->assertJsonValidationErrors(['target']);
});

// ─────────────────────────────────────────────────────────────────────────────
// Test 3: DELETE /backups/{backup} removes file from disk and deletes the row
// ─────────────────────────────────────────────────────────────────────────────

test('DELETE /backups/{backup} removes file from disk and deletes the row', function () {
    Storage::fake('backups');

    $user = User::factory()->create(['role' => 'user']);

    Storage::disk('backups')->put('1/db/mydb/backup.sql.gz', 'data');

    $backup = Backup::factory()->create([
        'user_id' => $user->id,
        'type' => 'db',
        'target' => 'mydb',
        'storage' => 'local',
        'disk_name' => 'backups',
        'path' => '1/db/mydb/backup.sql.gz',
        'status' => 'completed',
    ]);

    $this->actingAs($user);

    $response = $this->delete("/backups/{$backup->id}");

    $response->assertRedirect(route('backups.index'));

    expect(Backup::find($backup->id))->toBeNull();
    Storage::disk('backups')->assertMissing('1/db/mydb/backup.sql.gz');
});

// ─────────────────────────────────────────────────────────────────────────────
// Test 4: Non-owner DELETE /backups/{backup} returns 403
// ─────────────────────────────────────────────────────────────────────────────

test('Non-owner DELETE /backups/{backup} returns 403', function () {
    Storage::fake('backups');

    $owner = User::factory()->create(['role' => 'user']);
    $other = User::factory()->create(['role' => 'user']);

    $backup = Backup::factory()->create([
        'user_id' => $owner->id,
        'status' => 'completed',
        'disk_name' => 'backups',
        'path' => null,
    ]);

    $this->actingAs($other);

    $response = $this->delete("/backups/{$backup->id}");

    $response->assertStatus(403);
    expect(Backup::find($backup->id))->not->toBeNull();
});

// ─────────────────────────────────────────────────────────────────────────────
// Test 5: POST /backups/{backup}/restore returns 422 for empty new_target
// ─────────────────────────────────────────────────────────────────────────────

test('POST /backups/{backup}/restore returns 422 for empty new_target', function () {
    Storage::fake('backups');

    $user = User::factory()->create(['role' => 'user']);
    $backup = Backup::factory()->create([
        'user_id' => $user->id,
        'type' => 'db',
        'target' => 'sourcedb',
        'status' => 'completed',
    ]);

    $this->actingAs($user);

    $response = $this->postJson("/backups/{$backup->id}/restore", [
        'new_target' => '',
    ]);

    $response->assertStatus(422);
    $response->assertJsonValidationErrors(['new_target']);
});

// ─────────────────────────────────────────────────────────────────────────────
// Test 6: POST /backups/{backup}/restore returns 422 when new_target === source
// ─────────────────────────────────────────────────────────────────────────────

test('POST /backups/{backup}/restore returns 422 when new_target equals backup target', function () {
    Storage::fake('backups');

    $user = User::factory()->create(['role' => 'user']);
    $backup = Backup::factory()->create([
        'user_id' => $user->id,
        'type' => 'db',
        'target' => 'sourcedb',
        'status' => 'completed',
    ]);

    $this->actingAs($user);

    $response = $this->postJson("/backups/{$backup->id}/restore", [
        'new_target' => 'sourcedb',
    ]);

    $response->assertStatus(422);
    $response->assertJsonValidationErrors(['new_target']);
});

// ─────────────────────────────────────────────────────────────────────────────
// Test 7: POST /backups/{backup}/restore returns 422 for new_target failing regex
// ─────────────────────────────────────────────────────────────────────────────

test('POST /backups/{backup}/restore returns 422 for new_target that fails identifier regex', function (string $badTarget) {
    Storage::fake('backups');

    $user = User::factory()->create(['role' => 'user']);
    $backup = Backup::factory()->create([
        'user_id' => $user->id,
        'type' => 'db',
        'target' => 'sourcedb',
        'status' => 'completed',
    ]);

    $this->actingAs($user);

    $response = $this->postJson("/backups/{$backup->id}/restore", [
        'new_target' => $badTarget,
    ]);

    $response->assertStatus(422);
    $response->assertJsonValidationErrors(['new_target']);
})->with([
    'contains space' => ['bad name'],
    'contains backtick' => ['bad`name'],
    'contains hyphen' => ['bad-name'],
    'too long (65 chars)' => [str_repeat('a', 65)],
]);

// ─────────────────────────────────────────────────────────────────────────────
// Test 8: Non-owner DELETE /backups/schedules/{schedule} returns 403
// ─────────────────────────────────────────────────────────────────────────────

test('Non-owner DELETE /backups/schedules/{schedule} returns 403 (ScheduledBackupPolicy gate)', function () {
    $owner = User::factory()->create(['role' => 'user']);
    $other = User::factory()->create(['role' => 'user']);

    $schedule = ScheduledBackup::factory()->create([
        'user_id' => $owner->id,
    ]);

    $this->actingAs($other);

    $response = $this->delete("/backups/schedules/{$schedule->id}");

    $response->assertStatus(403);
    expect(ScheduledBackup::find($schedule->id))->not->toBeNull();
});

// ─────────────────────────────────────────────────────────────────────────────
// Test 9: Owner DELETE /backups/schedules/{schedule} succeeds
// ─────────────────────────────────────────────────────────────────────────────

test('Owner DELETE /backups/schedules/{schedule} deletes the schedule', function () {
    $owner = User::factory()->create(['role' => 'user']);

    $schedule = ScheduledBackup::factory()->create([
        'user_id' => $owner->id,
    ]);

    $this->actingAs($owner);

    $response = $this->delete("/backups/schedules/{$schedule->id}");

    $response->assertRedirect(route('backups.index'));
    expect(ScheduledBackup::find($schedule->id))->toBeNull();
});

// ─────────────────────────────────────────────────────────────────────────────
// Test 10: GET /backups unauthenticated redirects to login
// ─────────────────────────────────────────────────────────────────────────────

test('GET /backups unauthenticated redirects to login', function () {
    $response = $this->get('/backups');

    $response->assertStatus(302);
    $response->assertRedirect('/login');
});

// ─────────────────────────────────────────────────────────────────────────────
// Security: CreateBackupRequest does not allow target from another user's DB
// ─────────────────────────────────────────────────────────────────────────────

test('CreateBackupRequest scopeMine: cannot backup another user database via files type', function () {
    Storage::fake('backups');

    $owner = User::factory()->create(['role' => 'user']);
    $attacker = User::factory()->create(['role' => 'user']);

    Website::forceCreate([
        'user_id' => $owner->id,
        'url' => 'victim.com',
        'document_root' => '/public',
        'php_version_id' => 0,
    ]);

    $this->actingAs($attacker);

    $response = $this->postJson('/backups', [
        'type' => 'files',
        'target' => 'victim.com',
        'storage' => 'local',
    ]);

    $response->assertStatus(422);
    $response->assertJsonValidationErrors(['target']);
});
