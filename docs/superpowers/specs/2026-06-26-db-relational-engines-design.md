# Sub-project #2 — DB driver seam + MySQL / MariaDB / PostgreSQL (`db-relational-engines`)

- **Date:** 2026-06-26
- **Status:** Approved design (ready for writing-plans)
- **Roadmap:** Phase 1, sub-project #2 of `docs/superpowers/specs/2026-06-25-laranode-feature-roadmap.md`
- **Branch:** `feature/db-relational-engines` (off `development`)

## Goal

Introduce a driver abstraction seam so Laranode can manage databases on whichever relational engine is installed on the host (MySQL, MariaDB, or PostgreSQL), while keeping the user-facing experience identical to what ships today. Existing MySQL behavior is preserved without any user-visible regression. PostgreSQL is added as a first-class engine with idiomatic peer-auth execution. The seam makes future engines trivial to add.

**Why now:** the host may run MariaDB instead of MySQL, or may add PostgreSQL alongside. Without a seam, every engine needs its own parallel stack. One interface, three drivers, one controller.

## Success criteria

- Creating a database selects engine from the available set on the host; the form only offers what is installed and active. If no engine is available, the create form shows an appropriate empty state.
- MySQL/MariaDB databases continue to work exactly as before with zero data loss; existing rows backfilled to `engine='mysql'` by migration. A real backfill test confirms pre-existing null-engine rows are also handled.
- PostgreSQL databases are created/dropped via `sudo laranode-postgres.sh` (peer auth, no stored superuser password). Stats are fetched via `pg_database_size`. `REVOKE CONNECT FROM PUBLIC` is issued at creation; the created user receives an explicit `GRANT CONNECT`.
- `EngineManager::available()` reflects the real host state (systemctl check); the create form is driven by `EngineCapabilities` returned from the chosen driver — no hardcoded per-engine UI.
- SQL injection surface in the existing MySQL services is fixed: charset and collation are allowlist-validated in FormRequests (not just arbitrary strings); passwords are never interpolated into raw SQL strings (parameterized or stdin).
- Tests exist for the first time for the DB path: unit tests (mocked connection/Process) + container integration tests against real MySQL and real PostgreSQL (under `LARANODE_SYSTEM_TESTS=1`). The injection test uses a real captured-SQL assertion — not `pretend()+listen()`.
- Routes `/databases/*` work; `mysql.*` route aliases point the old URIs at `DatabasesController` via same-handler route aliases, not HTTP redirects.
- The existing per-user filter behaviour on the databases listing is preserved. Non-admins see only their own rows. Admin path is also tested.

## Architecture

The layering is: `DatabasesController` (thin, engine-agnostic) → `CreateDatabaseRequest` / `UpdateDatabaseRequest` / `DeleteDatabaseRequest` (validation, engine-aware) → `CreateDatabaseService` / `UpdateDatabaseService` / `DeleteDatabaseService` (orchestration, now call the driver) → `EngineManager` → `DatabaseEngineDriver` implementation.

The existing `app/Services/MySQL/{Create,Update,Delete}DatabaseService.php` and `app/Actions/MySQL/{GetDatabasesWithStats,GetCharsetsAndCollations}Action.php` are relocated and refactored into the new driver layer; the old namespaces are removed.

### Components

**1. `DatabaseEngineDriver` interface — `app/Contracts/DatabaseEngineDriver.php`**

```php
interface DatabaseEngineDriver {
    public function create(DatabaseSpec $spec): void;
    public function updatePassword(Database $database, string $newPassword): void;
    public function updateOptions(Database $database, array $options): void;
    public function delete(Database $database): void;
    public function stats(Database $database): DatabaseStats;
    public function capabilities(): EngineCapabilities;
}
```

Drivers never touch Eloquent directly. `DatabaseSpec` and `DatabaseStats` are readonly DTOs. The interface hides the execution mechanism (DB connection vs. sudo script).

**2. DTOs — `app/Databases/`**

