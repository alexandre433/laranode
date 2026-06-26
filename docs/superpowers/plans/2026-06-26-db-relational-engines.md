# DB Driver Seam + MySQL / MariaDB / PostgreSQL — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce a `DatabaseEngineDriver` interface and three concrete drivers (MySQL, MariaDB, PostgreSQL). Existing MySQL behavior is preserved without regression. Fix the SQL injection surface. Add PostgreSQL via sudo script + peer auth. Dynamic, engine-agnostic create/edit UI driven by `EngineCapabilities`.

**Architecture:** `DatabasesController` (engine-agnostic) → `CreateDatabaseRequest` / `UpdateDatabaseRequest` / `DeleteDatabaseRequest` (engine-aware, allowlist-validated) → `CreateDatabaseService` / `UpdateDatabaseService` / `DeleteDatabaseService` → `EngineManager` → `DatabaseEngineDriver`. Drivers never touch Eloquent. Services own all model mutations.

**Tech Stack:** Laravel 12, Pest 3, Vitest + RTL (already in place), MySQL / PostgreSQL (local-dev container), `Process` facade, `DB::connection('mysql_admin')` for MySQL driver SQL.

## Global Constraints

- `DatabaseEngineDriver` interface is the only public contract between services and engines.
- `EngineManager::available()` drives both the create form and `CreateDatabaseRequest` validation. If it returns empty, the create form shows an empty state — no engine selector.
- **Charset + collation allowlist validation is mandatory** in both `CreateDatabaseRequest` and `UpdateDatabaseRequest`: `regex:/^[a-zA-Z0-9_]+$/`. They are interpolated into SQL (MySQL does not support bind params here); raw user strings must never reach the SQL string.
- **Password parameterization is mandatory** in `MysqlDriver`: `DB::connection('mysql_admin')->statement('... IDENTIFIED BY ?', [$password])`. Never interpolated.
- **Injection test must use a real captured-SQL assertion** (not `pretend()+listen()`, which logs nothing and is vacuous). See Task 4.
- **PostgreSQL password never in argv.** Passed via stdin pipe or 0600 temp file to `psql`, never as a positional argument. Dollar-tag quoting inside the script uses a unique per-invocation random tag — never bare `$$`.
- **`pgsql_admin` is a SEPARATE named connection** reading `PGSQL_*` env vars. The existing `pgsql` skeleton connection (which reads `DB_*`) is not modified or reused.
- **`mysql_admin` uses dedicated `MYSQL_ADMIN_*` env vars**, falling back to `DB_USERNAME`/`DB_PASSWORD` only when not set. Never reuses or mutates the panel's `mysql` connection.
- **`mysql.*` route aliases are same-handler aliases pointing directly at `DatabasesController`** — NOT 301 redirects. POST/PATCH/DELETE redirected with 301 silently become GET, breaking form submissions.
- **`REVOKE CONNECT FROM PUBLIC`** is issued immediately after `create-db` in the Postgres script. `GRANT CONNECT` is issued explicitly to the created user.
- **`PostgresDriver::create()` rolls back** with `drop-db` if `create-user` fails, to avoid orphaned databases.
- **Both admin and non-admin listing paths are tested.**
- **Every system-touching path has at least one `LARANODE_SYSTEM_TESTS=1` integration test** — not only `Process::fake()`.
- **Tests run with `QUEUE_CONNECTION=sync`** (already set in `phpunit.xml`).
- **Branch:** `feature/db-relational-engines` (off `development`).
- **Run the suite in the `local-dev` container:** `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test'`. Use PowerShell (not Git Bash) for `make` / `docker compose`.

---

> **Execution order:** Tasks 1–12 in order. Tasks 1–3 are foundational (data model, config, contracts). Tasks 4–6 build the driver layer. Tasks 7–8 build services and controller. Tasks 9–10 add routes and frontend. Task 11 adds Postgres system infrastructure. Task 12 cleans up the old namespace.

---

### Task 1: Database migration — add `engine` column, backfill, nullable charset/collation

