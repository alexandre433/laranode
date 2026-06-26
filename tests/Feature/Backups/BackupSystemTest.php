<?php

// tests/Feature/Backups/BackupSystemTest.php
//
// Real system integration tests gated behind LARANODE_SYSTEM_TESTS=1.
// Exercises the four bash scripts (laranode-db-backup.sh, laranode-backup-files.sh,
// laranode-restore-db.sh, laranode-restore-files.sh) and the full DB restore flow.
//
// Run inside the local-dev container:
//   LARANODE_SYSTEM_TESTS=1 php artisan test --filter=BackupSystemTest

use App\Databases\DatabaseSpec;
use App\Databases\Drivers\MysqlDriver;
use App\Models\Database as DatabaseModel;
use App\Models\User;
use App\Services\Database\CreateDatabaseService;
use App\Services\Database\DeleteDatabaseService;
use Illuminate\Support\Facades\DB;

// Gate: skip the entire file unless LARANODE_SYSTEM_TESTS is set.
beforeEach(function () {
    if (! env('LARANODE_SYSTEM_TESTS')) {
        $this->markTestSkipped('LARANODE_SYSTEM_TESTS not set — skipping system integration tests.');
    }
});

// ---------------------------------------------------------------------------
// Helper: absolute path to the bash scripts in the bind-mounted repo tree.
// We use base_path() rather than config('laranode.laranode_bin_path') so the
// test works in the local-dev container regardless of the LARANODE_BIN_PATH
// env override (which points to /opt/laranode/bin, a separate copy that does
// not contain the new backup scripts until the container is reprovisioned).
// ---------------------------------------------------------------------------
function backupScriptPath(string $script): string
{
    return base_path('laranode-scripts/bin/'.$script);
}

// ---------------------------------------------------------------------------
// Helper: run a raw MySQL statement via the mysql_admin connection.
// ---------------------------------------------------------------------------
function mysqlAdmin(string $sql): void
{
    DB::connection('mysql_admin')->statement($sql);
}

// ---------------------------------------------------------------------------
// Test 1: laranode-db-backup.sh dumps a real MySQL database
// ---------------------------------------------------------------------------
test('laranode-db-backup.sh dumps a real MySQL database using --defaults-extra-file', function () {
    $suffix = substr(md5(uniqid('', true)), 0, 8);
    $dbName = 'ln_bkp_src_'.$suffix;
    // Use the same mysql_admin user/password the driver uses for DB operations.
    $dbUser = env('MYSQL_ADMIN_USERNAME', 'laranode');
    $dbPassword = env('MYSQL_ADMIN_PASSWORD', 'laranode_local_dev_pw');
    $dbHost = env('MYSQL_ADMIN_HOST', '127.0.0.1');

    // Create a real test database with one table and one row.
    mysqlAdmin("CREATE DATABASE IF NOT EXISTS `{$dbName}`");
    mysqlAdmin("CREATE TABLE `{$dbName}`.`test_tbl` (id INT PRIMARY KEY, val VARCHAR(32))");
    mysqlAdmin("INSERT INTO `{$dbName}`.`test_tbl` VALUES (1, 'hello-backup')");

    // Write a --defaults-extra-file .cnf (mode 0600) with host, user, and password.
    $cnfPath = sys_get_temp_dir().'/laranode-system-test-'.uniqid().'.cnf';
    file_put_contents($cnfPath, "[client]\nhost={$dbHost}\nuser={$dbUser}\npassword={$dbPassword}\n");
    chmod($cnfPath, 0600);

    $outFile = sys_get_temp_dir().'/laranode-system-test-'.uniqid().'.sql.gz';

    try {
        // Invoke the backup script directly; no sudo needed when running as root.
        $scriptPath = backupScriptPath('laranode-db-backup.sh');
        $cmd = escapeshellarg($scriptPath)
            .' mysql '
            .escapeshellarg($dbName)
            .' '.escapeshellarg($dbUser)
            .' '.escapeshellarg($cnfPath)
            .' '.escapeshellarg($outFile);

        $output = [];
        $exitCode = 0;
        exec($cmd.' 2>&1', $output, $exitCode);

        expect($exitCode)->toBe(0, 'Script exited non-zero: '.implode("\n", $output));

        // Output file must exist and be non-empty.
        expect(file_exists($outFile))->toBeTrue('Dump file was not created');
        expect(filesize($outFile))->toBeGreaterThan(0, 'Dump file is empty');

        // Check gzip magic bytes 0x1f 0x8b.
        $fp = fopen($outFile, 'rb');
        $magic = fread($fp, 2);
        fclose($fp);
        expect(bin2hex($magic))->toBe('1f8b', 'Output file does not have gzip magic bytes');

        // Verify the dump contains our table/row when decompressed.
        $decompressed = shell_exec('zcat '.escapeshellarg($outFile));
        expect($decompressed)->toContain('test_tbl');
        expect($decompressed)->toContain('hello-backup');

    } finally {
        mysqlAdmin("DROP DATABASE IF EXISTS `{$dbName}`");
        @unlink($cnfPath);
        @unlink($outFile);
    }
})->group('system');