- `DatabaseSpec` — `readonly class { string $name, string $dbUser, string $password, int $userId, array $options = [] }`. Passed to `create()`. Options carry engine-specific fields (charset+collation for MySQL/MariaDB; encoding+locale for Postgres).
- `DatabaseStats` — `readonly class { int $tableCount, float $sizeMb, array $extra = [] }`. Returned by `stats()`. The `extra` bag carries engine-specific data (Postgres has no table count via the same path — return 0).
- `EngineCapabilities` — `readonly class { string $label, bool $hasUsers, array $optionFields }`. `optionFields` is an array of `['key' => 'charset', 'label' => 'Charset', 'type' => 'select', 'source' => 'charset-options']` descriptors that drive the dynamic create form. No hardcoded per-engine UI.

**3. Drivers — `app/Databases/Drivers/`**

`MysqlDriver implements DatabaseEngineDriver`
- Runs all SQL via the named `mysql_admin` Laravel DB connection (a separate entry in `config/database.php` using dedicated admin credentials — `MYSQL_ADMIN_USERNAME` / `MYSQL_ADMIN_PASSWORD` env vars, falling back to `DB_USERNAME` / `DB_PASSWORD` only if the `MYSQL_ADMIN_*` vars are not set). Completely separate from the panel's own connection; never mutated.
- Password is passed via a parameterized `DB::connection('mysql_admin')->statement('ALTER USER ...IDENTIFIED BY ?', [$password])` — never interpolated into the raw SQL string.
- charset and collation in `CREATE DATABASE` / `ALTER DATABASE` are interpolated (MySQL does not support bind params for identifiers), but only after allowlist validation in `CreateDatabaseRequest` / `UpdateDatabaseRequest` (see Security section).
- `capabilities()` returns `EngineCapabilities(label:'MySQL', hasUsers:true, optionFields:[charset, collation])`.
- `stats()` runs the existing `information_schema` queries from `GetDatabasesWithStatsAction` via the `mysql_admin` connection.
- On partial create failure, rolls back with `DROP DATABASE IF EXISTS` + `DROP USER IF EXISTS`.

`MariaDbDriver extends MysqlDriver`
- Zero SQL differences; overrides only `capabilities()` label (`'MariaDB'`) and the DB connection name (`mariadb_admin`). MySQL and MariaDB never coexist on the same host (both bind :3306) — the `EngineManager` returns one or the other, never both.

`PostgresDriver implements DatabaseEngineDriver`
- All mutations shell out to `sudo laranode-postgres.sh <action> <args>` via `Process::run(['sudo', config('laranode.laranode_bin_path').'/laranode-postgres.sh', $action, ...])`. No stored superuser password; the script runs as the `postgres` OS user via peer auth.
- Passwords for the created Postgres role are passed via STDIN to `psql` (never as a positional argv visible in `ps`/`/proc`). Inside the script, the password is set with a `\password` meta-command reading from stdin, or via `ALTER ROLE ... PASSWORD` with a unique per-invocation dollar tag (e.g. `$pwd_<random>$`) — never using the bare `$$..$$` form which a user-supplied dollar sign could break out of.
- `create()` sequence: `create-db` → `REVOKE CONNECT ON DATABASE $name FROM PUBLIC` → `create-user` (password via stdin) → `grant`. On `create-db` failure, no further steps. On `create-user` failure, rolls back with `drop-db`. This ensures no partial orphan state.
- `stats()` connects via the application's `pgsql_admin` Laravel connection (a SEPARATE named connection reading `PGSQL_*` env vars — never the existing `pgsql` skeleton connection which reads `DB_*` vars) to run `SELECT pg_database_size(?) AS size_bytes` and query `pg_stat_user_tables` for table count.
- `capabilities()` returns `EngineCapabilities(label:'PostgreSQL', hasUsers:true, optionFields:[encoding, locale])`.

**4. `EngineManager` — `app/Databases/EngineManager.php`**

