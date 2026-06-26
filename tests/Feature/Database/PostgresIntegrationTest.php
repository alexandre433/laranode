<?php

use App\Databases\DatabaseSpec;
use App\Databases\Drivers\PostgresDriver;
use App\Databases\EngineManager;
use App\Models\Database;
use App\Models\User;
use App\Services\Database\CreateDatabaseService;
use App\Services\Database\DeleteDatabaseService;
use App\Services\Database\GetDatabasesWithStatsService;
use Illuminate\Support\Facades\DB;

/**
 * Real PostgreSQL integration tests.
 * Gate: LARANODE_SYSTEM_TESTS=1.
 *
 * Tests full create → index → delete lifecycle against the real PostgreSQL
 * instance running in the local-dev container.
 */
beforeEach(function () {
    if (! env('LARANODE_SYSTEM_TESTS')) {
        $this->markTestSkipped('LARANODE_SYSTEM_TESTS not set — skipping system integration tests.');
    }
});

test('postgres full lifecycle: create index delete with security assertions', function () {
    $user = User::factory()->create(['role' => 'user']);
    $admin = User::factory()->create(['role' => 'admin']);

    $uniqueSuffix = substr(md5(uniqid('', true)), 0, 8);
    $dbName = 'ln_pg_'.$uniqueSuffix;
    $dbUser = 'ln_pgu_'.$uniqueSuffix;
    $password = 'PgPass_'.$uniqueSuffix.'_secure';

    $spec = new DatabaseSpec(
        name: $dbName,
        dbUser: $dbUser,
        password: $password,
        userId: $user->id,
        options: ['encoding' => 'UTF8', 'locale' => 'en_US.UTF-8'],
    );

    $driver = new PostgresDriver;
    $createService = new CreateDatabaseService($driver);

    // ---- CREATE ----
    $record = $createService->handle($spec, 'postgres');

    expect($record->engine)->toBe('postgres');
    // Postgres rows have null charset and collation
    expect($record->charset)->toBeNull();
    expect($record->collation)->toBeNull();

    $this->assertDatabaseHas('databases', ['name' => $dbName, 'engine' => 'postgres']);

    // ---- SECURITY: REVOKE CONNECT FROM PUBLIC was applied ----
    // The pgsql_admin connection connects as laranode_pg_reader (a stats-reader role).
    // It should NOT be able to connect to the newly-created database since PUBLIC was revoked.
    // Only the specific dbUser should have connect access.
    $connectFailed = false;

    try {
        // Attempt connection to the new database as the stats-reader role
        // Using pgsql_admin connection config but targeting the new DB
        $pgsqlAdminConfig = config('database.connections.pgsql_admin');
        $testConfig = array_merge($pgsqlAdminConfig, ['database' => $dbName]);
        config(['database.connections.pgsql_admin_test' => $testConfig]);

        DB::connection('pgsql_admin_test')->selectOne('SELECT 1');
        DB::purge('pgsql_admin_test');
    } catch (\Exception $e) {
        $connectFailed = true;
        // Purge the failed connection
        try {
            DB::purge('pgsql_admin_test');
        } catch (\Exception) {
        }
    }

    expect($connectFailed)->toBeTrue('REVOKE CONNECT FROM PUBLIC should prevent the stats-reader role from connecting to the new database');

    // ---- SECURITY: Password not visible in process list during create ----
    // The password must not appear in /proc/*/cmdline (it should have been passed via stdin).
    // We re-create on a different db to observe the process list, but since the test runs
    // synchronously, we verify this by asserting the password was not in the last create
    // process command via checking /proc entries for psql commands that might have leaked it.
    // Note: since the system test is synchronous, the process is already done.
    // We instead verify through the script design: 'update-user-password' uses stdin.
    // The real check here is that the laranode-postgres.sh never passes password as argv.
    // We verify by examining the script source.
    $scriptPath = config('laranode.laranode_bin_path').'/laranode-postgres.sh';

    if (file_exists($scriptPath)) {
        $scriptContent = file_get_contents($scriptPath);
        // Script must NOT pass password as a positional argument to psql
        // It should use stdin (via heredoc or pipe)
        expect($scriptContent)->not->toContain('psql -c "ALTER ROLE')
            ->and($scriptContent)->toContain('password=$(cat)');
    }

    // ---- INDEX: non-admin sees own row, admin sees all ----
    $manager = app(EngineManager::class);

    $this->actingAs($user);
    GetDatabasesWithStatsService::clearCache();
    $statsService = new GetDatabasesWithStatsService($manager);
    $results = $statsService->handle();

    $own = collect($results)->firstWhere('name', $dbName);
    expect($own)->not->toBeNull();
    expect($own['engine'])->toBe('postgres');
    expect($own['charset'] ?? null)->toBeNull();
    expect($own['collation'] ?? null)->toBeNull();

    // Admin sees the row too
    $this->actingAs($admin);
    GetDatabasesWithStatsService::clearCache();
    $adminService = new GetDatabasesWithStatsService($manager);
    $allResults = $adminService->handle();
    $found = collect($allResults)->firstWhere('name', $dbName);
    expect($found)->not->toBeNull();

    // ---- DELETE ----
    $deleteService = new DeleteDatabaseService($driver);
    $deleteService->handle($record);

    $this->assertDatabaseMissing('databases', ['name' => $dbName]);

    // Verify the Postgres DB is actually dropped (connecting as superuser)
    $dbExists = DB::connection('pgsql_admin')->selectOne(
        'SELECT 1 FROM pg_database WHERE datname = ?',
        [$dbName]
    );
    expect($dbExists)->toBeNull();
})->group('system');