**Files:**
- Create: `database/migrations/XXXX_add_engine_to_databases_table.php`
- Create: `tests/Feature/Database/DatabaseMigrationTest.php`
- Modify: `app/Models/Database.php` — add `'engine'` to `$fillable`

**Acceptance criteria:**
- `Schema::hasColumn('databases', 'engine')` is true after migration runs.
- A row created without charset/collation has null values and engine `'postgres'`.
- After inserting a row with null engine directly via `DB::table()->insert()`, running the backfill query sets `engine='mysql'` on it (real backfill test, not just the column default).
- `./vendor/bin/pest --filter=DatabaseMigrationTest` passes (3 tests).

The backfill query must handle both `NULL` and `''` (empty string) engine values:
```php
DB::table('databases')->where(fn ($q) => $q->whereNull('engine')->orWhere('engine', ''))->update(['engine' => 'mysql']);
```

- [ ] Write failing test → run → confirm FAIL → write migration + model change → run `php artisan migrate` → confirm PASS → commit.

---

### Task 2: Config additions — `db_engines` map + `mysql_admin` / `mariadb_admin` / `pgsql_admin` connections

**Files:**
- Modify: `config/laranode.php` — add `db_engines` key
- Modify: `config/database.php` — add `mysql_admin`, `mariadb_admin`, `pgsql_admin` connections
- Modify: `.env.example` — add `MYSQL_ADMIN_USERNAME`, `MYSQL_ADMIN_PASSWORD`, `PGSQL_HOST`, `PGSQL_PORT`, `PGSQL_DB`, `PGSQL_USERNAME`, `PGSQL_PASSWORD`
- Create: `tests/Feature/Database/ConfigTest.php`

**`mysql_admin` / `mariadb_admin`:** same structure as the `mysql` connection, but `username` reads `MYSQL_ADMIN_USERNAME` with fallback `DB_USERNAME`, and `password` reads `MYSQL_ADMIN_PASSWORD` with fallback `DB_PASSWORD`.

**`pgsql_admin`:** separate connection reading `PGSQL_HOST`, `PGSQL_PORT`, `PGSQL_DB`, `PGSQL_USERNAME`, `PGSQL_PASSWORD`. Does NOT read `DB_HOST` / `DB_PORT` / etc. The existing `pgsql` skeleton connection is untouched.

**`db_engines` map:**
```php
'db_engines' => [
    'mysql'    => ['service' => 'mysql',      'port' => 3306],
    'mariadb'  => ['service' => 'mariadb',    'port' => 3306],
    'postgres' => ['service' => 'postgresql', 'port' => 5432],
],
```

**Acceptance criteria:**
- `config('laranode.db_engines')` has keys `mysql`, `mariadb`, `postgres`.
- `config('database.connections')` has keys `mysql_admin`, `mariadb_admin`, `pgsql_admin`.
- `pgsql_admin` does not share env var keys with the existing `pgsql` connection.
- `./vendor/bin/pest --filter=ConfigTest` passes.

- [ ] Write config changes + test → run → confirm PASS → commit.

---

### Task 3: Contracts + DTOs

**Files:**
- Create: `app/Contracts/DatabaseEngineDriver.php`
- Create: `app/Databases/DatabaseSpec.php`
- Create: `app/Databases/DatabaseStats.php`
- Create: `app/Databases/EngineCapabilities.php`

**`DatabaseSpec`:** `readonly class { string $name, string $dbUser, string $password, int $userId, array $options = [] }`

**`DatabaseStats`:** `readonly class { int $tableCount, float $sizeMb, array $extra = [] }`

**`EngineCapabilities`:** `readonly class { string $label, bool $hasUsers, array $optionFields }`

No tests needed beyond what Tasks 4–6 cover. Write and commit.

**Acceptance criteria:** Classes exist; `php artisan config:clear && php artisan route:list` completes without autoload errors.

- [ ] Write all four files → commit.

---

### Task 4: `MysqlDriver` — relocate + fix injection surface

**[TDD]**

**Files:**
- Create: `app/Databases/Drivers/MysqlDriver.php`
- Create: `tests/Feature/Database/MysqlDriverTest.php`

**SQL injection fixes (both are required):**