```php
class EngineManager {
    public function __construct(private array $drivers) {} // keyed by engine string
    public function for(string $engine): DatabaseEngineDriver;
    public function available(): array; // engine strings for installed+active engines
    public function capabilitiesFor(string $engine): EngineCapabilities;
}
```

`available()` implementation: iterate a config-seeded list `laranode.db_engines`; for each, run `Process::run(['systemctl', 'is-active', $service])` and include only those that return `active`. If `available()` returns an empty array (no engine installed), the create form shows an appropriate empty state — no engine selector rendered.

MariaDB detection: `EngineManager` checks `systemctl is-active mariadb` for the `mariadb` slot and `systemctl is-active mysql` for the `mysql` slot. Since both bind port 3306 and cannot coexist on the same host, at most one of `mysql` or `mariadb` will be active on any given machine. The config maps each engine key to its own service name.

Drivers are registered in a new `DatabaseServiceProvider`:

```php
$this->app->singleton(EngineManager::class, fn () => new EngineManager([
    'mysql'    => new MysqlDriver(),
    'mariadb'  => new MariaDbDriver(),
    'postgres' => new PostgresDriver(),
]));
```

**5. Services — `app/Services/Database/`** (renamed from `app/Services/MySQL/`)

`CreateDatabaseService`, `UpdateDatabaseService`, `DeleteDatabaseService` — same single `handle()` + sibling `*Exception` pattern. Now accept an `EngineManager` (injected) and dispatch to `$manager->for($engine)->create($spec)` etc. They still own the Eloquent `Database::create()` / `$database->update()` / `$database->delete()` calls; drivers never touch Eloquent.

`GetDatabasesWithStatsService` — replaces `GetDatabasesWithStatsAction`. Uses `Database::scopeMine()` (so it respects admin vs. non-admin), groups by engine, calls the appropriate driver's `stats()` for each. Returns a flat array for Inertia including `engine` field. N+1 stats calls are acceptable in v1 (noted); a per-request cache guards against repeated calls within a single request.

**6. Controller — `app/Http/Controllers/DatabasesController.php`**

New file. Replaces `MysqlController`. Engine-agnostic: takes `engine` from the request for `store`, loads `$database->engine` for `update`/`destroy`. Structure matches `MysqlController` method-for-method so the route swap is surgical.

`index` — calls `GetDatabasesWithStatsService`, renders `Pages/Databases/Index`.
`getEngineOptions` (new, replaces `getCharsetsAndCollations`) — takes `?engine` query param, returns `EngineCapabilities + options` for the dynamic form.
`store`, `update`, `destroy` — thin delegation to services.

**7. FormRequests — modified**

`CreateDatabaseRequest` — adds `engine` field (validated against `EngineManager::available()`). Removes the hardcoded charset/collation requirement; instead requires the option fields declared by `EngineCapabilities::optionFields` for the chosen engine (dynamic validation). **Critical security fix:** charset and collation are validated against an allowlist (`regex:/^[a-zA-Z0-9_]+$/`) before they can reach any SQL string — this must be in both `CreateDatabaseRequest` and `UpdateDatabaseRequest`, not only in the driver.

`UpdateDatabaseRequest` — same allowlist validation for charset and collation; engine is read from the existing `Database` record, not the request.

**8. Script — `laranode-scripts/bin/laranode-postgres.sh`** (new)

Actions: `create-db <name> <encoding> <locale>`, `create-user <user>` (password via stdin), `grant <user> <db>`, `revoke <user> <db>`, `drop-db <name>`, `drop-user <user>`, `update-user-password <user>` (password via stdin). Runs as the `postgres` OS user via `sudo -u postgres psql`.

Password handling: passed via a temp file with mode 0600 (`mktemp`, written immediately, `trap` to clean up on exit) and consumed by `psql` with `PGPASSFILE` or piped via stdin to `ALTER ROLE` — never as a positional argv.

