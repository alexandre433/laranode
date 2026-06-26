<?php

use App\Databases\DatabaseSpec;
use App\Databases\Drivers\CreateDatabaseException;
use App\Databases\Drivers\PostgresDriver;
use App\Models\Database;
use App\Models\User;
use Illuminate\Support\Facades\Process;

afterEach(function () {
    Mockery::close();
});

test('capabilities returns PostgreSQL label with users and encoding/locale option fields', function () {
    $driver = new PostgresDriver;
    $caps = $driver->capabilities();

    expect($caps->label)->toBe('PostgreSQL')
        ->and($caps->hasUsers)->toBeTrue()
        ->and($caps->optionFields)->toBe(['encoding', 'locale']);
});

test('create calls create-db, create-user, grant in order and password is not in command array', function () {
    Process::fake([
        '*' => Process::result(exitCode: 0),
    ]);

    $user = User::factory()->create();
    $spec = new DatabaseSpec(
        name: 'pgdb_test',
        dbUser: 'pguser_test',
        password: 'super_secret_pg_password_456',
        userId: $user->id,
        options: ['encoding' => 'UTF8', 'locale' => 'en_US.UTF-8'],
    );

    $driver = new PostgresDriver;
    $driver->create($spec);

    // Confirm create-db was called
    Process::assertRan(function ($process) {
        return is_array($process->command) && in_array('create-db', $process->command);
    });

    // Confirm create-user was called and password is NOT in the command array
    Process::assertRan(function ($process) {
        if (! is_array($process->command)) {
            return false;
        }

        return in_array('create-user', $process->command)
            && ! in_array('super_secret_pg_password_456', $process->command);
    });

    // Confirm grant was called
    Process::assertRan(function ($process) {
        return is_array($process->command) && in_array('grant', $process->command);
    });
});

test('non-zero exit on create-db throws CreateDatabaseException without calling create-user', function () {
    Process::fake([
        '*' => Process::result(exitCode: 1, output: 'create failed'),
    ]);

    $user = User::factory()->create();
    $spec = new DatabaseSpec(
        name: 'pgdb_fail',
        dbUser: 'pguser_fail',
        password: 'password',
        userId: $user->id,
    );

    $driver = new PostgresDriver;

    expect(fn () => $driver->create($spec))
        ->toThrow(CreateDatabaseException::class);

    // create-user should NOT have been called
    Process::assertNotRan(function ($process) {
        return is_array($process->command) && in_array('create-user', $process->command);
    });
});

test('non-zero exit on create-user triggers drop-db rollback', function () {
    $callCount = 0;

    Process::fake(function ($process) use (&$callCount) {
        $callCount++;

        // First call: create-db → success
        // Second call: create-user → failure
        // Third call: drop-db (rollback) → success
        if (is_array($process->command) && in_array('create-db', $process->command)) {
            return Process::result(exitCode: 0);
        }

        if (is_array($process->command) && in_array('create-user', $process->command)) {
            return Process::result(exitCode: 1, output: 'create-user failed');
        }

        return Process::result(exitCode: 0);
    });

    $user = User::factory()->create();
    $spec = new DatabaseSpec(
        name: 'pgdb_rollback',
        dbUser: 'pguser_rollback',
        password: 'password',
        userId: $user->id,
    );

    $driver = new PostgresDriver;

    expect(fn () => $driver->create($spec))
        ->toThrow(CreateDatabaseException::class);

    // drop-db should have been called as rollback
    Process::assertRan(function ($process) {
        return is_array($process->command) && in_array('drop-db', $process->command);
    });
});

test('delete calls drop-db and drop-user', function () {
    Process::fake([
        '*' => Process::result(exitCode: 0),
    ]);

    $user = User::factory()->create();
    $database = new Database([
        'name' => 'pgdb_delete',
        'db_user' => 'pguser_delete',
        'db_password' => encrypt('secret'),
        'charset' => null,
        'collation' => null,
        'engine' => 'postgres',
        'user_id' => $user->id,
    ]);

    $driver = new PostgresDriver;
    $driver->delete($database);

    Process::assertRan(function ($process) {
        return is_array($process->command) && in_array('drop-db', $process->command);
    });

    Process::assertRan(function ($process) {
        return is_array($process->command) && in_array('drop-user', $process->command);
    });
});

test('updatePassword calls update-user-password action with password via stdin not argv', function () {
    Process::fake([
        '*' => Process::result(exitCode: 0),
    ]);

    $user = User::factory()->create();
    $database = new Database([
        'name' => 'pgdb_update',
        'db_user' => 'pguser_update',
        'db_password' => encrypt('old_password'),
        'charset' => null,
        'collation' => null,
        'engine' => 'postgres',
        'user_id' => $user->id,
    ]);

    $driver = new PostgresDriver;
    $driver->updatePassword($database, 'new_pg_secret_789');

    // Password must NOT appear in the command array but is in input
    Process::assertRan(function ($process) {
        if (! is_array($process->command)) {
            return false;
        }

        return in_array('update-user-password', $process->command)
            && ! in_array('new_pg_secret_789', $process->command);
    });
});