1. **Charset + collation:** validated in `CreateDatabaseRequest` / `UpdateDatabaseRequest` via `regex:/^[a-zA-Z0-9_]+$/` before reaching the driver. The driver also asserts the same pattern as defense-in-depth (`preg_match('/^[a-zA-Z0-9_]+$/', $value)` → throw `\InvalidArgumentException` if it fails).

2. **Password:** `DB::connection('mysql_admin')->statement("CREATE USER IF NOT EXISTS \`{$dbUser}\`@'localhost' IDENTIFIED BY ?", [$password])` and `DB::connection('mysql_admin')->statement("ALTER USER \`{$dbUser}\`@'localhost' IDENTIFIED BY ?", [$newPassword])`. Never string-interpolated.

**Injection test — must use real captured SQL, NOT `pretend()+listen()`:**

`pretend()` + `listen()` does not execute SQL and records nothing — any assertion on the recorded array is vacuous. Instead:

- Bind the `mysql_admin` connection to a mock that records arguments passed to `statement()`:
```php
$recorded = [];
$conn = Mockery::mock(\Illuminate\Database\Connection::class);
$conn->shouldReceive('statement')->andReturnUsing(function ($sql, $bindings = []) use (&$recorded) {
    $recorded[] = ['sql' => $sql, 'bindings' => $bindings];
    return true;
});
$conn->shouldReceive('select')->andReturn([]);
app()->instance('db.connection.mysql_admin', $conn);
```
Then assert that no element of `$recorded` has the literal password in `$sql` (it should be in `$bindings`), and that `$sql` contains `IDENTIFIED BY ?`.

**Other driver behavior:**
- Uses `DB::connection('mysql_admin')` (returns `'mysql_admin'` from `connectionName()`).
- `create()`: `CREATE DATABASE \`{$name}\` CHARACTER SET {$charset} COLLATE {$collation}` → `CREATE USER ... IDENTIFIED BY ?` → `GRANT ALL PRIVILEGES` → `FLUSH PRIVILEGES`. On user-creation failure, rolls back with `DROP DATABASE IF EXISTS`.
- `updatePassword()`: `ALTER USER ... IDENTIFIED BY ?`.
- `updateOptions()`: `ALTER DATABASE \`{$name}\` CHARACTER SET {$charset} COLLATE {$collation}`.
- `delete()`: `DROP DATABASE IF EXISTS` → `DROP USER IF EXISTS` → `FLUSH PRIVILEGES`.
- `stats()`: `information_schema.tables` COUNT and SUM queries via `mysql_admin` connection.
- `capabilities()`: `EngineCapabilities(label:'MySQL', hasUsers:true, optionFields:[charset, collation])`.

**Acceptance criteria:**
- `./vendor/bin/pest --filter=MysqlDriverTest` passes (4 tests: capabilities, create records SQL with password in bindings not in sql string, delete records correct statements, updatePassword records parameterized form).
- The literal password string does not appear in any captured `$sql` value.

- [ ] Write failing tests → run → confirm FAIL → write driver → run → confirm PASS → commit.

---

### Task 5: `MariaDbDriver` + `PostgresDriver`

**[TDD]**

**Files:**
- Create: `app/Databases/Drivers/MariaDbDriver.php`
- Create: `app/Databases/Drivers/PostgresDriver.php`
- Create: `tests/Feature/Database/MariaDbDriverTest.php`
- Create: `tests/Feature/Database/PostgresDriverTest.php`

**`MariaDbDriver`:** extends `MysqlDriver`; overrides `connectionName()` → `'mariadb_admin'`; overrides `capabilities()` → label `'MariaDB'`.

**`PostgresDriver`:**
- `create()` sequence: call `create-db` action → on failure throw `CreateDatabaseException`; call `create-user` (password via stdin, never argv) → on failure call `drop-db` for rollback, then throw; call `grant` → on failure throw. The password must NOT appear in the `Process::run()` command array.
- `delete()`: `drop-db` then `drop-user`.
- `updatePassword()`: `update-user-password` action (password via stdin).
- `updateOptions()`: no-op for Postgres.
- `stats()`: `DB::connection('pgsql_admin')->selectOne('SELECT pg_database_size(?) AS size_bytes', [$name])`.
- `capabilities()`: `EngineCapabilities(label:'PostgreSQL', hasUsers:true, optionFields:[encoding, locale])`.
- Defense-in-depth: assert `[a-zA-Z0-9_]+` on `$name` and `$dbUser` before invoking sudo.