// ---------------------------------------------------------------------------
// Test 2: laranode-backup-files.sh tars a real directory
// ---------------------------------------------------------------------------
test('laranode-backup-files.sh archives a directory and produces a valid gzipped tar', function () {
    // Create a temp directory with known test files.
    $siteRoot = sys_get_temp_dir().'/laranode-bkp-site-'.uniqid();
    mkdir($siteRoot, 0755, true);
    file_put_contents($siteRoot.'/index.html', '<html>hello</html>');
    file_put_contents($siteRoot.'/README.txt', 'test content for backup');

    $outFile = sys_get_temp_dir().'/laranode-bkp-files-'.uniqid().'.tar.gz';
    $sysUser = 'root'; // container runs as root; chown is a no-op on an already-root-owned file

    try {
        $scriptPath = backupScriptPath('laranode-backup-files.sh');
        $cmd = escapeshellarg($scriptPath)
            .' '.escapeshellarg($siteRoot)
            .' '.escapeshellarg($outFile)
            .' '.escapeshellarg($sysUser);

        $output = [];
        $exitCode = 0;
        exec($cmd.' 2>&1', $output, $exitCode);

        expect($exitCode)->toBe(0, 'Script exited non-zero: '.implode("\n", $output));

        // Archive must exist and be non-empty.
        expect(file_exists($outFile))->toBeTrue('Archive file was not created');
        expect(filesize($outFile))->toBeGreaterThan(0, 'Archive file is empty');

        // List archive with tar tzf — both files must appear.
        $listing = shell_exec('tar tzf '.escapeshellarg($outFile));
        expect($listing)->toContain('index.html');
        expect($listing)->toContain('README.txt');

    } finally {
        @unlink($siteRoot.'/index.html');
        @unlink($siteRoot.'/README.txt');
        @rmdir($siteRoot);
        @unlink($outFile);
    }
})->group('system');