SQL quoting: database and user names use double-quoted identifiers (`"$name"`). Passwords for `ALTER ROLE ... PASSWORD` use a unique per-invocation dollar tag (`$tag$...$tag$` where `tag` is a random suffix generated by the script) so a user-supplied literal dollar sign cannot break the quoting.

Validation: `$2` (name/user argument) matches `^[a-zA-Z0-9_]+$` — exit 1 with error message if not. Encoding and locale arguments are also validated against a fixed allowlist (e.g. `UTF8`, `en_US.UTF-8`).

`/etc/sudoers.d/laranode-postgres` — grants `www-data NOPASSWD: /path/to/laranode-postgres.sh`. Added as a dedicated drop-in (not appended to the monolithic sudoers wildcard line).

**9. Routes — `routes/web.php`**

New canonical routes:
```
GET    /databases                    databases.index
GET    /databases/engine-options     databases.engine-options
POST   /databases                    databases.store
PATCH  /databases                    databases.update
DELETE /databases                    databases.destroy
```

Back-compat aliases — same-handler aliases pointing the old `mysql.*` URIs directly at `DatabasesController`, NOT HTTP redirects (a 301 on POST/PATCH/DELETE becomes a GET silently, breaking form submissions):
```php
Route::get('/mysql',                    [DatabasesController::class, 'index'])->name('mysql.index');
Route::get('/mysql/charsets-collations',[DatabasesController::class, 'getEngineOptions'])->name('mysql.charsets-collations');
Route::post('/mysql',                   [DatabasesController::class, 'store'])->name('mysql.store');
Route::patch('/mysql',                  [DatabasesController::class, 'update'])->name('mysql.update');
Route::delete('/mysql',                 [DatabasesController::class, 'destroy'])->name('mysql.destroy');
```
No controller duplication; both URI sets go to the same handler methods.

**10. Frontend — `resources/js/Pages/Databases/`**

`Pages/Databases/Index.jsx` — replaces `Pages/Mysql/Index.jsx`. The table gains an "Engine" column. Engine badge (MySQL / MariaDB / PostgreSQL) shown per row. Charset/collation columns become nullable; show `—` for Postgres rows. Empty state shown when no databases exist.

`Pages/Databases/Partials/CreateDatabaseForm.jsx` — replaces the MySQL-specific form. On mount, calls `databases.engine-options` with no engine to get the available engine list. If the list is empty, shows an empty state ("No database engine is currently active on this server"). On engine selection, re-fetches `engine-options?engine=<selected>` to get that engine's `optionFields`. Renders engine fields dynamically from `optionFields` descriptors. Removes all hardcoded per-engine UI conditionals.

`Pages/Databases/Partials/EditDatabaseForm.jsx` — same dynamic options pattern; engine is fixed (display-only) since you cannot change a database's engine after creation.

No new React hooks or Reverb channels — database create/update/delete remain synchronous.

## Data model + migrations

**Migration 1: `add_engine_to_databases_table`**
```php
Schema::table('databases', function (Blueprint $table) {
    $table->string('engine')->default('mysql')->after('user_id');
    $table->string('charset')->nullable()->change();
    $table->string('collation')->nullable()->change();
});
// Explicit backfill — covers pre-existing rows including any with null engine
DB::table('databases')->whereNull('engine')->orWhere('engine', '')->update(['engine' => 'mysql']);
```

**`Database` model — `app/Models/Database.php`** (modified)
- Add `'engine'` to `$fillable`.
- No other changes; `scopeMine()`, `db_password` encrypted cast, and `user()` relation stay as-is.
- `EngineManager::for()` treats a null or empty `engine` column as `'mysql'` as a defensive guard.

## Request / data flow

**Create (MySQL example):**
1. User opens create modal → JS calls `GET /databases/engine-options` → returns available engine list.
2. User picks engine → JS calls `GET /databases/engine-options?engine=mysql` → returns charset/collation option lists.
3. Submit → `POST /databases` → `CreateDatabaseRequest::authorize()` + `rules()` (allowlist-validates charset/collation, validates engine against `available()`) → `CreateDatabaseService::handle()` → `EngineManager::for('mysql')->create($spec)` → `MysqlDriver` runs parameterized SQL on `mysql_admin` connection → service calls `Database::create(['engine' => 'mysql', ...])`.
4. Redirect → `databases.index`.