**`PostgresDriverTest` acceptance criteria (in addition to standard driver tests):**
- `Process::assertRan()` confirms password is not in the command array for `create-user`.
- `Process::assertRan()` confirms `create-db`, `create-user`, `grant` are called in order for `create()`.
- Non-zero exit on `create-db` throws `CreateDatabaseException` without calling `create-user`.
- Non-zero exit on `create-user` triggers `drop-db` rollback call.

**Acceptance criteria:**
- `./vendor/bin/pest --filter="MariaDbDriverTest|PostgresDriverTest"` passes (6 tests total).

- [ ] Write failing tests → run → confirm FAIL → write both drivers → run → confirm PASS → commit.

---

### Task 6: `EngineManager` + `DatabaseServiceProvider`

**[TDD]**

**Files:**
- Create: `app/Databases/EngineManager.php`
- Create: `app/Providers/DatabaseServiceProvider.php`
- Modify: `bootstrap/providers.php` — register `DatabaseServiceProvider`
- Create: `tests/Feature/Database/EngineManagerTest.php`

**`EngineManager::available()` behavior:**
- Iterates `config('laranode.db_engines')`, runs `Process::run(['systemctl', 'is-active', $service])`, includes engine key only if output trims to `'active'`.
- Returns an empty array when no engine is active — no exception.

**`EngineManager::for($engine):`** throws `\InvalidArgumentException` for unknown engine.

**Acceptance criteria:**
- `available()` returns only active engines per faked `Process`.
- `available()` returns `[]` when all services are inactive — no exception thrown.
- `for('mysql')` returns `MysqlDriver`; `for('oracle')` throws.
- MariaDB detection: `systemctl is-active mariadb` active → `available()` contains `'mariadb'` but not `'mysql'` (they cannot coexist).
- `./vendor/bin/pest --filter=EngineManagerTest` passes (5 tests including the empty-available case).

- [ ] Write failing tests → run → confirm FAIL → write `EngineManager` + provider → register in `bootstrap/providers.php` → run → confirm PASS → commit.

---

### Task 7: Services — Create / Update / Delete / GetStats

**[TDD]**

**Files:**
- Create: `app/Services/Database/CreateDatabaseService.php`
- Create: `app/Services/Database/UpdateDatabaseService.php`
- Create: `app/Services/Database/DeleteDatabaseService.php`
- Create: `app/Services/Database/GetDatabasesWithStatsService.php`
- Create: `tests/Feature/Database/CreateDatabaseServiceTest.php`

**Pattern:** each service file declares a sibling `*Exception extends Exception` class at the top (same file, per project convention). Services own all Eloquent mutations; drivers own no Eloquent calls.

**`GetDatabasesWithStatsService`:** uses `Database::scopeMine()` — scoped by auth user, respects admin vs. non-admin. A per-request static cache prevents duplicate `stats()` calls within a single request.

**Acceptance criteria:**
- `CreateDatabaseService::handle($spec, 'mysql')` calls `driver->create($spec)` then `Database::create(...)` with `engine='mysql'`.
- `DeleteDatabaseService::handle($database)` calls `driver->delete($database)` then `$database->delete()` — row is gone from DB.
- Non-admin user only sees their own rows via `GetDatabasesWithStatsService`.
- Admin sees all rows.
- `./vendor/bin/pest --filter=CreateDatabaseServiceTest` passes (4 tests: create, update, delete, scopeMine admin+non-admin).

- [ ] Write failing tests → run → confirm FAIL → write all four services → run → confirm PASS → commit.

---

### Task 8: `DatabasesController` + updated FormRequests

**[TDD]**

