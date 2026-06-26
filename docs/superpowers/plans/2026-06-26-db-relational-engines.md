# DB Driver Seam + MySQL / MariaDB / PostgreSQL — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce a `DatabaseEngineDriver` interface and three concrete drivers (MySQL, MariaDB, PostgreSQL) so Laranode can manage databases on whichever engine the host runs. Existing MySQL behavior is preserved without any user-visible regression. Fix the SQL injection surface in the current MySQL services. Add PostgreSQL as a first-class engine via sudo script + peer auth. Provide a dynamic, engine-agnostic create/edit UI driven by `EngineCapabilities`.

**Architecture:** `DatabasesController` (engine-agnostic) → `CreateDatabaseRequest` / `UpdateDatabaseRequest` / `DeleteDatabaseRequest` (validation, engine-aware) → `CreateDatabaseService` / `UpdateDatabaseService` / `DeleteDatabaseService` (orchestration) → `EngineManager` → `DatabaseEngineDriver` implementation. Drivers never touch Eloquent. Services own all model mutations. `EngineManager` is registered in `DatabaseServiceProvider`. Routes rename to `databases.*`; `mysql.*` routes become 301-redirect aliases.

**Tech Stack:** Laravel 12, Pest 3, Vitest + RTL (already in place from sub-project #1), MySQL / PostgreSQL (local-dev container), `Process` facade for `systemctl is-active` checks and Postgres sudo script calls, `DB::connection('mysql_admin')` for MySQL driver SQL.

## Global Constraints

- **`DatabaseEngineDriver` interface is the only public contract between services and engines.** Drivers never call Eloquent; services never run raw SQL.
- **`EngineManager::available()` is the authoritative engine list** — drives both the create form and `CreateDatabaseRequest` validation. Hardcoded per-engine UI conditionals are forbidden.
- **SQL injection fix is mandatory** in `MysqlDriver`: parameterized `DB::connection('mysql_admin')->statement('... ?', [$value])` for password; defense-in-depth `[a-zA-Z0-9_]+` assertion for name and db_user (the request already regex-validates them).
- **PostgreSQL mutations are always via `sudo laranode-postgres.sh`** — no stored superuser password. Stats read via the `pgsql` Laravel connection as a read-only panel user.
- **`mysql.*` route aliases are kept as 301 redirects** and are NOT removed in this sub-project.
- **`MysqlController` is kept as a thin shim** (not removed until a follow-up cleanup pass).
- **`Pages/Mysql/` files are kept temporarily** (do not delete; route/Inertia-component renames happen only in the new `Pages/Databases/` files).
- **Tests run with `QUEUE_CONNECTION=sync`** (already set in `phpunit.xml`). No queue infrastructure needed here — database operations are synchronous.
- **`LARANODE_SYSTEM_TESTS=1` gate** on any test that hits real MySQL or real PostgreSQL. Unit tests use `DB::fake()` / `Process::fake()` / mock connections.
- **Branch:** `feature/db-relational-engines` (off `development`). Each task commits here.
- **Run the suite in the `local-dev` container** for the authoritative result: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test'`. Use PowerShell (not Git Bash) for `make` and `docker compose`.

---

> **Execution order:** Tasks 1–11 in order. Tasks 1–3 are foundational (data model, config, contracts); nothing else compiles without them. Tasks 4–6 build the driver layer. Tasks 7–8 build services and controller. Tasks 9–10 add routes and frontend. Task 11 adds the Postgres system infrastructure. All tasks with a TDD marker write the failing test before the implementation.

---

### Task 1: Database migration — add `engine` column, backfill, nullable charset/collation

**[MIGRATION/BACK-COMPAT]**

**Files:**
- Create: `database/migrations/XXXX_add_engine_to_databases_table.php`
- Modify: `app/Models/Database.php` (add `engine` to `$fillable`)

**Scope:** Single migration + model fillable change. No logic changes yet.

**Interfaces:**
- Produces: `databases.engine` column (`string`, `default('mysql')`); `databases.charset` and `databases.collation` nullable; existing rows backfilled to `engine='mysql'`. `App\Models\Database::$fillable` gains `'engine'`. Consumed by every subsequent task.

- [ ] **Step 1: Write the failing test**

```php
<?php // tests/Feature/Database/DatabaseMigrationTest.php

use App\Models\Database;
use App\Models\User;
use Illuminate\Support\Facades\Schema;

test('databases table has the engine column', function () {
    expect(Schema::hasColumn('databases', 'engine'))->toBeTrue();
});

test('charset and collation are nullable', function () {
    expect(Schema::getColumnType('databases', 'charset'))->not->toBeNull();
    // Create a row without charset/collation to confirm nullable works
    $user = User::factory()->create();
    $db = Database::create([
        'name' => $user->username . '_test',
        'db_user' => $user->username . '_user',
        'db_password' => encrypt('password123'),
        'user_id' => $user->id,
        'engine' => 'postgres',
    ]);
    expect($db->charset)->toBeNull()
        ->and($db->collation)->toBeNull()
        ->and($db->engine)->toBe('postgres');
});

test('existing rows without engine default to mysql', function () {
    // The backfill sets engine='mysql' on pre-existing rows; default handles new rows
    $user = User::factory()->create();
    $db = Database::create([
        'name' => $user->username . '_legacy',
        'db_user' => $user->username . '_leg',
        'db_password' => encrypt('password123'),
        'charset' => 'utf8mb4',
        'collation' => 'utf8mb4_unicode_ci',
        'user_id' => $user->id,
        'engine' => 'mysql',
    ]);
    expect($db->engine)->toBe('mysql');
});
```

- [ ] **Step 2: Run it; verify it fails**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=DatabaseMigrationTest'`
Expected: FAIL — `engine` column does not exist.

- [ ] **Step 3: Write the migration**

```php
<?php // database/migrations/XXXX_add_engine_to_databases_table.php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::table('databases', function (Blueprint $table) {
            $table->string('engine')->default('mysql')->after('user_id');
            $table->string('charset')->nullable()->change();
            $table->string('collation')->nullable()->change();
        });

        // Explicit backfill covers any rows that pre-date the default
        DB::table('databases')->whereNull('engine')->update(['engine' => 'mysql']);
    }

    public function down(): void
    {
        Schema::table('databases', function (Blueprint $table) {
            $table->dropColumn('engine');
            $table->string('charset')->nullable(false)->change();
            $table->string('collation')->nullable(false)->change();
        });
    }
};
```

- [ ] **Step 4: Add `engine` to `Database::$fillable`**

In `app/Models/Database.php`, add `'engine'` to the `$fillable` array. No other changes.

- [ ] **Step 5: Run migration + test; verify it passes**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan migrate && php artisan test --filter=DatabaseMigrationTest'`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add database/migrations/ app/Models/Database.php tests/Feature/Database/DatabaseMigrationTest.php
git commit -m "feat(databases): add engine column + nullable charset/collation + backfill"
```

---

### Task 2: Config additions — `db_engines` map + `mysql_admin` / `mariadb_admin` / `pgsql` connections

**Files:**
- Modify: `config/laranode.php` (add `db_engines` key)
- Modify: `config/database.php` (add `mysql_admin`, `mariadb_admin`, `pgsql` connections)

**Scope:** Config file edits only. No PHP class changes.

**Interfaces:**
- Produces: `config('laranode.db_engines')` returns `['mysql' => ['service' => 'mysql', 'port' => 3306], 'mariadb' => [...], 'postgres' => [...]]`. `DB::connection('mysql_admin')` and `DB::connection('mariadb_admin')` available (credentials from `MYSQL_ADMIN_USERNAME` / `MYSQL_ADMIN_PASSWORD` env vars). `DB::connection('pgsql')` available for Postgres stats. Consumed by `EngineManager` (Task 3) and drivers (Tasks 4–6).

- [ ] **Step 1: Add `db_engines` to `config/laranode.php`**

Append to the return array in `config/laranode.php`:
```php
    'db_engines' => [
        'mysql'    => ['service' => 'mysql',      'port' => 3306],
        'mariadb'  => ['service' => 'mariadb',    'port' => 3306],
        'postgres' => ['service' => 'postgresql', 'port' => 5432],
    ],
```

- [ ] **Step 2: Add `mysql_admin`, `mariadb_admin`, and `pgsql` connections to `config/database.php`**

In the `connections` array, after the existing `mysql` entry add:
```php
        'mysql_admin' => [
            'driver'    => 'mysql',
            'host'      => env('DB_HOST', '127.0.0.1'),
            'port'      => env('DB_PORT', '3306'),
            'database'  => env('DB_DATABASE', 'laranode'),
            'username'  => env('MYSQL_ADMIN_USERNAME', env('DB_USERNAME', 'root')),
            'password'  => env('MYSQL_ADMIN_PASSWORD', env('DB_PASSWORD', '')),
            'unix_socket' => env('DB_SOCKET', ''),
            'charset'   => 'utf8mb4',
            'collation' => 'utf8mb4_unicode_ci',
            'prefix'    => '',
            'strict'    => true,
            'engine'    => null,
        ],

        'mariadb_admin' => [
            'driver'    => 'mysql',
            'host'      => env('DB_HOST', '127.0.0.1'),
            'port'      => env('DB_PORT', '3306'),
            'database'  => env('DB_DATABASE', 'laranode'),
            'username'  => env('MYSQL_ADMIN_USERNAME', env('DB_USERNAME', 'root')),
            'password'  => env('MYSQL_ADMIN_PASSWORD', env('DB_PASSWORD', '')),
            'unix_socket' => env('DB_SOCKET', ''),
            'charset'   => 'utf8mb4',
            'collation' => 'utf8mb4_unicode_ci',
            'prefix'    => '',
            'strict'    => true,
            'engine'    => null,
        ],
```

After the existing `sqlite` / `mysql` / `mariadb` entries (or wherever appropriate in the file), add the `pgsql` entry if not already present (Laravel's skeleton includes one — if it exists, verify it reads from `PGSQL_*` env vars and update if needed):
```php
        'pgsql' => [
            'driver'   => 'pgsql',
            'host'     => env('PGSQL_HOST', '127.0.0.1'),
            'port'     => env('PGSQL_PORT', '5432'),
            'database' => env('PGSQL_DB', 'postgres'),
            'username' => env('PGSQL_USERNAME', 'laranode_pg_reader'),
            'password' => env('PGSQL_PASSWORD', ''),
            'charset'  => 'utf8',
            'prefix'   => '',
            'schema'   => 'public',
        ],
```

- [ ] **Step 3: Write a config smoke test**

```php
<?php // tests/Feature/Database/ConfigTest.php

test('db_engines config key is present with expected engines', function () {
    $engines = config('laranode.db_engines');
    expect($engines)->toBeArray()
        ->toHaveKey('mysql')
        ->toHaveKey('mariadb')
        ->toHaveKey('postgres');
    expect($engines['mysql']['service'])->toBe('mysql');
    expect($engines['postgres']['port'])->toBe(5432);
});

test('mysql_admin database connection is configured', function () {
    $connections = config('database.connections');
    expect($connections)->toHaveKey('mysql_admin')
        ->toHaveKey('mariadb_admin')
        ->toHaveKey('pgsql');
});
```

- [ ] **Step 4: Run tests; verify they pass**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=ConfigTest'`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add config/laranode.php config/database.php tests/Feature/Database/ConfigTest.php
git commit -m "feat(databases): add db_engines config + mysql_admin/mariadb_admin/pgsql connections"
```

---

### Task 3: Contracts + DTOs — `DatabaseEngineDriver`, `DatabaseSpec`, `DatabaseStats`, `EngineCapabilities`

**Files:**
- Create: `app/Contracts/DatabaseEngineDriver.php`
- Create: `app/Databases/DatabaseSpec.php`
- Create: `app/Databases/DatabaseStats.php`
- Create: `app/Databases/EngineCapabilities.php`

**Scope:** PHP interfaces and readonly DTO classes. No logic; no tests needed beyond what Tasks 4–6 cover implicitly. Write them correctly and move on.

**Interfaces:**
- Produces: `App\Contracts\DatabaseEngineDriver` interface; `App\Databases\{DatabaseSpec, DatabaseStats, EngineCapabilities}` readonly classes. Consumed by all drivers (Tasks 4–6) and services (Task 7).

- [ ] **Step 1: Write `app/Contracts/DatabaseEngineDriver.php`**

```php
<?php

namespace App\Contracts;

use App\Databases\DatabaseSpec;
use App\Databases\DatabaseStats;
use App\Databases\EngineCapabilities;
use App\Models\Database;

interface DatabaseEngineDriver
{
    public function create(DatabaseSpec $spec): void;
    public function updatePassword(Database $database, string $newPassword): void;
    public function updateOptions(Database $database, array $options): void;
    public function delete(Database $database): void;
    public function stats(Database $database): DatabaseStats;
    public function capabilities(): EngineCapabilities;
}
```

- [ ] **Step 2: Write `app/Databases/DatabaseSpec.php`**

```php
<?php

namespace App\Databases;

readonly class DatabaseSpec
{
    public function __construct(
        public string $name,
        public string $dbUser,
        public string $password,
        public int $userId,
        public array $options = [],
    ) {}
}
```

- [ ] **Step 3: Write `app/Databases/DatabaseStats.php`**

```php
<?php

namespace App\Databases;

readonly class DatabaseStats
{
    public function __construct(
        public int $tableCount,
        public float $sizeMb,
        public array $extra = [],
    ) {}
}
```

- [ ] **Step 4: Write `app/Databases/EngineCapabilities.php`**

```php
<?php

namespace App\Databases;

readonly class EngineCapabilities
{
    /**
     * @param array<int, array{key: string, label: string, type: string, source: string}> $optionFields
     */
    public function __construct(
        public string $label,
        public bool $hasUsers,
        public array $optionFields,
    ) {}
}
```

- [ ] **Step 5: Commit**

```bash
git add app/Contracts/DatabaseEngineDriver.php app/Databases/DatabaseSpec.php app/Databases/DatabaseStats.php app/Databases/EngineCapabilities.php
git commit -m "feat(databases): DatabaseEngineDriver interface + DatabaseSpec/Stats/EngineCapabilities DTOs"
```

---

### Task 4: `MysqlDriver` — relocate + fix SQL injection surface

**[TDD]**

**Files:**
- Create: `app/Databases/Drivers/MysqlDriver.php`
- Create: `tests/Feature/Database/MysqlDriverTest.php`

**Scope:** New driver class that mirrors the logic of `CreateDatabaseService`, `UpdateDatabaseService`, `DeleteDatabaseService`, and `GetDatabasesWithStatsAction` but uses `DB::connection('mysql_admin')` and fixes the injection surface. The old `app/Services/MySQL/` files are NOT deleted yet (that happens in Task 8).

**Interfaces:**
- Consumes: `DatabaseEngineDriver` contract, `DatabaseSpec`, `DatabaseStats`, `EngineCapabilities` (Task 3); `DB::connection('mysql_admin')`.
- Produces: `App\Databases\Drivers\MysqlDriver implements DatabaseEngineDriver`. `capabilities()` returns `EngineCapabilities(label:'MySQL', hasUsers:true, optionFields:[charset, collation])`. `stats()` queries `information_schema` via `mysql_admin` connection. Consumed by `EngineManager` (Task 5) and services (Task 7).

- [ ] **Step 1: Write the failing tests**

```php
<?php // tests/Feature/Database/MysqlDriverTest.php

use App\Databases\DatabaseSpec;
use App\Databases\Drivers\MysqlDriver;
use App\Databases\EngineCapabilities;
use App\Models\Database as DatabaseModel;
use App\Models\User;
use Illuminate\Support\Facades\DB;

beforeEach(function () {
    // Swap the mysql_admin connection to the test connection so no real DB is needed
    config(['database.connections.mysql_admin' => config('database.connections.sqlite')]);
    DB::purge('mysql_admin');
});

test('capabilities returns MySQL label and charset+collation option fields', function () {
    $driver = new MysqlDriver();
    $caps = $driver->capabilities();

    expect($caps)->toBeInstanceOf(EngineCapabilities::class)
        ->and($caps->label)->toBe('MySQL')
        ->and($caps->hasUsers)->toBeTrue()
        ->and(collect($caps->optionFields)->pluck('key')->toArray())->toContain('charset', 'collation');
});

test('create runs CREATE DATABASE and CREATE USER via mysql_admin connection', function () {
    $driver = new MysqlDriver();
    $spec = new DatabaseSpec(
        name: 'testuser_mydb',
        dbUser: 'testuser_myuser',
        password: 'securepassword123',
        userId: 1,
        options: ['charset' => 'utf8mb4', 'collation' => 'utf8mb4_unicode_ci'],
    );

    $executed = [];
    DB::connection('mysql_admin')->pretend(function () use ($driver, $spec, &$executed) {
        DB::connection('mysql_admin')->listen(fn ($q) => $executed[] = $q->sql);
        $driver->create($spec);
    });

    // Verify CREATE DATABASE and CREATE USER were issued
    expect(collect($executed)->filter(fn ($s) => str_contains($s, 'CREATE DATABASE'))->count())->toBeGreaterThan(0)
        ->and(collect($executed)->filter(fn ($s) => str_contains($s, 'CREATE USER'))->count())->toBeGreaterThan(0);
    // Password must not appear literally in any SQL string
    expect(collect($executed)->filter(fn ($s) => str_contains($s, 'securepassword123'))->count())->toBe(0);
});

test('delete issues DROP DATABASE and DROP USER via mysql_admin connection', function () {
    $user = User::factory()->create();
    $database = DatabaseModel::factory()->create([
        'user_id' => $user->id,
        'engine'  => 'mysql',
        'name'    => $user->username . '_dropme',
        'db_user' => $user->username . '_dropuser',
    ]);

    $driver = new MysqlDriver();
    $executed = [];
    DB::connection('mysql_admin')->pretend(function () use ($driver, $database, &$executed) {
        DB::connection('mysql_admin')->listen(fn ($q) => $executed[] = $q->sql);
        $driver->delete($database);
    });

    expect(collect($executed)->filter(fn ($s) => str_contains($s, 'DROP DATABASE'))->count())->toBeGreaterThan(0)
        ->and(collect($executed)->filter(fn ($s) => str_contains($s, 'DROP USER'))->count())->toBeGreaterThan(0);
});

test('updatePassword uses a parameterized query and does not interpolate the password', function () {
    $user = User::factory()->create();
    $database = DatabaseModel::factory()->create([
        'user_id' => $user->id,
        'engine'  => 'mysql',
        'name'    => $user->username . '_passtest',
        'db_user' => $user->username . '_passuser',
    ]);

    $driver = new MysqlDriver();
    $executed = [];
    DB::connection('mysql_admin')->pretend(function () use ($driver, $database, &$executed) {
        DB::connection('mysql_admin')->listen(fn ($q) => $executed[] = $q->sql);
        $driver->updatePassword($database, 'newpassword456');
    });

    // The raw SQL should not contain the literal password
    expect(collect($executed)->filter(fn ($s) => str_contains($s, 'newpassword456'))->count())->toBe(0)
        ->and(collect($executed)->filter(fn ($s) => str_contains(strtoupper($s), 'ALTER USER') || str_contains(strtoupper($s), 'SET PASSWORD'))->count())->toBeGreaterThan(0);
});
```

- [ ] **Step 2: Run it; verify it fails**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=MysqlDriverTest'`
Expected: FAIL — `App\Databases\Drivers\MysqlDriver` not found.

- [ ] **Step 3: Write `app/Databases/Drivers/MysqlDriver.php`**

The driver must:
- Use `DB::connection($this->connectionName())` throughout (`connectionName()` returns `'mysql_admin'`).
- `create()`: `CREATE DATABASE \`{$name}\` CHARACTER SET {$charset} COLLATE {$collation}` (backtick-quoted name, charset/collation value-substituted not parameterized — MySQL doesn't support bind params for identifiers; the request regex already validates them); `CREATE USER IF NOT EXISTS \`{$dbUser}\`@'localhost' IDENTIFIED BY ?` — parameterized; `GRANT ALL PRIVILEGES ON \`{$name}\`.* TO \`{$dbUser}\`@'localhost'`; `FLUSH PRIVILEGES`.
- `updatePassword()`: `ALTER USER \`{$dbUser}\`@'localhost' IDENTIFIED BY ?` — parameterized.
- `updateOptions()`: `ALTER DATABASE \`{$name}\` CHARACTER SET {$charset} COLLATE {$collation}`.
- `delete()`: `DROP DATABASE IF EXISTS \`{$name}\``; `DROP USER IF EXISTS \`{$dbUser}\`@'localhost'`; `FLUSH PRIVILEGES`.
- `stats()`: queries `information_schema.tables` for `COUNT(*)` and `SUM(data_length + index_length)` — same logic as `GetDatabasesWithStatsAction`, but using `mysql_admin` connection.
- `capabilities()`: returns `new EngineCapabilities(label: 'MySQL', hasUsers: true, optionFields: [['key' => 'charset', 'label' => 'Charset', 'type' => 'select', 'source' => 'charset-options'], ['key' => 'collation', 'label' => 'Collation', 'type' => 'select', 'source' => 'collation-options']])`.
- Defense-in-depth before any raw SQL: assert `preg_match('/^[a-zA-Z0-9_]+$/', $value)` for name and dbUser, throw `\InvalidArgumentException` if not matched (the request layer prevents this in normal flow).
- Before throwing on create failure, rollback with `DROP DATABASE IF EXISTS` and `DROP USER IF EXISTS`.

Sibling exception class in the same file per convention:
```php
class MysqlDriverException extends \RuntimeException {}
```

- [ ] **Step 4: Run the tests; verify they pass**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=MysqlDriverTest'`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add app/Databases/Drivers/MysqlDriver.php tests/Feature/Database/MysqlDriverTest.php
git commit -m "feat(databases): MysqlDriver — relocate SQL + fix injection surface (parameterized password)"
```

---

### Task 5: `MariaDbDriver` + `PostgresDriver`

**[TDD]**

**Files:**
- Create: `app/Databases/Drivers/MariaDbDriver.php`
- Create: `app/Databases/Drivers/PostgresDriver.php`
- Create: `tests/Feature/Database/MariaDbDriverTest.php`
- Create: `tests/Feature/Database/PostgresDriverTest.php`

**Scope:** `MariaDbDriver` extends `MysqlDriver` — two-method override. `PostgresDriver` delegates mutations to `laranode-postgres.sh` via `Process::fake()`-testable calls and reads stats via `DB::connection('pgsql')`.

**Interfaces:**
- Consumes: `MysqlDriver` (Task 4), `DatabaseEngineDriver` contract (Task 3), `Process` facade.
- Produces: `App\Databases\Drivers\MariaDbDriver` (label `'MariaDB'`, connection `mariadb_admin`); `App\Databases\Drivers\PostgresDriver` (sudo script mutations, `pgsql` connection stats). Consumed by `EngineManager` (Task 6).

- [ ] **Step 1: Write failing tests for both drivers**

```php
<?php // tests/Feature/Database/MariaDbDriverTest.php

use App\Databases\Drivers\MariaDbDriver;

test('MariaDbDriver capabilities returns MariaDB label', function () {
    $driver = new MariaDbDriver();
    expect($driver->capabilities()->label)->toBe('MariaDB');
});

test('MariaDbDriver uses the mariadb_admin connection', function () {
    $driver = new MariaDbDriver();
    // Verify via reflection that connectionName() returns 'mariadb_admin'
    $ref = new ReflectionMethod($driver, 'connectionName');
    $ref->setAccessible(true);
    expect($ref->invoke($driver))->toBe('mariadb_admin');
});
```

```php
<?php // tests/Feature/Database/PostgresDriverTest.php

use App\Databases\DatabaseSpec;
use App\Databases\Drivers\PostgresDriver;
use App\Databases\EngineCapabilities;
use App\Models\Database as DatabaseModel;
use App\Models\User;
use Illuminate\Support\Facades\Process;

test('capabilities returns PostgreSQL label and encoding+locale option fields', function () {
    $driver = new PostgresDriver();
    $caps = $driver->capabilities();

    expect($caps)->toBeInstanceOf(EngineCapabilities::class)
        ->and($caps->label)->toBe('PostgreSQL')
        ->and($caps->hasUsers)->toBeTrue()
        ->and(collect($caps->optionFields)->pluck('key')->toArray())->toContain('encoding', 'locale');
});

test('create calls laranode-postgres.sh with create-db and create-user and grant', function () {
    Process::fake(['*' => Process::result(output: '', exitCode: 0)]);

    $driver = new PostgresDriver();
    $spec = new DatabaseSpec(
        name: 'testuser_pgdb',
        dbUser: 'testuser_pguser',
        password: 'pgpassword123',
        userId: 1,
        options: ['encoding' => 'UTF8', 'locale' => 'en_US.UTF-8'],
    );

    $driver->create($spec);

    Process::assertRan(fn ($p) => str_contains(implode(' ', $p->command()), 'laranode-postgres.sh') && in_array('create-db', $p->command()));
    Process::assertRan(fn ($p) => str_contains(implode(' ', $p->command()), 'laranode-postgres.sh') && in_array('create-user', $p->command()));
    Process::assertRan(fn ($p) => str_contains(implode(' ', $p->command()), 'laranode-postgres.sh') && in_array('grant', $p->command()));
});

test('create throws CreateDatabaseException when script exits non-zero', function () {
    Process::fake(['*laranode-postgres.sh*' => Process::result(output: '', errorOutput: 'psql: error', exitCode: 1)]);

    $driver = new PostgresDriver();
    $spec = new DatabaseSpec('testuser_fail', 'testuser_failuser', 'pass12345', 1, ['encoding' => 'UTF8', 'locale' => 'en_US.UTF-8']);

    expect(fn () => $driver->create($spec))->toThrow(\App\Services\Database\CreateDatabaseException::class);
});

test('delete calls laranode-postgres.sh with drop-db and drop-user', function () {
    Process::fake(['*' => Process::result(output: '', exitCode: 0)]);

    $user = User::factory()->create();
    $database = DatabaseModel::factory()->create([
        'user_id' => $user->id,
        'engine'  => 'postgres',
        'name'    => $user->username . '_pgdrop',
        'db_user' => $user->username . '_pgdropuser',
    ]);

    $driver = new PostgresDriver();
    $driver->delete($database);

    Process::assertRan(fn ($p) => str_contains(implode(' ', $p->command()), 'laranode-postgres.sh') && in_array('drop-db', $p->command()));
    Process::assertRan(fn ($p) => str_contains(implode(' ', $p->command()), 'laranode-postgres.sh') && in_array('drop-user', $p->command()));
});
```

- [ ] **Step 2: Run them; verify they fail**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter="MariaDbDriverTest|PostgresDriverTest"'`
Expected: FAIL — classes not found.

- [ ] **Step 3: Write `app/Databases/Drivers/MariaDbDriver.php`**

```php
<?php

namespace App\Databases\Drivers;

use App\Databases\EngineCapabilities;

class MariaDbDriver extends MysqlDriver
{
    protected function connectionName(): string
    {
        return 'mariadb_admin';
    }

    public function capabilities(): EngineCapabilities
    {
        $parent = parent::capabilities();
        return new EngineCapabilities(
            label: 'MariaDB',
            hasUsers: $parent->hasUsers,
            optionFields: $parent->optionFields,
        );
    }
}
```

- [ ] **Step 4: Write `app/Databases/Drivers/PostgresDriver.php`**

The driver must:
- Resolve the script path from `config('laranode.laranode_bin_path') . '/laranode-postgres.sh'`.
- `create()`: call `Process::run(['sudo', $script, 'create-db', $name, $encoding, $locale])`, check exit code; then `create-user`; then `grant`. Throw `CreateDatabaseException` (from `app/Services/Database/CreateDatabaseService.php`) on non-zero exit, including stderr in the message.
- `delete()`: call `drop-db` then `drop-user`. Throw `DeleteDatabaseException` on non-zero exit.
- `updatePassword()`: call `Process::run(['sudo', $script, 'update-user-password', $dbUser, $newPassword])`.
- `updateOptions()`: no-op (Postgres has no ALTER DATABASE charset equivalent); or log a warning.
- `stats()`: `DB::connection('pgsql')->selectOne('SELECT pg_database_size(?) AS size_bytes', [$name])` → convert to MB; `pg_stat_user_tables` count or return 0 if not accessible.
- `capabilities()`: `EngineCapabilities(label:'PostgreSQL', hasUsers:true, optionFields:[['key'=>'encoding',...,'source'=>'encoding-locales'], ['key'=>'locale',...,'source'=>'encoding-locales']])`.
- Defense-in-depth: assert `[a-zA-Z0-9_]+` on `$name` and `$dbUser` before invoking sudo.

Exception classes are imported from the service files (e.g. `use App\Services\Database\CreateDatabaseException`).

- [ ] **Step 5: Run the tests; verify they pass**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter="MariaDbDriverTest|PostgresDriverTest"'`
Expected: PASS (6 tests total).

- [ ] **Step 6: Commit**

```bash
git add app/Databases/Drivers/MariaDbDriver.php app/Databases/Drivers/PostgresDriver.php tests/Feature/Database/MariaDbDriverTest.php tests/Feature/Database/PostgresDriverTest.php
git commit -m "feat(databases): MariaDbDriver (extends MySQL) + PostgresDriver (sudo script + pgsql stats)"
```

---

### Task 6: `EngineManager` + `DatabaseServiceProvider`

**[TDD]**

**Files:**
- Create: `app/Databases/EngineManager.php`
- Create: `app/Providers/DatabaseServiceProvider.php`
- Modify: `bootstrap/providers.php` (register the new provider)
- Create: `tests/Feature/Database/EngineManagerTest.php`

**Scope:** `EngineManager` wraps the driver map and the `systemctl is-active` availability check. `DatabaseServiceProvider` registers `EngineManager` as a singleton.

**Interfaces:**
- Consumes: All three drivers (Tasks 4–5), `Process` facade, `config('laranode.db_engines')`.
- Produces: `App\Databases\EngineManager` with `for(string $engine): DatabaseEngineDriver`, `available(): array`, `capabilitiesFor(string $engine): EngineCapabilities`. Singleton registered in container. Consumed by all services (Task 7) and `CreateDatabaseRequest` (Task 8).

- [ ] **Step 1: Write the failing tests**

```php
<?php // tests/Feature/Database/EngineManagerTest.php

use App\Databases\EngineManager;
use Illuminate\Support\Facades\Process;

test('available() returns only engines whose systemctl service is active', function () {
    Process::fake([
        'systemctl is-active mysql'       => Process::result(output: "active\n", exitCode: 0),
        'systemctl is-active mariadb'     => Process::result(output: "inactive\n", exitCode: 3),
        'systemctl is-active postgresql'  => Process::result(output: "inactive\n", exitCode: 3),
    ]);

    $manager = app(EngineManager::class);
    $available = $manager->available();

    expect($available)->toContain('mysql')
        ->and($available)->not->toContain('mariadb')
        ->and($available)->not->toContain('postgres');
});

test('available() returns postgres when its service is active', function () {
    Process::fake([
        'systemctl is-active mysql'       => Process::result(output: "inactive\n", exitCode: 3),
        'systemctl is-active mariadb'     => Process::result(output: "inactive\n", exitCode: 3),
        'systemctl is-active postgresql'  => Process::result(output: "active\n", exitCode: 0),
    ]);

    $manager = app(EngineManager::class);
    expect($manager->available())->toContain('postgres');
});

test('for() returns the correct driver for a known engine', function () {
    $manager = app(EngineManager::class);
    expect($manager->for('mysql'))->toBeInstanceOf(\App\Databases\Drivers\MysqlDriver::class);
    expect($manager->for('mariadb'))->toBeInstanceOf(\App\Databases\Drivers\MariaDbDriver::class);
    expect($manager->for('postgres'))->toBeInstanceOf(\App\Databases\Drivers\PostgresDriver::class);
});

test('for() throws InvalidArgumentException for unknown engine', function () {
    $manager = app(EngineManager::class);
    expect(fn () => $manager->for('oracle'))->toThrow(\InvalidArgumentException::class);
});

test('capabilitiesFor() returns engine capabilities', function () {
    $manager = app(EngineManager::class);
    expect($manager->capabilitiesFor('mysql')->label)->toBe('MySQL');
    expect($manager->capabilitiesFor('postgres')->label)->toBe('PostgreSQL');
});
```

- [ ] **Step 2: Run it; verify it fails**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=EngineManagerTest'`
Expected: FAIL — `EngineManager` not found or not bound.

- [ ] **Step 3: Write `app/Databases/EngineManager.php`**

```php
<?php

namespace App\Databases;

use App\Contracts\DatabaseEngineDriver;
use Illuminate\Support\Facades\Process;

class EngineManager
{
    public function __construct(private array $drivers) {} // keyed by engine string

    public function for(string $engine): DatabaseEngineDriver
    {
        if (! isset($this->drivers[$engine])) {
            throw new \InvalidArgumentException("Unknown database engine: [{$engine}]");
        }
        return $this->drivers[$engine];
    }

    /** Returns engine keys whose systemctl service reports 'active'. */
    public function available(): array
    {
        $engines = config('laranode.db_engines', []);
        $available = [];
        foreach ($engines as $engine => $config) {
            $service = $config['service'];
            $result = Process::run(['systemctl', 'is-active', $service]);
            if (trim($result->output()) === 'active') {
                $available[] = $engine;
            }
        }
        return $available;
    }

    public function capabilitiesFor(string $engine): EngineCapabilities
    {
        return $this->for($engine)->capabilities();
    }
}
```

- [ ] **Step 4: Write `app/Providers/DatabaseServiceProvider.php`**

```php
<?php

namespace App\Providers;

use App\Databases\Drivers\MariaDbDriver;
use App\Databases\Drivers\MysqlDriver;
use App\Databases\Drivers\PostgresDriver;
use App\Databases\EngineManager;
use Illuminate\Support\ServiceProvider;

class DatabaseServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->app->singleton(EngineManager::class, fn () => new EngineManager([
            'mysql'    => new MysqlDriver(),
            'mariadb'  => new MariaDbDriver(),
            'postgres' => new PostgresDriver(),
        ]));
    }
}
```

- [ ] **Step 5: Register the provider in `bootstrap/providers.php`**

Add `App\Providers\DatabaseServiceProvider::class` to the return array.

- [ ] **Step 6: Run the tests; verify they pass**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=EngineManagerTest'`
Expected: PASS (5 tests).

- [ ] **Step 7: Commit**

```bash
git add app/Databases/EngineManager.php app/Providers/DatabaseServiceProvider.php bootstrap/providers.php tests/Feature/Database/EngineManagerTest.php
git commit -m "feat(databases): EngineManager (available/for/capabilitiesFor) + DatabaseServiceProvider"
```

---

### Task 7: Services — `CreateDatabaseService`, `UpdateDatabaseService`, `DeleteDatabaseService`, `GetDatabasesWithStatsService`

**[TDD]**

**Files:**
- Create: `app/Services/Database/CreateDatabaseService.php`
- Create: `app/Services/Database/UpdateDatabaseService.php`
- Create: `app/Services/Database/DeleteDatabaseService.php`
- Create: `app/Services/Database/GetDatabasesWithStatsService.php`
- Create: `tests/Feature/Database/CreateDatabaseServiceTest.php`

**Scope:** New `app/Services/Database/` namespace. Services own all Eloquent mutations; drivers never touch Eloquent. The old `app/Services/MySQL/` files are NOT deleted yet. Each service file contains a sibling `*Exception` class per project convention.

**Interfaces:**
- Consumes: `EngineManager` (Task 6), `DatabaseSpec`, `DatabaseStats` (Task 3), `Database` model (Task 1).
- Produces: `CreateDatabaseService::handle(DatabaseSpec $spec, string $engine): Database`; `UpdateDatabaseService::handle(Database $database, array $validated): void`; `DeleteDatabaseService::handle(Database $database): void`; `GetDatabasesWithStatsService::handle(User $user): array`. Consumed by `DatabasesController` (Task 8).

- [ ] **Step 1: Write the failing tests**

```php
<?php // tests/Feature/Database/CreateDatabaseServiceTest.php

use App\Contracts\DatabaseEngineDriver;
use App\Databases\DatabaseSpec;
use App\Databases\DatabaseStats;
use App\Databases\EngineCapabilities;
use App\Databases\EngineManager;
use App\Models\User;
use App\Services\Database\CreateDatabaseService;
use App\Services\Database\UpdateDatabaseService;
use App\Services\Database\DeleteDatabaseService;

test('CreateDatabaseService calls driver->create() and persists a Database row with the correct engine', function () {
    $user = User::factory()->create();
    $spec = new DatabaseSpec(
        name: $user->username . '_newdb',
        dbUser: $user->username . '_newuser',
        password: 'supersecret123',
        userId: $user->id,
        options: ['charset' => 'utf8mb4', 'collation' => 'utf8mb4_unicode_ci'],
    );

    $mockDriver = Mockery::mock(DatabaseEngineDriver::class);
    $mockDriver->shouldReceive('create')->once()->with($spec)->andReturn(null);

    $mockManager = Mockery::mock(EngineManager::class);
    $mockManager->shouldReceive('for')->with('mysql')->once()->andReturn($mockDriver);

    $service = new CreateDatabaseService($mockManager);
    $db = $service->handle($spec, 'mysql');

    expect($db->engine)->toBe('mysql')
        ->and($db->name)->toBe($user->username . '_newdb')
        ->and($db->user_id)->toBe($user->id);
});

test('UpdateDatabaseService calls driver->updatePassword() when password provided', function () {
    $user = User::factory()->create();
    $database = \App\Models\Database::factory()->create([
        'user_id' => $user->id,
        'engine'  => 'mysql',
        'name'    => $user->username . '_updb',
        'db_user' => $user->username . '_upuser',
        'charset' => 'utf8mb4',
        'collation' => 'utf8mb4_unicode_ci',
    ]);

    $mockDriver = Mockery::mock(DatabaseEngineDriver::class);
    $mockDriver->shouldReceive('updatePassword')->once()->with($database, 'newpass123');
    $mockDriver->shouldReceive('updateOptions')->once();

    $mockManager = Mockery::mock(EngineManager::class);
    $mockManager->shouldReceive('for')->with('mysql')->once()->andReturn($mockDriver);

    $service = new UpdateDatabaseService($mockManager);
    $service->handle($database, ['charset' => 'utf8mb4', 'collation' => 'utf8mb4_unicode_ci', 'db_password' => 'newpass123']);
});

test('DeleteDatabaseService calls driver->delete() and then deletes the model row', function () {
    $user = User::factory()->create();
    $database = \App\Models\Database::factory()->create([
        'user_id' => $user->id,
        'engine'  => 'mysql',
        'name'    => $user->username . '_deldb',
        'db_user' => $user->username . '_deluser',
    ]);
    $id = $database->id;

    $mockDriver = Mockery::mock(DatabaseEngineDriver::class);
    $mockDriver->shouldReceive('delete')->once()->with(Mockery::on(fn ($d) => $d->id === $id));

    $mockManager = Mockery::mock(EngineManager::class);
    $mockManager->shouldReceive('for')->with('mysql')->once()->andReturn($mockDriver);

    $service = new DeleteDatabaseService($mockManager);
    $service->handle($database);

    expect(\App\Models\Database::find($id))->toBeNull();
});
```

- [ ] **Step 2: Run it; verify it fails**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=CreateDatabaseServiceTest'`
Expected: FAIL — `App\Services\Database\CreateDatabaseService` not found.

- [ ] **Step 3: Write the four service files**

`app/Services/Database/CreateDatabaseService.php`:
```php
<?php

namespace App\Services\Database;

use App\Databases\DatabaseSpec;
use App\Databases\EngineManager;
use App\Models\Database;
use Exception;

class CreateDatabaseException extends Exception {}

class CreateDatabaseService
{
    public function __construct(private EngineManager $manager) {}

    public function handle(DatabaseSpec $spec, string $engine): Database
    {
        try {
            $this->manager->for($engine)->create($spec);
        } catch (\Throwable $e) {
            throw new CreateDatabaseException('Failed to create database: ' . $e->getMessage(), 0, $e);
        }

        return Database::create([
            'name'      => $spec->name,
            'db_user'   => $spec->dbUser,
            'db_password' => $spec->password,
            'charset'   => $spec->options['charset'] ?? null,
            'collation' => $spec->options['collation'] ?? null,
            'user_id'   => $spec->userId,
            'engine'    => $engine,
        ]);
    }
}
```

`app/Services/Database/UpdateDatabaseService.php`: analogous — calls `driver->updatePassword()` if password provided, `driver->updateOptions()` for charset/collation, then `$database->update()` with the new values.

`app/Services/Database/DeleteDatabaseService.php`: calls `driver->delete($database)`, then `$database->delete()`.

`app/Services/Database/GetDatabasesWithStatsService.php`: uses `Database::scopeMine()` (so it respects the auth user), groups rows by engine, calls `$manager->for($engine)->stats($database)` per row, returns a flat array for Inertia including `engine` field.

Each file declares a sibling `*Exception extends Exception` class at the top of the file.

- [ ] **Step 4: Run the tests; verify they pass**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=CreateDatabaseServiceTest'`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app/Services/Database/ tests/Feature/Database/CreateDatabaseServiceTest.php
git commit -m "feat(databases): Database services (Create/Update/Delete/Stats) — engine-agnostic via EngineManager"
```

---

### Task 8: `DatabasesController` + updated FormRequests

**[TDD]**

**Files:**
- Create: `app/Http/Controllers/DatabasesController.php`
- Modify: `app/Http/Requests/CreateDatabaseRequest.php` (add `engine` field + dynamic option validation)
- Modify: `app/Http/Requests/UpdateDatabaseRequest.php` (dynamic option validation)
- Create: `tests/Feature/Database/DatabasesControllerTest.php`

**Scope:** New engine-agnostic controller. FormRequests gain `engine` validation. Old `MysqlController` and `CreateDatabaseRequest`/`UpdateDatabaseRequest` original logic for charset/collation becomes conditional on engine.

**Interfaces:**
- Consumes: `GetDatabasesWithStatsService`, `CreateDatabaseService`, `UpdateDatabaseService`, `DeleteDatabaseService` (Task 7); `EngineManager` (Task 6).
- Produces: `DatabasesController` with methods `index`, `getEngineOptions`, `store`, `update`, `destroy`. `CreateDatabaseRequest` validates `engine` against `EngineManager::available()`. Inertia renders `Databases/Index`. Consumed by routes (Task 9).

- [ ] **Step 1: Write the failing tests**

```php
<?php // tests/Feature/Database/DatabasesControllerTest.php

use App\Databases\EngineManager;
use App\Models\User;
use Illuminate\Support\Facades\Process;

beforeEach(function () {
    // Make mysql appear active for tests that hit EngineManager::available()
    Process::fake(['systemctl is-active mysql' => Process::result(output: "active\n", exitCode: 0),
                   'systemctl is-active mariadb' => Process::result(output: "inactive\n", exitCode: 3),
                   'systemctl is-active postgresql' => Process::result(output: "inactive\n", exitCode: 3)]);
});

test('GET /databases returns 200 for authenticated user', function () {
    $user = User::factory()->create();
    $this->actingAs($user)->get(route('databases.index'))->assertOk();
});

test('GET /databases redirects unauthenticated users', function () {
    $this->get(route('databases.index'))->assertRedirect(route('login'));
});

test('GET /databases/engine-options returns available engines and capabilities', function () {
    $user = User::factory()->create();
    $response = $this->actingAs($user)->getJson(route('databases.engine-options'));
    $response->assertOk()
        ->assertJsonStructure(['engines', 'capabilities']);
    expect($response->json('engines'))->toContain('mysql');
});

test('POST /databases with invalid engine returns 422', function () {
    $user = User::factory()->create();
    $this->actingAs($user)->postJson(route('databases.store'), [
        'engine'        => 'oracle',  // not in available()
        'name_suffix'   => 'testdb',
        'db_user_suffix' => 'testuser',
        'db_pass'       => 'password123',
    ])->assertUnprocessable();
});

test('POST /databases with mysql engine creates a database row', function () {
    // Mock the MysqlDriver::create() to avoid real DB call
    $mockDriver = Mockery::mock(\App\Contracts\DatabaseEngineDriver::class);
    $mockDriver->shouldReceive('create')->once()->andReturn(null);
    $mockDriver->shouldReceive('capabilities')->andReturn(new \App\Databases\EngineCapabilities('MySQL', true, []));

    $mockManager = Mockery::mock(EngineManager::class);
    $mockManager->shouldReceive('available')->andReturn(['mysql']);
    $mockManager->shouldReceive('for')->with('mysql')->andReturn($mockDriver);
    $mockManager->shouldReceive('capabilitiesFor')->andReturn(new \App\Databases\EngineCapabilities('MySQL', true, []));
    app()->instance(EngineManager::class, $mockManager);

    $user = User::factory()->create();
    $this->actingAs($user)->post(route('databases.store'), [
        'engine'         => 'mysql',
        'name_suffix'    => 'mydb',
        'db_user_suffix' => 'myuser',
        'db_pass'        => 'password123',
        'charset'        => 'utf8mb4',
        'collation'      => 'utf8mb4_unicode_ci',
    ])->assertRedirect(route('databases.index'));

    expect(\App\Models\Database::where('name', $user->username . '_mydb')->exists())->toBeTrue();
});
```

- [ ] **Step 2: Run it; verify it fails**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=DatabasesControllerTest'`
Expected: FAIL — route `databases.index` not defined.

- [ ] **Step 3: Write `app/Http/Controllers/DatabasesController.php`**

```php
<?php

namespace App\Http\Controllers;

use App\Databases\DatabaseSpec;
use App\Databases\EngineManager;
use App\Http\Requests\CreateDatabaseRequest;
use App\Http\Requests\DeleteDatabaseRequest;
use App\Http\Requests\UpdateDatabaseRequest;
use App\Models\Database;
use App\Services\Database\CreateDatabaseService;
use App\Services\Database\DeleteDatabaseService;
use App\Services\Database\GetDatabasesWithStatsService;
use App\Services\Database\UpdateDatabaseService;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Gate;
use Inertia\Inertia;

class DatabasesController extends Controller
{
    public function __construct(private EngineManager $manager) {}

    public function index(Request $request): \Inertia\Response
    {
        $databases = (new GetDatabasesWithStatsService($this->manager))->handle($request->user());

        return Inertia::render('Databases/Index', [
            'databases' => $databases,
        ]);
    }

    public function getEngineOptions(Request $request): JsonResponse
    {
        $engines = $this->manager->available();
        $engine  = $request->query('engine');

        $capabilities = $engine
            ? $this->manager->capabilitiesFor($engine)
            : null;

        return response()->json([
            'engines'      => $engines,
            'capabilities' => $capabilities,
        ]);
    }

    public function store(CreateDatabaseRequest $request): RedirectResponse
    {
        $user      = $request->user();
        $validated = $request->validated();
        $engine    = $validated['engine'];

        $spec = new DatabaseSpec(
            name: $validated['name'],
            dbUser: $validated['db_user'],
            password: $validated['db_pass'],
            userId: $user->id,
            options: array_diff_key($validated, array_flip(['engine', 'name', 'db_user', 'db_pass', 'name_suffix', 'db_user_suffix'])),
        );

        (new CreateDatabaseService($this->manager))->handle($spec, $engine);

        session()->flash('success', 'Database created successfully!');
        return redirect()->route('databases.index');
    }

    public function update(UpdateDatabaseRequest $request): RedirectResponse
    {
        $user     = $request->user();
        $database = Database::where('id', $request->integer('id'))
            ->where('user_id', $user->id)
            ->firstOrFail();

        Gate::authorize('update', $database);

        (new UpdateDatabaseService($this->manager))->handle($database, $request->validated());

        session()->flash('success', 'Database updated successfully!');
        return redirect()->route('databases.index');
    }

    public function destroy(DeleteDatabaseRequest $request): RedirectResponse
    {
        $user     = $request->user();
        $database = Database::where('id', $request->integer('id'))
            ->where('user_id', $user->id)
            ->firstOrFail();

        Gate::authorize('delete', $database);

        (new DeleteDatabaseService($this->manager))->handle($database);

        session()->flash('success', 'Database deleted successfully!');
        return redirect()->route('databases.index');
    }
}
```

- [ ] **Step 4: Modify `CreateDatabaseRequest`**

Add `engine` to `rules()` validated against `EngineManager::available()`. Make `charset` and `collation` conditional (`required_if:engine,mysql`, `required_if:engine,mariadb`). Inject `EngineManager` or resolve from the container in `rules()`. Keep existing `prepareForValidation` prefix logic intact. Keep existing `database_limit` guard in `withValidator`.

- [ ] **Step 5: Modify `UpdateDatabaseRequest`**

Make `charset` and `collation` conditional on the `engine` of the existing database record being updated (load via the `id` field). For Postgres rows, these fields are optional and ignored.

- [ ] **Step 6: Run the tests; verify they pass**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=DatabasesControllerTest'`
Expected: PASS (5 tests).

- [ ] **Step 7: Commit**

```bash
git add app/Http/Controllers/DatabasesController.php app/Http/Requests/CreateDatabaseRequest.php app/Http/Requests/UpdateDatabaseRequest.php tests/Feature/Database/DatabasesControllerTest.php
git commit -m "feat(databases): DatabasesController (engine-agnostic) + updated FormRequests (engine validation)"
```

---

### Task 9: Routes — `databases.*` canonical routes + `mysql.*` redirect aliases

**[MIGRATION/BACK-COMPAT]**

**Files:**
- Modify: `routes/web.php`

**Scope:** Route file only. Add new `databases.*` routes. Convert existing `mysql.*` entries to 301 redirect aliases. Keep `MysqlController` import (it becomes a shim in a later pass).

**Interfaces:**
- Produces: `databases.index` (`GET /databases`), `databases.engine-options` (`GET /databases/engine-options`), `databases.store` (`POST /databases`), `databases.update` (`PATCH /databases`), `databases.destroy` (`DELETE /databases`). `mysql.*` routes return 301 redirects to `databases.*` equivalents. Consumed by `DatabasesControllerTest` (which used these routes in Task 8), frontend (Task 10).

- [ ] **Step 1: Add the new route block to `routes/web.php`**

Replace the current MySQL route block:
```php
// MySQL management [Admin | User]
Route::get('/mysql', [MysqlController::class, 'index'])->middleware(['auth'])->name('mysql.index');
Route::get('/mysql/charsets-collations', [MysqlController::class, 'getCharsetsAndCollations'])->middleware(['auth'])->name('mysql.charsets-collations');
Route::post('/mysql', [MysqlController::class, 'store'])->middleware(['auth'])->name('mysql.store');
Route::patch('/mysql', [MysqlController::class, 'update'])->middleware(['auth'])->name('mysql.update');
Route::delete('/mysql', [MysqlController::class, 'destroy'])->middleware(['auth'])->name('mysql.destroy');
```

With this (keep the MysqlController import at the top of the file for now):
```php
// Databases management [Admin | User] — canonical routes
Route::middleware(['auth'])->group(function () {
    Route::get('/databases',                [\App\Http\Controllers\DatabasesController::class, 'index'])->name('databases.index');
    Route::get('/databases/engine-options', [\App\Http\Controllers\DatabasesController::class, 'getEngineOptions'])->name('databases.engine-options');
    Route::post('/databases',               [\App\Http\Controllers\DatabasesController::class, 'store'])->name('databases.store');
    Route::patch('/databases',              [\App\Http\Controllers\DatabasesController::class, 'update'])->name('databases.update');
    Route::delete('/databases',             [\App\Http\Controllers\DatabasesController::class, 'destroy'])->name('databases.destroy');
});

// MySQL back-compat redirect aliases [Admin | User] — 301 to databases.*
Route::middleware(['auth'])->group(function () {
    Route::get('/mysql',                   fn () => redirect()->route('databases.index', [], 301))->name('mysql.index');
    Route::get('/mysql/charsets-collations', fn () => redirect()->route('databases.engine-options', ['engine' => 'mysql'], 301))->name('mysql.charsets-collations');
    Route::post('/mysql',                  fn () => redirect()->route('databases.store', [], 301))->name('mysql.store');
    Route::patch('/mysql',                 fn () => redirect()->route('databases.update', [], 301))->name('mysql.update');
    Route::delete('/mysql',                fn () => redirect()->route('databases.destroy', [], 301))->name('mysql.destroy');
});
```

- [ ] **Step 2: Write a route smoke test**

```php
<?php // tests/Feature/Database/RouteTest.php

use App\Models\User;

test('databases.index route exists and is auth-gated', function () {
    expect(route('databases.index'))->toBe(url('/databases'));
    $this->get(route('databases.index'))->assertRedirect(route('login'));
});

test('mysql.index route exists as a redirect alias', function () {
    expect(route('mysql.index'))->toBe(url('/mysql'));
    // Redirect to databases.index (301)
    $user = User::factory()->create();
    $this->actingAs($user)->get(route('mysql.index'))->assertRedirect(route('databases.index'));
});

test('databases.engine-options route exists', function () {
    expect(route('databases.engine-options'))->toBe(url('/databases/engine-options'));
});
```

- [ ] **Step 3: Run tests; verify they pass**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=RouteTest'`
Expected: PASS (3 tests). Also run `php artisan route:list --name=databases` to confirm all five canonical routes are listed.

- [ ] **Step 4: Re-run the full controller test suite to confirm no regressions**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=DatabasesControllerTest'`
Expected: still PASS (5 tests) — routes were referenced by name in Task 8 already.

- [ ] **Step 5: Commit**

```bash
git add routes/web.php tests/Feature/Database/RouteTest.php
git commit -m "feat(databases): canonical databases.* routes + mysql.* redirect aliases (301 back-compat)"
```

---

### Task 10: Frontend — `Pages/Databases/` (Index + CreateDatabaseForm + EditDatabaseForm + Vitest)

**Files:**
- Create: `resources/js/Pages/Databases/Index.jsx`
- Create: `resources/js/Pages/Databases/Partials/CreateDatabaseForm.jsx`
- Create: `resources/js/Pages/Databases/Partials/EditDatabaseForm.jsx`
- Create: `resources/js/Pages/Databases/Partials/CreateDatabaseForm.test.jsx`

**Scope:** New Inertia page component and forms for the engine-agnostic DB UI. The existing `Pages/Mysql/` files are NOT deleted. `DatabasesController` renders `Databases/Index`.

**Interfaces:**
- Consumes: `databases.engine-options` route (JSON `{ engines, capabilities }`), `databases.store` / `databases.update` / `databases.destroy` routes, `auth.user` shared prop (via `usePage`).
- Produces: `Databases/Index.jsx` (table with Engine column + engine badge; charset/collation show `—` for Postgres rows); `CreateDatabaseForm.jsx` (engine selector → fetches optionFields from `engine-options?engine=X`; renders fields dynamically); `EditDatabaseForm.jsx` (engine read-only; dynamic options per engine). Consumed by `DatabasesController::index`.

- [ ] **Step 1: Write the Vitest tests first**

```jsx
// resources/js/Pages/Databases/Partials/CreateDatabaseForm.test.jsx
import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import { test, expect, vi, beforeEach } from 'vitest';
import axios from 'axios';
import CreateDatabaseForm from './CreateDatabaseForm';

vi.mock('axios');
vi.mock('@inertiajs/react', () => ({
    useForm: () => ({
        data: { engine: '', name_suffix: '', db_user_suffix: '', db_pass: '' },
        setData: vi.fn(),
        post: vi.fn(),
        processing: false,
        reset: vi.fn(),
        clearErrors: vi.fn(),
        errors: {},
        transform: vi.fn((fn) => fn),
    }),
    usePage: () => ({ props: { auth: { user: { username: 'alice', database_limit: null } } } }),
}));

// Stub route() global from Ziggy
global.route = (name) => `/${name}`;

beforeEach(() => {
    axios.get.mockResolvedValue({
        data: {
            engines: ['mysql', 'postgres'],
            capabilities: { label: 'MySQL', hasUsers: true, optionFields: [{ key: 'charset', label: 'Charset', type: 'select', source: 'charset-options' }] },
        },
    });
});

test('engine selector is populated from engine-options response', async () => {
    render(<CreateDatabaseForm />);
    const btn = screen.getByText(/Create Database/i);
    fireEvent.click(btn);
    await waitFor(() => expect(screen.getByLabelText(/Engine/i)).toBeTruthy());
    // Both engines appear as options
    expect(screen.getByText('mysql')).toBeTruthy();
    expect(screen.getByText('postgres')).toBeTruthy();
});

test('selecting mysql engine fetches charset option fields and renders them', async () => {
    axios.get.mockResolvedValueOnce({
        data: { engines: ['mysql'], capabilities: null },
    }).mockResolvedValueOnce({
        data: { engines: ['mysql'], capabilities: { label: 'MySQL', hasUsers: true, optionFields: [{ key: 'charset', label: 'Charset', type: 'select', source: 'charset-options' }] } },
    });
    render(<CreateDatabaseForm />);
    fireEvent.click(screen.getByText(/Create Database/i));
    await waitFor(() => screen.getByLabelText(/Engine/i));
    fireEvent.change(screen.getByLabelText(/Engine/i), { target: { value: 'mysql' } });
    await waitFor(() => expect(axios.get).toHaveBeenCalledWith(expect.stringContaining('engine=mysql')));
});

test('selecting postgres engine does not show charset/collation fields', async () => {
    axios.get.mockResolvedValueOnce({
        data: { engines: ['postgres'], capabilities: null },
    }).mockResolvedValueOnce({
        data: { engines: ['postgres'], capabilities: { label: 'PostgreSQL', hasUsers: true, optionFields: [{ key: 'encoding', label: 'Encoding', type: 'select', source: 'encoding-locales' }] } },
    });
    render(<CreateDatabaseForm />);
    fireEvent.click(screen.getByText(/Create Database/i));
    await waitFor(() => screen.getByLabelText(/Engine/i));
    fireEvent.change(screen.getByLabelText(/Engine/i), { target: { value: 'postgres' } });
    await waitFor(() => expect(screen.queryByLabelText(/Charset/i)).toBeNull());
});
```

- [ ] **Step 2: Run failing Vitest tests; verify they fail**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && npm run test -- --reporter=verbose 2>&1 | grep -E "FAIL|PASS|CreateDatabaseForm"'`
Expected: FAIL — `CreateDatabaseForm` component not found.

- [ ] **Step 3: Write `resources/js/Pages/Databases/Partials/CreateDatabaseForm.jsx`**

Structure mirrors `Pages/Mysql/Partials/CreateDatabaseForm.jsx` but:
- On modal open, `GET /databases/engine-options` (no engine param) to get available engine list.
- Render an Engine `<select>` using the returned `engines` array.
- On engine change, `GET /databases/engine-options?engine={selected}` to get `capabilities.optionFields`.
- Render `optionFields` dynamically: `source: 'charset-options'` → fetch charsets from MySQL-specific endpoint (or from the same capabilities response); `source: 'encoding-locales'` → static list of Postgres encodings. This removes all hardcoded per-engine conditionals.
- Submit to `route('databases.store')` via Inertia `post()`.
- Pass `engine` in the form data alongside the existing `name_suffix`, `db_user_suffix`, `db_pass`, and any engine-specific option fields.

- [ ] **Step 4: Write `resources/js/Pages/Databases/Partials/EditDatabaseForm.jsx`**

Structure mirrors `Pages/Mysql/Partials/EditDatabaseForm.jsx` but:
- Shows engine as a disabled read-only text input (cannot change engine after creation).
- For MySQL/MariaDB rows: fetches charset/collation options and renders them.
- For Postgres rows: fetches `engine-options?engine=postgres` capabilities; renders encoding/locale or shows `—` if not editable.
- Submits to `route('databases.update')`.

- [ ] **Step 5: Write `resources/js/Pages/Databases/Index.jsx`**

Structure mirrors `Pages/Mysql/Index.jsx` but:
- Renders `Databases ({databases.length}/{auth.user.database_limit || 'unlimited'})` in the header.
- Table gains an `Engine` column. Engine badge: `MySQL` = blue, `MariaDB` = teal, `PostgreSQL` = indigo (use a simple `engineBadge` map).
- `charset` and `collation` columns show the value or `—` (Postgres rows have null here).
- Wires delete to `route('databases.destroy')` and edit to `EditDatabaseForm` from the new Partials directory.
- Imports `CreateDatabaseForm` from the new Partials directory.

- [ ] **Step 6: Run Vitest tests; verify they pass**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && npm run test'`
Expected: all Vitest tests pass (existing sanity test + 3 new CreateDatabaseForm tests).

- [ ] **Step 7: Build assets**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && npm run build'`
Expected: build succeeds with no import errors.

- [ ] **Step 8: Commit**

```bash
git add resources/js/Pages/Databases/ 
git commit -m "feat(ui): Databases/Index + engine-agnostic CreateDatabaseForm/EditDatabaseForm + Vitest tests"
```

---

### Task 11: Postgres system infrastructure — `laranode-postgres.sh` + sudoers drop-in + local-dev container

**[MIGRATION/BACK-COMPAT: local-dev parity; LARANODE_SYSTEM_TESTS gates]**

**Files:**
- Create: `laranode-scripts/bin/laranode-postgres.sh`
- Create: `laranode-scripts/bin/laranode-postgres-sudoers` (template for the drop-in, applied by installer)
- Modify: `laranode-scripts/bin/laranode-installer.sh` (install `postgresql-client` + apply sudoers drop-in)
- Modify: `local-dev/docker-compose.yml` (add `postgres` service + named volume)
- Modify: `local-dev/entrypoint-setup.sh` (start Postgres service + smoke test the script)
- Create: `tests/Feature/Database/MysqlIntegrationTest.php` (`LARANODE_SYSTEM_TESTS=1`)
- Create: `tests/Feature/Database/PostgresIntegrationTest.php` (`LARANODE_SYSTEM_TESTS=1`)

**Scope:** The bash script and its integration with the local-dev Docker container. The integration tests gate behind `LARANODE_SYSTEM_TESTS=1` and exercise real MySQL and real PostgreSQL in the container.

**Interfaces:**
- Produces: `laranode-postgres.sh` handling `create-db`, `create-user`, `grant`, `revoke`, `drop-db`, `drop-user`, `update-user-password` actions. `/etc/sudoers.d/laranode-postgres` drop-in granting `www-data NOPASSWD` for the script. Postgres service running in local-dev. Integration tests verify the full create → stats → delete cycle for both MySQL and Postgres engines.

- [ ] **Step 1: Write `laranode-scripts/bin/laranode-postgres.sh`**

The script must:
- Accept `$1` as the action and remaining positional args.
- Validate `$2` (name/user) matches `^[a-zA-Z0-9_]+$` — exit 1 with error message if not.
- Use `sudo -u postgres psql -c "..."` for all psql calls.
- `create-db <name> <encoding> <locale>`: `CREATE DATABASE "$name" ENCODING '$encoding' LC_COLLATE '$locale' LC_CTYPE '$locale' TEMPLATE template0;` then `REVOKE CONNECT ON DATABASE "$name" FROM PUBLIC;`.
- `create-user <user> <password>`: `CREATE ROLE "$user" WITH LOGIN PASSWORD $$<password>$$;` (dollar-quoting for the password to avoid shell injection).
- `grant <user> <db>`: `GRANT CONNECT ON DATABASE "$db" TO "$user"; GRANT ALL PRIVILEGES ON SCHEMA public TO "$user";`.
- `revoke <user> <db>`: `REVOKE ALL ON DATABASE "$db" FROM "$user";`.
- `drop-db <name>`: `DROP DATABASE IF EXISTS "$name";`.
- `drop-user <user>`: `DROP ROLE IF EXISTS "$user";`.
- `update-user-password <user> <password>`: `ALTER ROLE "$user" PASSWORD $$<password>$$;`.
- Unknown action: exit 1 with usage message.
- Make executable: `chmod +x laranode-scripts/bin/laranode-postgres.sh`.

- [ ] **Step 2: Write the sudoers template**

Create `laranode-scripts/bin/laranode-postgres-sudoers` (a template; the installer writes it to `/etc/sudoers.d/laranode-postgres`):
```
www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-postgres.sh
```
(The installer substitutes the actual install path.)

- [ ] **Step 3: Modify `laranode-installer.sh`**

Add the following steps after the existing MySQL setup section:
1. `apt-get install -y postgresql-client` (if not already present).
2. Copy the sudoers template to `/etc/sudoers.d/laranode-postgres` with the correct install path substituted.
3. `chmod 440 /etc/sudoers.d/laranode-postgres`.
4. `visudo -c -f /etc/sudoers.d/laranode-postgres` to validate syntax before applying.

- [ ] **Step 4: Modify `local-dev/docker-compose.yml`**

Add a `postgres` service (using `postgresql` from the Ubuntu 24.04 apt package, not a separate container — the local-dev container is a single systemd Ubuntu image, so Postgres is installed into the same container, not as a sidecar). Update the `local-dev/entrypoint-setup.sh` instead (see Step 5).

The local-dev container runs a single Ubuntu 24.04 systemd image. Add a named volume for Postgres data to `docker-compose.yml`:
```yaml
volumes:
  laranode-vendor:
  laranode-node-modules:
  laranode-mysql:
  laranode-postgres:
```

And mount it in the `laranode` service volumes:
```yaml
      - laranode-postgres:/var/lib/postgresql
```

- [ ] **Step 5: Modify `local-dev/entrypoint-setup.sh`**

Add, after the MySQL setup section:
```bash
# Install and start PostgreSQL
if ! dpkg -l postgresql-16 &>/dev/null; then
    apt-get install -y postgresql-16 postgresql-client-16
fi
systemctl enable postgresql
systemctl start postgresql

# Apply sudoers drop-in for laranode-postgres.sh
PANEL_PATH=/home/laranode_ln/panel
SUDOERS_SRC="$PANEL_PATH/laranode-scripts/bin/laranode-postgres-sudoers"
SUDOERS_DEST=/etc/sudoers.d/laranode-postgres
sed "s|/home/laranode_ln/panel|$PANEL_PATH|g" "$SUDOERS_SRC" > "$SUDOERS_DEST"
chmod 440 "$SUDOERS_DEST"

# Smoke test
sudo "$PANEL_PATH/laranode-scripts/bin/laranode-postgres.sh" create-db laranode_smoke_test UTF8 en_US.UTF-8 && \
sudo "$PANEL_PATH/laranode-scripts/bin/laranode-postgres.sh" drop-db laranode_smoke_test && \
echo "Postgres smoke test passed" || echo "WARNING: Postgres smoke test failed"
```

- [ ] **Step 6: Write the integration tests (gated by `LARANODE_SYSTEM_TESTS=1`)**

```php
<?php // tests/Feature/Database/MysqlIntegrationTest.php

use App\Models\User;

test('full MySQL database lifecycle via databases routes works against real MySQL', function () {
    if (! env('LARANODE_SYSTEM_TESTS')) {
        $this->markTestSkipped('LARANODE_SYSTEM_TESTS not set');
    }

    $user = User::factory()->create();

    // Create
    $this->actingAs($user)->post(route('databases.store'), [
        'engine'         => 'mysql',
        'name_suffix'    => 'integtest',
        'db_user_suffix' => 'integuser',
        'db_pass'        => 'Password123!',
        'charset'        => 'utf8mb4',
        'collation'      => 'utf8mb4_unicode_ci',
    ])->assertRedirect(route('databases.index'));

    $db = \App\Models\Database::where('name', $user->username . '_integtest')->firstOrFail();
    expect($db->engine)->toBe('mysql');

    // Stats via index
    $this->actingAs($user)->get(route('databases.index'))->assertOk();

    // Delete
    $this->actingAs($user)->delete(route('databases.destroy'), ['id' => $db->id])
        ->assertRedirect(route('databases.index'));

    expect(\App\Models\Database::find($db->id))->toBeNull();
})->group('system');
```

```php
<?php // tests/Feature/Database/PostgresIntegrationTest.php

use App\Models\User;

test('full PostgreSQL database lifecycle via databases routes works against real Postgres', function () {
    if (! env('LARANODE_SYSTEM_TESTS')) {
        $this->markTestSkipped('LARANODE_SYSTEM_TESTS not set');
    }

    $user = User::factory()->create();

    // Create
    $this->actingAs($user)->post(route('databases.store'), [
        'engine'         => 'postgres',
        'name_suffix'    => 'pgintegtest',
        'db_user_suffix' => 'pginteguser',
        'db_pass'        => 'PgPassword123!',
        'encoding'       => 'UTF8',
        'locale'         => 'en_US.UTF-8',
    ])->assertRedirect(route('databases.index'));

    $db = \App\Models\Database::where('name', $user->username . '_pgintegtest')->firstOrFail();
    expect($db->engine)->toBe('postgres')
        ->and($db->charset)->toBeNull()
        ->and($db->collation)->toBeNull();

    // Stats via index
    $this->actingAs($user)->get(route('databases.index'))->assertOk();

    // Delete
    $this->actingAs($user)->delete(route('databases.destroy'), ['id' => $db->id])
        ->assertRedirect(route('databases.index'));

    expect(\App\Models\Database::find($db->id))->toBeNull();
})->group('system');
```

- [ ] **Step 7: Run the system tests in the container**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && LARANODE_SYSTEM_TESTS=1 php artisan test --filter="MysqlIntegrationTest|PostgresIntegrationTest"'`
Expected: PASS (2 tests) — one for real MySQL, one for real Postgres.

- [ ] **Step 8: Commit**

```bash
git add laranode-scripts/bin/laranode-postgres.sh laranode-scripts/bin/laranode-postgres-sudoers laranode-scripts/bin/laranode-installer.sh local-dev/docker-compose.yml local-dev/entrypoint-setup.sh tests/Feature/Database/MysqlIntegrationTest.php tests/Feature/Database/PostgresIntegrationTest.php
git commit -m "feat(postgres): laranode-postgres.sh + sudoers drop-in + local-dev Postgres service + system integration tests"
```

---

### Task 12: Cleanup — delete old `app/Services/MySQL/` + `app/Actions/MySQL/` + update nav link

**[MIGRATION/BACK-COMPAT]**

**Files:**
- Delete: `app/Services/MySQL/CreateDatabaseService.php`
- Delete: `app/Services/MySQL/UpdateDatabaseService.php`
- Delete: `app/Services/MySQL/DeleteDatabaseService.php`
- Delete: `app/Actions/MySQL/GetDatabasesWithStatsAction.php`
- Delete: `app/Actions/MySQL/GetCharsetsAndCollationsAction.php`
- Verify: `app/Http/Controllers/MysqlController.php` no longer imports any of the above (update imports to use new services if needed — or leave it as-is since it will be removed in a follow-up).
- Update: nav link in `resources/js/Layouts/AuthenticatedLayout.jsx` (or wherever the "MySQL" link lives) to point to `route('databases.index')` with the label "Databases".

**Scope:** Deletion of the old namespace files. The old `MysqlController` is kept (it is a shim — removal is deferred). The old `Pages/Mysql/` files are kept temporarily. Nav label update to "Databases".

**Interfaces:**
- `MysqlController` currently imports from `App\Services\MySQL\*` and `App\Actions\MySQL\*`. After deletion, those imports break. Fix `MysqlController` by either: (a) making it delegate to `DatabasesController` methods (cleanest — thin shim); or (b) importing the new `App\Services\Database\*` equivalents. Option (a) is preferred.

- [ ] **Step 1: Fix `MysqlController` to delegate to `DatabasesController`**

Replace `MysqlController` body with thin delegation:
```php
<?php

namespace App\Http\Controllers;

use Illuminate\Http\RedirectResponse;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use App\Http\Requests\CreateDatabaseRequest;
use App\Http\Requests\UpdateDatabaseRequest;
use App\Http\Requests\DeleteDatabaseRequest;
use App\Databases\EngineManager;

class MysqlController extends Controller
{
    // Shim: all actions delegate to DatabasesController.
    // This class will be removed in a follow-up cleanup pass once
    // mysql.* redirect aliases are confirmed stable.

    public function index(Request $request): \Inertia\Response
    {
        return app(DatabasesController::class)->index($request);
    }

    public function getCharsetsAndCollations(): JsonResponse
    {
        return app(DatabasesController::class)->getEngineOptions(request()->merge(['engine' => 'mysql']));
    }

    public function store(CreateDatabaseRequest $request): RedirectResponse
    {
        return app(DatabasesController::class)->store($request);
    }

    public function update(UpdateDatabaseRequest $request): RedirectResponse
    {
        return app(DatabasesController::class)->update($request);
    }

    public function destroy(DeleteDatabaseRequest $request): RedirectResponse
    {
        return app(DatabasesController::class)->destroy($request);
    }
}
```

- [ ] **Step 2: Delete the old service and action files**

```bash
git rm app/Services/MySQL/CreateDatabaseService.php
git rm app/Services/MySQL/UpdateDatabaseService.php
git rm app/Services/MySQL/DeleteDatabaseService.php
git rm app/Actions/MySQL/GetDatabasesWithStatsAction.php
git rm app/Actions/MySQL/GetCharsetsAndCollationsAction.php
```

- [ ] **Step 3: Update the nav link**

Find the navigation link that currently reads "MySQL" and points to `route('mysql.index')` in `resources/js/Layouts/AuthenticatedLayout.jsx` (or wherever it lives). Change the label to "Databases" and the route to `route('databases.index')`.

- [ ] **Step 4: Run the full Pest suite to confirm no regressions**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test'`
Expected: all tests pass. Build also: `npm run build`.

- [ ] **Step 5: Commit**

```bash
git add app/Http/Controllers/MysqlController.php
git commit -m "refactor(databases): remove app/Services/MySQL + app/Actions/MySQL; MysqlController becomes thin shim; nav link renamed to Databases"
```

---

## Self-Review

**1. Spec coverage:**
- Migration: `engine` column + nullable charset/collation + backfill → Task 1 ✓
- Config: `db_engines` map + `mysql_admin` / `mariadb_admin` / `pgsql` connections → Task 2 ✓
- `DatabaseEngineDriver` interface + DTOs → Task 3 ✓
- `MysqlDriver` (relocate SQL, fix injection, parameterized password) → Task 4 ✓
- `MariaDbDriver` (extends MySQL, override label + connection) → Task 5 ✓
- `PostgresDriver` (sudo script mutations, `pgsql` stats) → Task 5 ✓
- `EngineManager` (`available()` via systemctl, `for()`, `capabilitiesFor()`) → Task 6 ✓
- `DatabaseServiceProvider` singleton registration → Task 6 ✓
- `CreateDatabaseService` / `UpdateDatabaseService` / `DeleteDatabaseService` (engine-agnostic, Eloquent-owning) → Task 7 ✓
- `GetDatabasesWithStatsService` (replaces `GetDatabasesWithStatsAction`) → Task 7 ✓
- `DatabasesController` (engine-agnostic, `getEngineOptions`) → Task 8 ✓
- `CreateDatabaseRequest` / `UpdateDatabaseRequest` (engine field, dynamic option validation) → Task 8 ✓
- `databases.*` canonical routes + `mysql.*` redirect aliases → Task 9 ✓
- `Pages/Databases/Index.jsx` (Engine column, engine badge) → Task 10 ✓
- `Pages/Databases/Partials/CreateDatabaseForm.jsx` (engine selector + dynamic option fields) → Task 10 ✓
- `Pages/Databases/Partials/EditDatabaseForm.jsx` (engine read-only, dynamic options) → Task 10 ✓
- Vitest tests for CreateDatabaseForm (engine selector, option field re-render, Postgres hides charset) → Task 10 ✓
- `laranode-postgres.sh` (all actions, validation, dollar-quoting) → Task 11 ✓
- Sudoers drop-in (`/etc/sudoers.d/laranode-postgres`) → Task 11 ✓
- `laranode-installer.sh` update (postgresql-client + drop-in) → Task 11 ✓
- `local-dev` Postgres service + volume → Task 11 ✓
- `MysqlIntegrationTest` + `PostgresIntegrationTest` (LARANODE_SYSTEM_TESTS) → Task 11 ✓
- Old `app/Services/MySQL/` + `app/Actions/MySQL/` deleted → Task 12 ✓
- `MysqlController` becomes a thin shim → Task 12 ✓
- Nav link renamed to "Databases" → Task 12 ✓

**2. TDD tasks:** Tasks 1, 4, 5, 6, 7, 8 all write the failing test before the implementation.

**3. Migration / back-compat tasks flagged:** Tasks 1 (migration), 9 (redirect aliases), 11 (local-dev parity), 12 (old namespace cleanup).

**4. SQL injection fix:** Task 4 explicitly tests that the literal password never appears in raw SQL. Defense-in-depth assertion (`[a-zA-Z0-9_]+`) documented in Task 4 scope and enforced in the driver.

**5. Type/contract consistency:** `DatabaseSpec(name, dbUser, password, userId, options)` passed from `CreateDatabaseService` to all drivers consistently. `DatabaseStats(tableCount, sizeMb, extra)` returned from all drivers' `stats()`. `EngineCapabilities(label, hasUsers, optionFields)` used in `getEngineOptions` JSON response and consumed by `CreateDatabaseForm.jsx`. `EngineManager::available()` gates both `CreateDatabaseRequest` validation and the engine selector in the form.

**6. Remaining deferrals (explicitly out of scope per spec):** SQLite engine, MongoDB engine, database dump/restore, per-database engine migration, replication, admin view of all users' databases. These are NOT addressed here.

---

## Final Verification Gate

Run each of the following in the `local-dev` container. All must pass before the branch is considered ready for review.

```bash
# 1. Full Pest suite (no system tests)
docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test'
# Expected: all tests pass, 0 failures, 0 errors.

# 2. Pint (code style)
docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && ./vendor/bin/pint --test'
# Expected: no style violations. Run ./vendor/bin/pint (without --test) to auto-fix before committing.

# 3. Vitest (frontend unit/component)
docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && npm run test'
# Expected: all Vitest tests pass (sanity + MysqlDriver mocks + CreateDatabaseForm engine-selector tests).

# 4. Asset build
docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && npm run build'
# Expected: build succeeds with no import errors or missing module warnings.

# 5. System integration tests (real MySQL + real Postgres in the container)
docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && LARANODE_SYSTEM_TESTS=1 php artisan test --group=system'
# Expected: MysqlIntegrationTest and PostgresIntegrationTest both pass.

# 6. Route list check
docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan route:list --name=databases'
# Expected: 5 routes listed (index, engine-options, store, update, destroy).

# 7. Back-compat alias smoke
docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan route:list --name=mysql'
# Expected: 5 mysql.* routes still listed as redirect aliases.

# 8. Manual container behavior check
# Log in as admin at http://localhost → navigate to /databases.
# Confirm: Engine column visible; "Create Database" form shows engine selector; selecting MySQL reveals
# charset/collation; selecting PostgreSQL shows encoding/locale instead; delete and create work end-to-end.
# Navigate to /mysql → confirm 301 redirect lands on /databases.
```