**Create (Postgres):**
Same except step 3: `PostgresDriver::create($spec)` calls `sudo laranode-postgres.sh create-db ...`, then `create-user` (password via stdin), then `grant`. The `Database` row stores `engine='postgres'`; `charset`/`collation` are null.

**Delete:**
`DatabasesController@destroy` → `DeleteDatabaseRequest` → `DeleteDatabaseService` → loads `$database->engine` → `EngineManager::for($engine)->delete($database)` → driver-specific drop → `$database->delete()`.

## Error handling

Services declare `CreateDatabaseException` / `UpdateDatabaseException` / `DeleteDatabaseException` (sibling classes in the same file). Drivers throw these on failure. The controller catches and flash-redirects as today.

`PostgresDriver` checks `Process::result()->exitCode()` after each sudo call and throws on non-zero. The script's stderr is included in the exception message.

`EngineManager::for($engine)` throws `InvalidArgumentException` for unknown/unavailable engines — the `CreateDatabaseRequest` validation prevents this reaching the service in normal flow.

If `EngineManager::available()` returns an empty array at the controller level, `getEngineOptions` returns `{ engines: [], capabilities: null }` and the frontend shows an empty state.

## Security

**MySQL/MariaDB charset+collation injection (fixed):** The current `CreateDatabaseService` and `UpdateDatabaseService` interpolate `$charset` and `$collation` directly into SQL strings (e.g. `"CREATE DATABASE \`$name\` CHARACTER SET $charset COLLATE $collation"`). MySQL does not support bind params for `CHARACTER SET` / `COLLATE` clauses, so these values must be validated before interpolation. **Both** `CreateDatabaseRequest` and `UpdateDatabaseRequest` must add:
```php
'charset'   => ['required_if:engine,mysql', 'regex:/^[a-zA-Z0-9_]+$/'],
'collation' => ['required_if:engine,mysql', 'regex:/^[a-zA-Z0-9_]+$/'],
```
The `MysqlDriver` additionally asserts the same pattern as defense-in-depth before use.

**MySQL/MariaDB password injection (fixed):** The current code interpolates `$dbPass` and `$newPassword` into SQL strings. `MysqlDriver` uses parameterized statements throughout:
```php
DB::connection('mysql_admin')->statement("CREATE USER IF NOT EXISTS `{$dbUser}`@'localhost' IDENTIFIED BY ?", [$password]);
DB::connection('mysql_admin')->statement("ALTER USER `{$dbUser}`@'localhost' IDENTIFIED BY ?", [$newPassword]);
```
The injection test must use a real captured-SQL assertion (not `pretend()+listen()`, which logs nothing and is vacuous). Use a test-specific `mysql_admin` connection bound to a real SQLite-in-memory connection that records executed statements, or use a spy on `DB::connection()->statement()`.

**MySQL/MariaDB connection isolation (fixed):** `MysqlDriver` and `MariaDbDriver` use a dedicated `mysql_admin` / `mariadb_admin` connection (`config/database.php`), not the panel's own app connection. These connections read from `MYSQL_ADMIN_USERNAME` / `MYSQL_ADMIN_PASSWORD` env vars, falling back to `DB_USERNAME` / `DB_PASSWORD` only when those vars are absent. The panel's own `mysql` connection is never used for user-managed database operations.

**PostgreSQL password visibility (fixed):** The Postgres user password is never passed as a positional argv (visible in `ps`/`/proc/cmdline`). It is passed via a 0600 temp file (cleaned up by `trap`) or via stdin pipe to `psql`. Inside the script, the password is set via `ALTER ROLE ... PASSWORD '$tag$...$tag$'` where `$tag$` is a unique per-invocation string (e.g. `$pwd_<random>$`) — never bare `$$` which a dollar sign in the password could escape.