**Files:**
- Create: `app/Http/Controllers/DatabasesController.php`
- Modify: `app/Http/Requests/CreateDatabaseRequest.php` — add `engine` field + allowlist charset/collation
- Modify: `app/Http/Requests/UpdateDatabaseRequest.php` — allowlist charset/collation
- Create: `tests/Feature/Database/DatabasesControllerTest.php`

**`CreateDatabaseRequest` changes (all are required):**
- Add `'engine' => ['required', 'string', Rule::in(app(EngineManager::class)->available())]`.
- Change `'charset'` to `['required_if:engine,mysql', 'required_if:engine,mariadb', 'nullable', 'regex:/^[a-zA-Z0-9_]+$/']`.
- Change `'collation'` to `['required_if:engine,mysql', 'required_if:engine,mariadb', 'nullable', 'regex:/^[a-zA-Z0-9_]+$/']`.
- Keep existing `prepareForValidation()` prefix logic and `withValidator()` database limit guard unchanged.

**`UpdateDatabaseRequest` changes:**
- Add same allowlist regex for `charset` and `collation`.

**`DatabasesController::getEngineOptions`:** returns `{ engines: [], capabilities: null }` when `EngineManager::available()` is empty. Frontend handles this as an empty state.

**Acceptance criteria:**
- `GET /databases` (authenticated, non-admin) → 200, Inertia component `Databases/Index`, only own rows.
- `GET /databases` (authenticated, admin) → 200, all rows.
- `GET /databases` (unauthenticated) → 302 to login.
- `POST /databases` with `engine='oracle'` (not in `available()`) → 422.
- `POST /databases` with `charset='utf8; DROP DATABASE foo'` → 422 (fails allowlist regex).
- `mysql.index` route resolves to the same controller action as `databases.index` (no redirect — tested by confirming the response is 200, not 301/302).
- `./vendor/bin/pest --filter=DatabasesControllerTest` passes (6 tests).

- [ ] Write failing tests → run → confirm FAIL → write controller + modify FormRequests → run → confirm PASS → commit.

---

### Task 9: Routes — `databases.*` canonical + `mysql.*` same-handler aliases

**Files:**
- Modify: `routes/web.php`
- Create: `tests/Feature/Database/RouteTest.php`

**Route structure:**

Replace the current MySQL route block with:
```php
// Databases management [Admin | User] — canonical routes
Route::middleware(['auth'])->group(function () {
    Route::get('/databases',                [DatabasesController::class, 'index'])->name('databases.index');
    Route::get('/databases/engine-options', [DatabasesController::class, 'getEngineOptions'])->name('databases.engine-options');
    Route::post('/databases',               [DatabasesController::class, 'store'])->name('databases.store');
    Route::patch('/databases',              [DatabasesController::class, 'update'])->name('databases.update');
    Route::delete('/databases',             [DatabasesController::class, 'destroy'])->name('databases.destroy');
});

// mysql.* back-compat aliases — same handler, NOT redirects (301 on POST/PATCH/DELETE becomes GET)
Route::middleware(['auth'])->group(function () {
    Route::get('/mysql',                    [DatabasesController::class, 'index'])->name('mysql.index');
    Route::get('/mysql/charsets-collations',[DatabasesController::class, 'getEngineOptions'])->name('mysql.charsets-collations');
    Route::post('/mysql',                   [DatabasesController::class, 'store'])->name('mysql.store');
    Route::patch('/mysql',                  [DatabasesController::class, 'update'])->name('mysql.update');
    Route::delete('/mysql',                 [DatabasesController::class, 'destroy'])->name('mysql.destroy');
});
```

**Acceptance criteria:**
- `php artisan route:list --name=databases` shows 5 routes.
- `php artisan route:list --name=mysql` shows 5 routes.
- `mysql.store` posts to `/mysql` and resolves to `DatabasesController@store` (same handler, no redirect).
- Authenticated user posting to `/mysql` gets a redirect to `databases.index` (the service redirect), NOT a 301 to `/databases`.
- `./vendor/bin/pest --filter=RouteTest` passes (3 tests).

- [ ] Write route changes + test → run → confirm PASS → commit.

---

