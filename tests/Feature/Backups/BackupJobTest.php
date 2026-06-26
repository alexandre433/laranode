<?php

// tests/Feature/Backups/BackupJobTest.php

use App\Actions\Backup\DumpDatabaseAction;
use App\Actions\Backup\TarFilesAction;
use App\Backup\BackupEngineManager;
use App\Contracts\Backup\BackupEngineDriver;
use App\Jobs\BackupJob;
use App\Models\Backup;
use App\Models\Database as DatabaseModel;
use App\Models\Operation;
use App\Models\User;
use App\Models\Website;
use App\Services\Backups\BackupService;
use Illuminate\Support\Facades\Storage;

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Bind a fake BackupEngineManager whose driver creates and returns a real temp file,
 * so UploadToStorageAction can stream it.
 */
function bindFakeDumpDriver(string $content = 'fake-dump-data'): void
{
    $fakeDriver = new class($content) implements BackupEngineDriver
    {
        public function __construct(private string $content) {}

        public function dump(string $dbName, string $dbUser, string $cnfFile, callable $emit): string
        {
            // Create a real temp file so UploadToStorageAction can open it
            $path = tempnam(sys_get_temp_dir(), 'laranode-test-dump-') . '.sql.gz';
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
 * Bind a fake BackupEngineManager whose driver throws RuntimeException.
 */
function bindFailingDumpDriver(): void
{
    $throwingDriver = new class implements BackupEngineDriver
    {
        public function dump(string $dbName, string $dbUser, string $cnfFile, callable $emit): string
        {
            throw new RuntimeException('DB dump failed: mysqldump: Access denied');
        }
    };

    $fakeManager = new class($throwingDriver) extends BackupEngineManager
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
 * Bind a fake TarFilesAction that creates a real temp file and returns its path.
 */
function bindFakeTarFilesAction(string $content = 'fake-tar-data'): void
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
// BackupJob — db type
// ─────────────────────────────────────────────────────────────────────────────

test('BackupJob marks backup completed and operation succeeded for db type', function () {
    Storage::fake('backups');
    bindFakeDumpDriver();

    $user = User::factory()->create();
    $database = DatabaseModel::factory()->create([
        'user_id' => $user->id,
        'name' => 'testdb_ln',
        'db_password' => 'secret',
    ]);

    $operation = Operation::create([
        'user_id' => $user->id,
        'type' => 'backup.db',
        'target' => 'testdb_ln',
        'status' => 'queued',
    ]);

    $backup = Backup::create([
        'user_id' => $user->id,
        'operation_id' => $operation->id,
        'type' => 'db',
        'target' => 'testdb_ln',
        'storage' => 'local',
        'disk_name' => 'backups',
        'status' => 'pending',
    ]);

    BackupJob::dispatchSync($operation, $backup);

    expect($backup->fresh()->status)->toBe('completed');
    expect($operation->fresh()->status)->toBe('succeeded');
    expect($operation->fresh()->exit_code)->toBe(0);
});

// ─────────────────────────────────────────────────────────────────────────────
// BackupJob — files type
// ─────────────────────────────────────────────────────────────────────────────

test('BackupJob marks backup completed for files type', function () {
    Storage::fake('backups');
    bindFakeTarFilesAction();

    $user = User::factory()->create(['username' => 'siteusr']);
    $website = Website::forceCreate([
        'user_id' => $user->id,
        'url' => 'example.com',
        'document_root' => '/public',
        'php_version_id' => 0,
    ]);

    $operation = Operation::create([
        'user_id' => $user->id,
        'type' => 'backup.files',
        'target' => 'example.com',
        'status' => 'queued',
    ]);

    $backup = Backup::create([
        'user_id' => $user->id,
        'operation_id' => $operation->id,
        'type' => 'files',
        'target' => 'example.com',
        'storage' => 'local',
        'disk_name' => 'backups',
        'status' => 'pending',
    ]);

    BackupJob::dispatchSync($operation, $backup);

    expect($backup->fresh()->status)->toBe('completed');
    expect($operation->fresh()->status)->toBe('succeeded');
});

// ─────────────────────────────────────────────────────────────────────────────
// BackupJob — dump failure keeps backup pending, operation failed
// ─────────────────────────────────────────────────────────────────────────────

test('BackupJob keeps backup pending and marks operation failed when dump fails', function () {
    Storage::fake('backups');
    bindFailingDumpDriver();

    $user = User::factory()->create();
    DatabaseModel::factory()->create([
        'user_id' => $user->id,
        'name' => 'faildb_ln',
        'db_password' => 'secret',
    ]);

    $operation = Operation::create([
        'user_id' => $user->id,
        'type' => 'backup.db',
        'target' => 'faildb_ln',
        'status' => 'queued',
    ]);

    $backup = Backup::create([
        'user_id' => $user->id,
        'operation_id' => $operation->id,
        'type' => 'db',
        'target' => 'faildb_ln',
        'storage' => 'local',
        'disk_name' => 'backups',
        'status' => 'pending',
    ]);

    // OperationJob re-throws exceptions after marking operation failed
    expect(fn () => BackupJob::dispatchSync($operation, $backup))
        ->toThrow(RuntimeException::class);

    expect($backup->fresh()->status)->toBe('pending');
    expect($operation->fresh()->status)->toBe('failed');
    expect($operation->fresh()->exit_code)->toBe(1);
});

// ─────────────────────────────────────────────────────────────────────────────
// BackupService::handle()
// ─────────────────────────────────────────────────────────────────────────────

test('BackupService::handle() creates Backup and Operation rows, returns Operation, backup ends completed', function () {
    Storage::fake('backups');
    bindFakeDumpDriver();

    $user = User::factory()->create();
    DatabaseModel::factory()->create([
        'user_id' => $user->id,
        'name' => 'mydb_ln',
        'db_password' => 'secret',
    ]);

    $service = new BackupService;

    $operation = $service->handle([
        'type' => 'db',
        'target' => 'mydb_ln',
        'storage' => 'local',
    ], $user);

    expect($operation)->toBeInstanceOf(Operation::class);
    expect($operation->exists)->toBeTrue();

    $backup = Backup::where('operation_id', $operation->id)->first();
    expect($backup)->not->toBeNull();
    expect($backup->type)->toBe('db');
    expect($backup->target)->toBe('mydb_ln');
    expect($backup->disk_name)->toBe('backups');

    // With QUEUE_CONNECTION=sync the job runs inline — backup should be completed
    expect($backup->fresh()->status)->toBe('completed');
    expect($operation->fresh()->status)->toBe('succeeded');
});