**PostgreSQL access control:** `laranode-postgres.sh create-db` issues `REVOKE CONNECT ON DATABASE "$name" FROM PUBLIC` immediately after `CREATE DATABASE`. `grant` issues `GRANT CONNECT ON DATABASE "$db" TO "$user"` explicitly. This matches MySQL's per-database GRANT model — new databases are not accessible to all roles by default.

**PostgreSQL connection isolation:** Stats use a separate `pgsql_admin` connection (new entry in `config/database.php`) reading from `PGSQL_HOST` / `PGSQL_PORT` / `PGSQL_DB` / `PGSQL_USERNAME` / `PGSQL_PASSWORD` env vars. The existing Laravel skeleton `pgsql` connection reads `DB_HOST` / `DB_PORT` etc. and must not be modified or reused for panel-managed Postgres stats. A new `pgsql_admin` connection is added alongside it.

**Channel / access control:** no new broadcast channels. `DatabasesController` reuses `Gate::authorize('update'/$database)` and `Gate::authorize('delete'/$database)` as today. `scopeMine()` on `Database` is unchanged; both admin and non-admin paths are tested.

## `config/database.php` additions

Add a `mysql_admin` connection (copy of `mysql` structure, but `username`/`password` read from `MYSQL_ADMIN_USERNAME`/`MYSQL_ADMIN_PASSWORD`, falling back to `DB_USERNAME`/`DB_PASSWORD` if unset). Add `mariadb_admin` (same pattern). Add `pgsql_admin` reading from `PGSQL_HOST`, `PGSQL_PORT`, `PGSQL_DB`, `PGSQL_USERNAME`, `PGSQL_PASSWORD`. These connections are used only by the drivers, not by the panel's own migrations.

Document all new env vars in `.env.example`:
```
MYSQL_ADMIN_USERNAME=
MYSQL_ADMIN_PASSWORD=
PGSQL_HOST=127.0.0.1
PGSQL_PORT=5432
PGSQL_DB=postgres
PGSQL_USERNAME=laranode_pg_reader
PGSQL_PASSWORD=
```

Add `laranode.db_engines` config key in `config/laranode.php`:
```php
'db_engines' => [
    'mysql'    => ['service' => 'mysql',      'port' => 3306],
    'mariadb'  => ['service' => 'mariadb',    'port' => 3306],
    'postgres' => ['service' => 'postgresql', 'port' => 5432],
],
```

## Testing strategy

**Unit tests (no real DB/Process) — `tests/Feature/Database/`**

- `EngineManagerTest`: mock `Process` for systemctl responses → `available()` returns only active engines; handles empty available() (no engine installed); `for('unknown')` throws. Tests both mysql and mariadb detection paths.
- `MysqlDriverTest`: real captured-SQL assertion (NOT `pretend()+listen()` which logs nothing). Use a mock/spy on the `mysql_admin` connection's `statement()` method, or bind the `mysql_admin` connection to an in-memory SQLite that records DDL. Assert correct SQL shape; assert the literal password never appears in any captured SQL string; assert charset/collation injection attempt is rejected at the request layer (allowlist regex).
- `PostgresDriverTest`: `Process::fake()` → assert correct argument list passed to `laranode-postgres.sh`; assert password is NOT present as a positional arg in the command array; assert non-zero exit throws `CreateDatabaseException`; assert `REVOKE CONNECT` step is called (check script action sequence).
- `CreateDatabaseServiceTest`: mock `EngineManager` → assert service calls `driver->create()` and then `Database::create()` with the correct engine field.
- `DatabasesControllerTest`: `GET /databases` (auth, non-admin) → 200, only own rows; `GET /databases` (admin) → 200, all rows; `GET /databases` (unauthenticated) → 302; `POST /databases` with invalid engine → 422; `POST /databases` with bad charset (e.g. `utf8; DROP DATABASE`) → 422; `mysql.index` route resolves to same handler as `databases.index` (same-handler alias, not a redirect).
- `BackfillTest`: insert a database row with null engine directly to the DB, run the migration, assert the row has `engine='mysql'` afterwards.