### Task 10: Frontend — `Pages/Databases/` + Vitest

**Files:**
- Create: `resources/js/Pages/Databases/Index.jsx`
- Create: `resources/js/Pages/Databases/Partials/CreateDatabaseForm.jsx`
- Create: `resources/js/Pages/Databases/Partials/EditDatabaseForm.jsx`
- Create: `resources/js/Pages/Databases/Partials/CreateDatabaseForm.test.jsx`

**`Index.jsx`:** Engine column + engine badge per row. Charset/collation show `—` for Postgres rows. Empty state when no databases. `DatabasesController` renders `Databases/Index`.

**`CreateDatabaseForm.jsx`:** On mount, fetches `engine-options` (no engine param) to get available engine list. If `engines` is empty, shows empty state ("No database engine is currently active"). On engine selection, re-fetches `engine-options?engine=X` to get `optionFields`. Renders dynamically from `optionFields` — no hardcoded per-engine conditionals.

**`EditDatabaseForm.jsx`:** Engine displayed as read-only. Dynamic options per engine.

**Acceptance criteria (Vitest):**
- Engine selector populates from `engine-options` response.
- Selecting MySQL triggers re-fetch with `?engine=mysql` and renders charset/collation fields.
- Selecting Postgres does not render charset/collation fields.
- Empty `engines` array shows empty state message.
- `npm run test` passes (existing sanity test + 4 new `CreateDatabaseForm` tests).
- `npm run build` succeeds with no import errors.

- [ ] Write Vitest tests → run → confirm FAIL → write components → run → confirm PASS → build → commit.

---

### Task 11: Postgres system infrastructure

**Files:**
- Create: `laranode-scripts/bin/laranode-postgres.sh`
- Create: `laranode-scripts/bin/laranode-postgres-sudoers`
- Modify: `laranode-scripts/bin/laranode-installer.sh` — install `postgresql-client` + apply sudoers drop-in
- Modify: `local-dev/docker-compose.yml` — add `laranode-postgres` named volume
- Modify: `local-dev/entrypoint-setup.sh` — install + start Postgres + smoke test
- Create: `tests/Feature/Database/MysqlIntegrationTest.php` (`LARANODE_SYSTEM_TESTS=1`)
- Create: `tests/Feature/Database/PostgresIntegrationTest.php` (`LARANODE_SYSTEM_TESTS=1`)
- Create: `tests/Feature/Database/BackfillTest.php`

**`laranode-postgres.sh` requirements:**
- Actions: `create-db <name> <encoding> <locale>`, `create-user <user>` (password via stdin), `grant <user> <db>`, `revoke <user> <db>`, `drop-db <name>`, `drop-user <user>`, `update-user-password <user>` (password via stdin).
- Name/user arguments validated against `^[a-zA-Z0-9_]+$` — exit 1 if not matched.
- `create-db` issues `REVOKE CONNECT ON DATABASE "$name" FROM PUBLIC` immediately after `CREATE DATABASE`.
- Password handling: piped via stdin to `psql`, never as a positional arg. Inside SQL: `ALTER ROLE "$user" PASSWORD '$tag$...$tag$'` where `$tag` is a per-invocation random string (e.g. `$(head -c8 /dev/urandom | base64 | tr -dc a-z | head -c8)`) to avoid dollar-quoting breakout.
- `trap` cleanup for any temp files created.
- Make executable: `chmod +x`.

**Sudoers drop-in:** `laranode-postgres-sudoers` template with `www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-postgres.sh`. Installer substitutes the actual path.

**local-dev:** Add named volume `laranode-postgres` in `docker-compose.yml`, mounted at `/var/lib/postgresql` in the `laranode` service. In `entrypoint-setup.sh`: install `postgresql-16 postgresql-client-16`, start + enable the service, apply the sudoers drop-in, run a smoke test (`create-db` + `drop-db` on a throwaway name).

**Backfill test (`BackfillTest.php`):**
```
Insert a row with NULL engine via DB::table()->insert(). Run the backfill query. Assert the row now has engine='mysql'.
```

**Integration tests (gated by `LARANODE_SYSTEM_TESTS=1`):**