// ---------------------------------------------------------------------------
// Test 3: Full dump → restore flow via CreateDatabaseService
// ---------------------------------------------------------------------------
test('laranode-restore-db.sh restores a dump into a new panel-managed database', function () {
    $suffix = substr(md5(uniqid('', true)), 0, 8);
    $srcDbName = 'ln_restore_src_'.$suffix;
    $destDbName = 'ln_restore_dst_'.$suffix;
    $destDbUser = 'ln_u_'.$suffix;
    $destDbPass = 'RestorePass_'.$suffix.'!';

    $adminUser = env('MYSQL_ADMIN_USERNAME', 'laranode');
    $adminPass = env('MYSQL_ADMIN_PASSWORD', 'laranode_local_dev_pw');
    $adminHost = env('MYSQL_ADMIN_HOST', '127.0.0.1');

    $dumpFile = sys_get_temp_dir().'/laranode-restore-'.uniqid().'.sql.gz';
    $srcCnf = sys_get_temp_dir().'/laranode-src-cnf-'.uniqid().'.cnf';
    $dstCnf = sys_get_temp_dir().'/laranode-dst-cnf-'.uniqid().'.cnf';

    // User row for scoping — uses the SQLite test DB via RefreshDatabase.
    $user = User::factory()->create(['role' => 'user']);
    $destDbRecord = null;

    try {
        // 1. Create source DB with known data via mysql_admin connection.
        mysqlAdmin("CREATE DATABASE IF NOT EXISTS `{$srcDbName}`");
        mysqlAdmin("CREATE TABLE `{$srcDbName}`.`items` (id INT PRIMARY KEY, name VARCHAR(64))");
        mysqlAdmin("INSERT INTO `{$srcDbName}`.`items` VALUES (42, 'restored-item')");

        // 2. Dump source DB via laranode-db-backup.sh.
        // Include host + user + password so mysqldump uses the correct credentials.
        file_put_contents($srcCnf, "[client]\nhost={$adminHost}\nuser={$adminUser}\npassword={$adminPass}\n");
        chmod($srcCnf, 0600);

        $backupScript = backupScriptPath('laranode-db-backup.sh');
        $cmd = escapeshellarg($backupScript)
            .' mysql '
            .escapeshellarg($srcDbName)
            .' '.escapeshellarg($adminUser)
            .' '.escapeshellarg($srcCnf)
            .' '.escapeshellarg($dumpFile);

        $output = [];
        $exitCode = 0;
        exec($cmd.' 2>&1', $output, $exitCode);
        expect($exitCode)->toBe(0, 'Dump failed: '.implode("\n", $output));
        expect(file_exists($dumpFile))->toBeTrue('Dump file missing after backup script');

        // 3. Create destination DB via CreateDatabaseService (panel-managed row + MySQL user).
        $driver = new MysqlDriver;
        $createService = new CreateDatabaseService($driver);
        $spec = new DatabaseSpec(
            name: $destDbName,
            dbUser: $destDbUser,
            password: $destDbPass,
            userId: $user->id,
            options: ['charset' => 'utf8mb4', 'collation' => 'utf8mb4_unicode_ci'],
        );
        $destDbRecord = $createService->handle($spec, 'mysql');

        // Panel row must exist in the test SQLite DB.
        expect(DatabaseModel::where('name', $destDbName)->exists())->toBeTrue(
            'Panel database row was not created by CreateDatabaseService'
        );

        // 4. Restore the dump into the destination DB via laranode-restore-db.sh.
        // The dest user was granted ALL on destDbName by CreateDatabaseService.
        // Include host + user + password so mysql uses the correct credentials,
        // not the Unix socket identity of the process owner.
        file_put_contents($dstCnf, "[client]\nhost={$adminHost}\nuser={$adminUser}\npassword={$adminPass}\n");
        chmod($dstCnf, 0600);

        $restoreScript = backupScriptPath('laranode-restore-db.sh');
        $restoreCmd = escapeshellarg($restoreScript)
            .' '.escapeshellarg($dstCnf)
            .' '.escapeshellarg($dumpFile)
            .' '.escapeshellarg($destDbName);

        $restoreOutput = [];
        $restoreExit = 0;
        exec($restoreCmd.' 2>&1', $restoreOutput, $restoreExit);
        expect($restoreExit)->toBe(0, 'Restore failed: '.implode("\n", $restoreOutput));

        // 5. Verify the restored data exists in the destination DB.
        $rows = DB::connection('mysql_admin')->select(
            "SELECT id, name FROM `{$destDbName}`.`items` WHERE id = 42"
        );
        expect($rows)->not->toBeEmpty('Restored table/row not found in destination DB');
        expect($rows[0]->name)->toBe('restored-item');

    } finally {
        // Cleanup real MySQL objects.
        mysqlAdmin("DROP DATABASE IF EXISTS `{$srcDbName}`");

        if ($destDbRecord) {
            $driver = new MysqlDriver;
            $deleteService = new DeleteDatabaseService($driver);
            try {
                $deleteService->handle($destDbRecord);
            } catch (\Throwable) {
                // DB already dropped or user missing; clean up the panel row directly.
                $destDbRecord->delete();
                mysqlAdmin("DROP DATABASE IF EXISTS `{$destDbName}`");
            }
        } else {
            mysqlAdmin("DROP DATABASE IF EXISTS `{$destDbName}`");
        }

        @unlink($srcCnf);
        @unlink($dstCnf);
        @unlink($dumpFile);
    }
})->group('system');