**Container integration tests (`LARANODE_SYSTEM_TESTS=1`) — `tests/Feature/Database/`**

- `MysqlIntegrationTest`: hit real `mysql_admin` connection → `POST /databases` with `engine=mysql` creates a real MySQL database and user; `GET /databases` shows it with stats; `DELETE /databases` drops it. Non-admin variant: assert non-admin only sees own row. Within `RefreshDatabase` / explicit teardown.
- `PostgresIntegrationTest`: same flow with `engine=postgres` against a real Postgres instance in the `local-dev` container. Assert `REVOKE CONNECT FROM PUBLIC` was applied (attempt to connect as a different user fails). Assert password is not visible in process list during create.

**Frontend (Vitest)**

- `CreateDatabaseForm.test.jsx` — mock `axios.get` for `engine-options`; assert engine selector populates; assert option fields re-render on engine change; assert Postgres rows hide charset/collation fields; assert MySQL form shows them; assert empty engine list shows empty state.

**Local-dev Postgres parity**

Add Postgres to the `local-dev` container via `entrypoint-setup.sh` (install `postgresql-16` + `postgresql-client-16`, start the service, apply the sudoers drop-in, run a smoke test). Add a named volume `laranode-postgres` mounted at `/var/lib/postgresql` in `local-dev/docker-compose.yml`.

## Back-compat + migration

- All five existing `mysql.*` routes are kept as same-handler aliases pointing directly at `DatabasesController` methods. No redirects — POST/PATCH/DELETE must not silently become GET. No existing functionality breaks.
- `Pages/Mysql/` files are kept temporarily until a future cleanup pass; `DatabasesController` renders `Pages/Databases/Index`.
- `app/Services/MySQL/` namespace is deleted; `app/Actions/MySQL/` namespace is deleted. Both are internal.
- `MysqlController` is kept as a thin shim delegating to `DatabasesController`. Removed in a follow-up.
- The `databases` table migration is additive: `engine` column with `default('mysql')` + immediate backfill. `EngineManager::for()` treats null or empty engine as `'mysql'` as a defensive guard.
- `charset`/`collation` columns become nullable but retain existing data for MySQL rows. No data is lost.

## Resolved decisions

1. **`mysql_admin` credentials:** dedicated `MYSQL_ADMIN_USERNAME` / `MYSQL_ADMIN_PASSWORD` env vars with fallback to `DB_USERNAME`/`DB_PASSWORD`. All new env vars documented in `.env.example`.

2. **MariaDB detection:** `systemctl is-active mariadb` for the `mariadb` slot, `systemctl is-active mysql` for the `mysql` slot. At most one will be active (both bind :3306). The config maps each engine key to its own service name — no port deduplication logic needed.

3. **Postgres access control:** `REVOKE CONNECT ON DATABASE $name FROM PUBLIC` issued immediately after `CREATE DATABASE`. `GRANT CONNECT` issued explicitly to the created user. This matches MySQL's per-database GRANT model.

4. **`GetDatabasesWithStatsService` performance:** N+1 stats calls are acceptable in v1. A per-request cache (e.g. `Cache::remember` with a very short TTL or a simple `static` array inside the service) prevents duplicate calls within a single request. Batch stats or lazy-load endpoints are deferred to a follow-up if profiling shows a problem.

5. **`mysql.*` back-compat alias lifetime:** aliases are kept for the duration of this sub-project and into the next until the MySQL-specific UI is confirmed stable. Removal is a follow-up "cleanup" task. They are same-handler aliases (not redirects) so they add no observable overhead.

## File inventory