`MysqlIntegrationTest`: full create → index (shows row + stats, non-admin sees own row, admin sees all) → delete lifecycle against real MySQL. Assert engine column is `'mysql'`.

`PostgresIntegrationTest`: full create → index → delete lifecycle against real Postgres. Assert `charset` and `collation` are null. Assert `REVOKE CONNECT FROM PUBLIC` was applied (attempting to connect as a different role fails). Assert the password is not visible in the process list during create (check via `/proc` or `ps` from within the test).

**Acceptance criteria:**
- `laranode-postgres.sh create-db test1 UTF8 en_US.UTF-8 && laranode-postgres.sh drop-db test1` smoke passes in container.
- `LARANODE_SYSTEM_TESTS=1 ./vendor/bin/pest --filter="MysqlIntegrationTest|PostgresIntegrationTest"` passes (2 tests, `--group=system`).
- `./vendor/bin/pest --filter=BackfillTest` passes.

- [ ] Write script + sudoers + local-dev changes + integration tests → run in container → confirm PASS → commit.

---

### Task 12: Cleanup — remove old namespaces + update nav link + `MysqlController` shim

**Files:**
- Delete: `app/Services/MySQL/CreateDatabaseService.php`
- Delete: `app/Services/MySQL/UpdateDatabaseService.php`
- Delete: `app/Services/MySQL/DeleteDatabaseService.php`
- Delete: `app/Actions/MySQL/GetDatabasesWithStatsAction.php`
- Delete: `app/Actions/MySQL/GetCharsetsAndCollationsAction.php`
- Modify: `app/Http/Controllers/MysqlController.php` — replace body with thin delegation to `DatabasesController`
- Modify: nav layout — change "MySQL" label to "Databases", route to `databases.index`

**`MysqlController` shim:** All five methods (`index`, `getCharsetsAndCollations`, `store`, `update`, `destroy`) delegate to the corresponding `DatabasesController` methods. No imports from the deleted namespaces.

**Acceptance criteria:**
- `php artisan test` passes (full suite, no regressions).
- `npm run build` succeeds.
- Nav link reads "Databases" and routes to `/databases`.
- `MysqlController` compiles with no imports from `App\Services\MySQL\*` or `App\Actions\MySQL\*`.

- [ ] Fix `MysqlController` shim → delete old files via `git rm` → update nav → full test run → commit.

---

## Final Verification Gate

Run each of the following in the `local-dev` container. All must pass before the branch is ready for review.

```bash
# 1. Full Pest suite (no system tests)
docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test'
# Expected: all tests pass, 0 failures.

# 2. Pint (code style)
docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && ./vendor/bin/pint --test'
# Auto-fix: ./vendor/bin/pint (without --test)

# 3. Vitest (frontend unit/component)
docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && npm run test'
# Expected: all Vitest tests pass.

# 4. Asset build
docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && npm run build'
# Expected: no import errors.

# 5. System integration tests (real MySQL + real Postgres)
docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && LARANODE_SYSTEM_TESTS=1 php artisan test --group=system'
# Expected: MysqlIntegrationTest and PostgresIntegrationTest pass.

# 6. Route list
docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan route:list --name=databases'
# Expected: 5 databases.* routes listed.

docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan route:list --name=mysql'
# Expected: 5 mysql.* routes listed (same-handler aliases, no redirect action).

# 7. Postgres smoke (in container)
docker exec laranode-lab bash -lc 'sudo /home/laranode_ln/panel/laranode-scripts/bin/laranode-postgres.sh create-db smoke_test UTF8 en_US.UTF-8 && sudo /home/laranode_ln/panel/laranode-scripts/bin/laranode-postgres.sh drop-db smoke_test'
# Expected: exits 0, no error output.

# 8. Manual behavior check
# Log in at http://localhost → navigate to /databases.
# Confirm: Engine column visible; Create form shows engine selector; MySQL shows charset/collation;
# Postgres shows encoding/locale; empty engine list shows empty state; delete and create work end-to-end.
# Navigate to /mysql → confirm same page renders (no redirect).
```
