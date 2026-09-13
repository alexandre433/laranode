<?php

// tests/Feature/Database/PostgresDegradedStatsTest.php
//
// Graceful degradation when PostgreSQL is absent, stopped, or the
// laranode_pg_reader stats role is missing.
//
// The pgsql_admin connection is pointed at an unreachable port so the failure
// is deterministic on any machine (Windows dev boxes have no PostgreSQL, and a
// developer box that does have one may still lack the reader role).

use App\Contracts\DatabaseEngineDriver;
use App\Databases\DatabaseSpec;
use App\Databases\DatabaseStats;
use App\Databases\Drivers\DatabaseStatsException;
use App\Databases\Drivers\PostgresDriver;
use App\Databases\EngineCapabilities;
use App\Databases\EngineManager;
use App\Models\Database;
use App\Models\User;
use App\Services\Database\GetDatabasesWithStatsService;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Process;

/**
 * Point pgsql_admin at a closed port and drop the resolved connection so the
 * next query has to reconnect (and fail) deterministically.
 */
function makePgsqlAdminUnreachable(): void
{
    config(['database.connections.pgsql_admin' => array_merge(
        config('database.connections.pgsql_admin'),
        ['host' => '127.0.0.1', 'port' => 1],
    )]);

    DB::purge('pgsql_admin');
}

/**
 * A postgres Database row as it would exist after a successful create — postgres
 * rows carry null charset/collation.
 */
function makePostgresDatabaseRow(User $user, string $name = 'pgdb_degraded'): Database
{
    return Database::factory()->create([
        'name' => $name,
        'db_user' => $name.'_user',
        'charset' => null,
        'collation' => null,
        'engine' => 'postgres',
        'user_id' => $user->id,
    ]);
}

beforeEach(function () {
    app()->forgetInstance(EngineManager::class);
    GetDatabasesWithStatsService::clearCache();
    makePgsqlAdminUnreachable();
});

// ──────────────────────────────────────────────────────────────────────
// Driver level: raw QueryException → domain DatabaseStatsException
// ──────────────────────────────────────────────────────────────────────

test('PostgresDriver stats throws the domain DatabaseStatsException when PostgreSQL is unreachable', function () {
    $database = makePostgresDatabaseRow(User::factory()->create());

    $exception = null;

    try {
        (new PostgresDriver)->stats($database);
    } catch (DatabaseStatsException $e) {
        $exception = $e;
    }

    expect($exception)->toBeInstanceOf(DatabaseStatsException::class);
    expect($exception->getMessage())->toContain('Unable to read PostgreSQL stats');
    // The original QueryException is kept as the previous exception for diagnostics.
    expect($exception->getPrevious())->not->toBeNull();
});

test('PostgresDriver stats does not leak a raw QueryException for an unreachable engine', function () {
    $database = makePostgresDatabaseRow(User::factory()->create());

    // A QueryException escaping here is exactly what 500s the Databases page.
    expect(fn () => (new PostgresDriver)->stats($database))
        ->not->toThrow(\Illuminate\Database\QueryException::class);
});

// ──────────────────────────────────────────────────────────────────────
// Service level: the listing degrades to zero stats
// ──────────────────────────────────────────────────────────────────────

test('Database stats degrade to zero when the engine is unreachable instead of throwing', function () {
    $user = User::factory()->create();
    makePostgresDatabaseRow($user);

    $this->actingAs($user);

    $items = (new GetDatabasesWithStatsService(app(EngineManager::class)))->handle();

    expect($items)->toHaveCount(1)
        ->and($items[0]['engine'])->toBe('postgres')
        ->and($items[0]['name'])->toBe('pgdb_degraded')
        ->and($items[0]['sizeMb'])->toBe(0.0)
        ->and($items[0]['tables'])->toBe(0);
});

test('Database stats degrade when a driver throws the domain exception', function () {
    $user = User::factory()->create();
    makePostgresDatabaseRow($user);

    $this->actingAs($user);

    $throwingDriver = new class implements DatabaseEngineDriver
    {
        public function connectionName(): string
        {
            return 'pgsql_admin';
        }

        public function create(DatabaseSpec $spec): void {}

        public function updatePassword(Database $database, string $newPassword): void {}

        public function updateOptions(Database $database, array $options): void {}

        public function delete(Database $database): void {}

        public function stats(Database $database): DatabaseStats
        {
            throw new DatabaseStatsException('engine down');
        }

        public function capabilities(): EngineCapabilities
        {
            return new EngineCapabilities(label: 'PostgreSQL', hasUsers: true, optionFields: ['encoding', 'locale']);
        }
    };

    $manager = Mockery::mock(EngineManager::class);
    $manager->shouldReceive('for')->with('postgres')->andReturn($throwingDriver);

    $items = (new GetDatabasesWithStatsService($manager))->handle();

    expect($items)->toHaveCount(1)
        ->and($items[0]['sizeMb'])->toBe(0.0)
        ->and($items[0]['tables'])->toBe(0);
});

// ──────────────────────────────────────────────────────────────────────
// UI facing path: GET /databases must render, not 500
// ──────────────────────────────────────────────────────────────────────

test('GET /databases renders with zero stats when PostgreSQL is unreachable', function () {
    $user = User::factory()->create(['role' => 'user']);
    makePostgresDatabaseRow($user);

    $response = $this->actingAs($user)->get('/databases');

    $response->assertStatus(200);
    $response->assertInertia(fn ($page) => $page
        ->component('Databases/Index')
        ->has('databases', 1)
        ->where('databases.0.engine', 'postgres')
        ->where('databases.0.sizeMb', 0)
    );
});

test('Database creation is not offered for an engine whose service is inactive', function () {
    // No engine service is active — the create form must not offer postgres,
    // and posting engine=postgres must be rejected by validation, not 500.
    Process::fake(fn () => Process::result(output: 'inactive', exitCode: 1));

    app()->forgetInstance(EngineManager::class);

    $user = User::factory()->create(['role' => 'user']);
    $this->actingAs($user);

    $options = $this->getJson('/databases/engine-options');
    $options->assertStatus(200)->assertJson(['engines' => [], 'capabilities' => null]);

    $response = $this->postJson('/databases', [
        'engine' => 'postgres',
        'name_suffix' => 'mydb',
        'db_user_suffix' => 'myuser',
        'db_pass' => 'password123',
    ]);

    $response->assertStatus(422)->assertJsonValidationErrors('engine');
});