```
app/Contracts/DatabaseEngineDriver.php           (new — interface)
app/Databases/DatabaseSpec.php                   (new — DTO)
app/Databases/DatabaseStats.php                  (new — DTO)
app/Databases/EngineCapabilities.php             (new — DTO)
app/Databases/EngineManager.php                  (new — factory)
app/Databases/Drivers/MysqlDriver.php            (new — relocates+fixes MySQL/*Service SQL)
app/Databases/Drivers/MariaDbDriver.php          (new — extends MysqlDriver)
app/Databases/Drivers/PostgresDriver.php         (new — sudo script execution)
app/Providers/DatabaseServiceProvider.php        (new — registers EngineManager)
app/Services/Database/CreateDatabaseService.php  (new — replaces MySQL/CreateDatabaseService)
app/Services/Database/UpdateDatabaseService.php  (new — replaces MySQL/UpdateDatabaseService)
app/Services/Database/DeleteDatabaseService.php  (new — replaces MySQL/DeleteDatabaseService)
app/Services/Database/GetDatabasesWithStatsService.php (new — replaces MySQL action)
app/Http/Controllers/DatabasesController.php     (new — engine-agnostic, replaces MysqlController)
app/Http/Requests/CreateDatabaseRequest.php      (modify — add engine + allowlist charset/collation)
app/Http/Requests/UpdateDatabaseRequest.php      (modify — allowlist charset/collation)
database/migrations/XXXX_add_engine_to_databases_table.php (new)
config/database.php                              (modify — mysql_admin + mariadb_admin + pgsql_admin)
config/laranode.php                              (modify — db_engines map)
.env.example                                     (modify — MYSQL_ADMIN_* + PGSQL_* vars)
laranode-scripts/bin/laranode-postgres.sh        (new — privileged Postgres operations)
laranode-scripts/bin/laranode-postgres-sudoers   (new — sudoers drop-in template)
laranode-scripts/bin/laranode-installer.sh       (modify — install postgresql-client + sudoers drop-in)
local-dev/docker-compose.yml                     (modify — add laranode-postgres volume)
local-dev/entrypoint-setup.sh                    (modify — install + start Postgres + smoke test)
routes/web.php                                   (modify — databases.* routes + mysql.* same-handler aliases)
resources/js/Pages/Databases/Index.jsx           (new)
resources/js/Pages/Databases/Partials/CreateDatabaseForm.jsx (new)
resources/js/Pages/Databases/Partials/EditDatabaseForm.jsx   (new)
resources/js/Pages/Databases/Partials/CreateDatabaseForm.test.jsx (new — Vitest)
tests/Feature/Database/EngineManagerTest.php     (new)
tests/Feature/Database/MysqlDriverTest.php       (new)
tests/Feature/Database/PostgresDriverTest.php    (new)
tests/Feature/Database/CreateDatabaseServiceTest.php (new)
tests/Feature/Database/DatabasesControllerTest.php  (new)
tests/Feature/Database/BackfillTest.php             (new — real backfill assertion)
tests/Feature/Database/MysqlIntegrationTest.php     (new, LARANODE_SYSTEM_TESTS)
tests/Feature/Database/PostgresIntegrationTest.php  (new, LARANODE_SYSTEM_TESTS)
app/Services/MySQL/                              (delete — replaced by app/Services/Database/)
app/Actions/MySQL/                               (delete — replaced by driver stats() methods)
app/Http/Controllers/MysqlController.php         (keep as shim → deprecate in follow-up)
resources/js/Pages/Mysql/                        (keep temporarily → remove in follow-up)
```

## Out of scope (later sub-projects / deferred)

- SQLite engine (local-dev only, no system user model, different set of constraints).
- MongoDB engine.
- Database dump / restore (a separate async feature using `OperationJob`).
- Per-database engine migration (moving a DB from MySQL to Postgres).
- Replication / replica management.
- Admin view of all users' databases across all users simultaneously (impersonation covers the use case today).
- Batch stats queries or lazy-load stats endpoint (defer until profiling shows N+1 is a real problem).
