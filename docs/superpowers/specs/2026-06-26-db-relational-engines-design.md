# Sub-project #2 — DB driver seam + MySQL / MariaDB / PostgreSQL (`db-relational-engines`)

- **Date:** 2026-06-26
- **Status:** Approved design (ready for writing-plans)
- **Roadmap:** Phase 1, sub-project #2 of `docs/superpowers/specs/2026-06-25-laranode-feature-roadmap.md`
- **Branch:** `feature/db-relational-engines` (off `development`)

## Goal

Introduce a driver abstraction seam so Laranode can manage databases on whichever relational engine is installed on the host (MySQL, MariaDB, or PostgreSQL), while keeping the user-facing experience identical to what ships today. Existing MySQL behavior is preserved without any user-visible regression. PostgreSQL is added as a first-class engine with idiomatic peer-auth execution. The seam makes future engines (SQLite, MongoDB) trivial to add.

**Why now:** the host may run MariaDB instead of MySQL, or may add PostgreSQL alongside. Without a seam, every engine needs its own parallel stack. One interface, three drivers, one controller.

## Success criteria

- Creating a database selects engine from the available set on the host; the form only offers what is installed and active.
- MySQL/MariaDB databases continue to work exactly as before with zero data loss or migration required; existing rows backfilled to `engine='mysql'`.
- PostgreSQL databases are created/dropped via `sudo laranode-postgres.sh` (peer auth, no stored superuser password). Stats are fetched via `pg_database_size`.
- `EngineManager::available()` reflects the real host state (systemctl check); the create form is driven by `EngineCapabilities` returned from the chosen driver — no hardcoded per-engine UI.
- SQL injection surface in the existing MySQL services is fixed at relocation into `MysqlDriver`.
- Tests exist for the first time for the DB path: unit tests (mocked connection/Process) + container integration tests against real MySQL and real PostgreSQL (under `LARANODE_SYSTEM_TESTS=1`).
- Routes `/databases/*` work; `mysql.*` route aliases redirect for back-compat.

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

- `DatabaseSpec` — `readonly class { string $name, string $dbUser, string $password, array $options = [] }`. Passed to `create()`. Options carry engine-specific fields (charset+collation for MySQL/MariaDB; encoding+locale for Postgres).
- `DatabaseStats` — `readonly class { int $tableCount, float $sizeMb, array $extra = [] }`. Returned by `stats()`. The `extra` bag carries engine-specific data (Postgres has no table count via the same path — return 0 or omit).
- `EngineCapabilities` — `readonly class { string $label, bool $hasUsers, array $optionFields }`. `optionFields` is an array of `['key' => 'charset', 'label' => 'Charset', 'type' => 'select', 'source' => 'charset-options']` descriptors that drive the dynamic create form. No hardcoded per-engine UI.

**3. Drivers — `app/Databases/Drivers/`**

`MysqlDriver implements DatabaseEngineDriver`
- Runs all SQL via the named `mysql_admin` Laravel DB connection (a new entry in `config/database.php` using the existing MySQL credentials with elevated privileges, separate from the panel's own connection). Mirrors the current inline `DB::statement(...)` calls in `CreateDatabaseService` / `UpdateDatabaseService` / `DeleteDatabaseService`, but with fixed identifier escaping (see Security section).
- `capabilities()` returns `EngineCapabilities(label:'MySQL', hasUsers:true, optionFields:[charset, collation])`.
- `stats()` runs the existing `information_schema` queries from `GetDatabasesWithStatsAction`.

`MariaDbDriver extends MysqlDriver`
- Zero SQL differences; overrides only `capabilities()` label (`'MariaDB'`) and the DB connection name (`mariadb_admin`). MySQL and MariaDB never coexist on the same host (both bind :3306) — the `EngineManager` returns one or the other, never both.

`PostgresDriver implements DatabaseEngineDriver`
- All mutations shell out to `sudo laranode-postgres.sh <action> <args>` via `Process::run(['sudo', config('laranode.laranode_bin_path').'/laranode-postgres.sh', $action, ...])`. No stored superuser password; the script runs as the `postgres` OS user via peer auth.
- `stats()` connects via the application's `pgsql` Laravel connection (read-only panel DB user) to run `SELECT pg_database_size($name)` and query `pg_stat_user_tables` for table count.
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

`available()` implementation: iterate a config-seeded list `laranode.db_engines` (e.g. `['mysql','postgres']`); for each, run `Process::run(['systemctl', 'is-active', $service])` and include only those that return `active`. The MySQL and MariaDB service names differ (`mysql` vs `mariadb`) — the config maps engine → service name. In the create form, only available engines are offered.

Drivers are registered in a new `DatabaseServiceProvider`:

```php
$this->app->singleton(EngineManager::class, fn () => new EngineManager([
    'mysql'    => new MysqlDriver(),
    'mariadb'  => new MariaDbDriver(),
    'postgres' => new PostgresDriver(),
]));
```

This mirrors the Flysystem injection pattern in `AppServiceProvider`.

**5. Services — `app/Services/Database/`** (renamed from `app/Services/MySQL/`)

`CreateDatabaseService`, `UpdateDatabaseService`, `DeleteDatabaseService` — same single `handle()` + sibling `*Exception` pattern. Now accept an `EngineManager` (injected) and dispatch to `$manager->for($engine)->create($spec)` etc. They still own the Eloquent `Database::create()` / `$database->update()` / `$database->delete()` calls; drivers never touch Eloquent.

`GetDatabasesWithStatsService` — replaces `GetDatabasesWithStatsAction`. Iterates `Database::scopeMine()`, groups by engine, calls the appropriate driver's `stats()` for each. Returns a flat array for Inertia.

**6. Controller — `app/Http/Controllers/DatabasesController.php`**

New file. Replaces `MysqlController`. Engine-agnostic: takes `engine` from the request for `store`, loads `$database->engine` for `update`/`destroy`. Structure matches `MysqlController` method-for-method so the route swap is surgical.

`index` — calls `GetDatabasesWithStatsService`, renders `Pages/Databases/Index`.
`getEngineOptions` (new, replaces `getCharsetsAndCollations`) — takes `?engine` query param, returns `EngineCapabilities + options` for the dynamic form.
`store`, `update`, `destroy` — thin delegation to services.

**7. FormRequests — modified**

`CreateDatabaseRequest` — adds `engine` field (validated against `EngineManager::available()`). Removes the hardcoded charset/collation requirement; instead requires the option fields declared by `EngineCapabilities::optionFields` for the chosen engine (dynamic validation).

`UpdateDatabaseRequest` — same dynamic option-fields approach; engine is read from the existing `Database` record, not the request.

**8. Script — `laranode-scripts/bin/laranode-postgres.sh`** (new)

Actions: `create-db <name> <encoding> <locale>`, `create-user <user> <password>`, `grant <user> <db>`, `revoke <user> <db>`, `drop-db <name>`, `drop-user <user>`. Runs as the `postgres` OS user via `sudo -u postgres psql -c "..."`. Arguments are positional; the script validates non-empty and alphanumeric-safe names before passing to psql. Uses `psql` `\$\$`-quoting for passwords to avoid shell injection.

`/etc/sudoers.d/laranode-postgres` — grants `www-data NOPASSWD: /path/to/laranode-postgres.sh`. Added as a dedicated drop-in (not appended to the monolithic sudoers line).

**9. Routes — `routes/web.php`**

New canonical routes:
```
GET  /databases                    databases.index
GET  /databases/engine-options     databases.engine-options
POST /databases                    databases.store
PATCH /databases                   databases.update
DELETE /databases                  databases.destroy
```

Alias routes for back-compat (keep `mysql.*` names resolving):
```
Route::get('/mysql', ...)->name('mysql.index');   // 301 redirect to databases.index
... (and so on for store/update/destroy/charsets-collations)
```
The back-compat aliases call `redirect()->route('databases.*')` so no controller duplication.

**10. Frontend — `resources/js/Pages/Databases/`**

`Pages/Databases/Index.jsx` — replaces `Pages/Mysql/Index.jsx`. The table gains an "Engine" column. Engine badge (MySQL / MariaDB / PostgreSQL) shown per row. Charset/collation columns become nullable; show `—` for Postgres rows.

`Pages/Databases/Partials/CreateDatabaseForm.jsx` — replaces the MySQL-specific form. On mount, calls `databases.engine-options` with no engine to get the available engine list. On engine selection, re-fetches `engine-options?engine=<selected>` to get that engine's `optionFields`. Renders engine fields dynamically from `optionFields` descriptors (a `source:'charset-options'` descriptor triggers the charset/collation fetch pattern; a `source:'encoding-locales'` triggers a static list of Postgres encodings). This removes all hardcoded per-engine conditionals from the UI.

`Pages/Databases/Partials/EditDatabaseForm.jsx` — same dynamic options pattern; engine is fixed (display-only) since you cannot change a database's engine after creation.

No new React hooks or Reverb channels — database create/update/delete remain synchronous (fast enough; no certbot-scale waits). The `OperationProgress` component from sub-project #1 is not used here.

## Data model + migrations

**Migration 1: `add_engine_to_databases_table`**
```php
Schema::table('databases', function (Blueprint $table) {
    $table->string('engine')->default('mysql')->after('user_id');
    $table->string('charset')->nullable()->change();    // was default 'utf8mb4'
    $table->string('collation')->nullable()->change();  // was default 'utf8mb4_unicode_ci'
});
```
Immediately followed by a data backfill: `DB::table('databases')->update(['engine' => 'mysql'])` (safe since `default('mysql')` covers new rows; the explicit backfill covers any null edge cases).

**`Database` model — `app/Models/Database.php`** (modified)
- Add `'engine'` to `$fillable`.
- No other changes; `scopeMine()`, `db_password` encrypted cast, and `user()` relation stay as-is.

## Request / data flow

**Create (MySQL example):**
1. User opens create modal → JS calls `GET /databases/engine-options` → `DatabasesController@getEngineOptions` → `EngineManager::available()` + `EngineCapabilities` for each → JSON `{ engines: [...], optionFields: [...] }`.
2. User fills form, picks engine → JS calls `GET /databases/engine-options?engine=mysql` → returns charset/collation option lists for the form fields.
3. Submit → `POST /databases` → `CreateDatabaseRequest::authorize()` + `rules()` (dynamic option fields) → `CreateDatabaseService::handle()` → `EngineManager::for('mysql')->create($spec)` → `MysqlDriver` runs `CREATE DATABASE` + `CREATE USER` + `GRANT` on the `mysql_admin` connection → service calls `Database::create(['engine' => 'mysql', ...])`.
4. Redirect → `databases.index` → `GetDatabasesWithStatsService` queries each row's driver for stats → Inertia renders `Pages/Databases/Index`.

**Create (Postgres):**
Same except step 3: `PostgresDriver::create($spec)` calls `Process::run(['sudo', '.../laranode-postgres.sh', 'create-db', $name, $encoding, $locale])`, then `create-user`, then `grant`. The `Database` row stores `engine='postgres'`; `charset`/`collation` are null.

**Delete:**
`DatabasesController@destroy` → `DeleteDatabaseRequest` → `DeleteDatabaseService` → loads `$database->engine` → `EngineManager::for($engine)->delete($database)` → driver-specific drop → `$database->delete()`.

## Error handling

Services declare `CreateDatabaseException` / `UpdateDatabaseException` / `DeleteDatabaseException` (sibling classes in the same file, matching the existing pattern). Drivers throw these on failure. The controller catches and flash-redirects as today.

`PostgresDriver` additionally checks `Process::result()->exitCode()` after each sudo call and throws on non-zero. The script's stderr is included in the exception message.

`EngineManager::for($engine)` throws `InvalidArgumentException` for unknown/unavailable engines — the `CreateDatabaseRequest` validation prevents this reaching the service in normal flow.

## Security

**MySQL/MariaDB identifier injection (fixed):** The current `CreateDatabaseService` interpolates `$name`, `$dbUser`, and `$dbPass` directly into SQL strings — e.g., `` "CREATE USER IF NOT EXISTS `$dbUser`@'localhost' IDENTIFIED BY '$dbPass'" ``. `MysqlDriver` must fix this:
- Database name and username: validate in `CreateDatabaseRequest` (the `regex:/^{prefix}[a-zA-Z0-9_]+$/` rules already constrain to safe characters — keep them, and add a defense-in-depth assertion in the driver that the value matches `[a-zA-Z0-9_]+` before use).
- Password: use a `DB::statement("ALTER USER ...IDENTIFIED BY ?", [$password])` parameterized form where the driver supports it, or at minimum run `DB::statement("SET PASSWORD FOR ...= PASSWORD(?)", [$password])`. The goal is that the password value never appears in the raw SQL string. Use `DB::connection('mysql_admin')->statement(...)` throughout.

**PostgreSQL:** peer auth means no stored superuser credentials anywhere in Laravel. The `laranode-postgres.sh` script is the only path with elevated access. Password for the created DB user is passed as a positional argument to the script and written via psql `\password` or `ALTER ROLE ... PASSWORD '...'` using `$$`-quoting inside the script to isolate it from shell interpolation. The script validates that name arguments match `^[a-zA-Z0-9_]+$` before use.

**Channel / access control:** no new broadcast channels. `DatabasesController` reuses `Gate::authorize('update'/$database)` and `Gate::authorize('delete'/$database)` as today. `scopeMine()` on `Database` is unchanged.

## `config/database.php` additions

Add a `mysql_admin` connection (copy of `mysql` but connected to the admin MySQL account — credentials from `.env` as `MYSQL_ADMIN_USERNAME` / `MYSQL_ADMIN_PASSWORD`). `MariaDbDriver` uses `mariadb_admin` (same pattern). These connections are used only by the drivers, not by the panel's own migrations.

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

- `EngineManagerTest`: mock `Process` for systemctl responses → `available()` returns only active engines; `for('unknown')` throws.
- `MysqlDriverTest`: mock the `mysql_admin` DB connection → assert correct SQL shape for create/updatePassword/delete; assert `capabilities()` returns expected `EngineCapabilities`; assert identifier injection attempt is rejected (e.g., `name` with a backtick) by the validation layer before reaching the driver.
- `PostgresDriverTest`: `Process::fake()` → assert correct argument list passed to `laranode-postgres.sh` for create/delete; assert non-zero exit throws `CreateDatabaseException`.
- `CreateDatabaseServiceTest`: mock `EngineManager` → assert service calls `driver->create()` and then `Database::create()` with the correct engine field.
- `DatabasesControllerTest`: `GET /databases` (auth) → 200, correct Inertia component; `GET /databases` (unauthenticated) → 302; `POST /databases` with invalid engine → 422.

**Container integration tests (`LARANODE_SYSTEM_TESTS=1`) — `tests/Feature/Database/`**

- `MysqlIntegrationTest`: hit real `mysql_admin` connection → `POST /databases` with `engine=mysql` creates a real MySQL database and user; `GET /databases` shows it with stats; `DELETE /databases` drops it. All within `RefreshDatabase` / explicit teardown.
- `PostgresIntegrationTest`: same flow with `engine=postgres` against a real Postgres instance in the `local-dev` container (Postgres service added to `local-dev/docker-compose.yml` and `local-dev/entrypoint-setup.sh`).

**Frontend (Vitest, reusing the harness from sub-project #1)**

- `CreateDatabaseForm.test.jsx` — mock `axios.get` for `engine-options`; assert engine selector populates; assert option fields re-render on engine change; assert Postgres rows hide charset/collation fields; assert MySQL form shows them.

**Local-dev Postgres parity**

Add a `postgres` service to `local-dev/docker-compose.yml` (image `postgres:16`, named volume `laranode-postgres`). Add a `laranode-postgres` volume entry. In `local-dev/entrypoint-setup.sh`, install `postgresql-client` and run `laranode-postgres.sh` integration smoke. The `LARANODE_SYSTEM_TESTS=1` Pest run in the container exercises both MySQL and Postgres paths.

## Back-compat + migration

- All five existing `mysql.*` routes are kept as redirect aliases (`301`) pointing to `databases.*`. No existing bookmarks break.
- `Pages/Mysql/` files are kept temporarily (renamed internally to render `Pages/Databases/` via an Inertia alias or a thin re-export) until a future cleanup pass; this avoids a breaking Inertia component-name change for any cached sessions.
- `app/Services/MySQL/` namespace is deleted; `app/Actions/MySQL/` namespace is deleted. Both are internal; nothing outside the panel calls them.
- `MysqlController` is kept as a thin shim that delegates to `DatabasesController` methods. It is removed in a follow-up once the redirect routes are confirmed stable.
- The `databases` table migration is additive: `engine` column with `default('mysql')` and immediate backfill. Rolling deploy is safe — the panel handles `engine=null` as `mysql` in `EngineManager::for()` as a defensive guard.
- `charset`/`collation` columns become nullable but retain their existing data for MySQL rows. No data is lost.

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
app/Http/Requests/CreateDatabaseRequest.php      (modify — add engine field + dynamic options)
app/Http/Requests/UpdateDatabaseRequest.php      (modify — dynamic options)
database/migrations/XXXX_add_engine_to_databases_table.php (new)
config/database.php                              (modify — mysql_admin + mariadb_admin connections)
config/laranode.php                              (modify — db_engines map)
laranode-scripts/bin/laranode-postgres.sh        (new — privileged Postgres operations)
/etc/sudoers.d/laranode-postgres                 (new — drop-in, provisioned by installer)
laranode-scripts/bin/laranode-installer.sh       (modify — install postgres-client + sudoers drop-in)
local-dev/docker-compose.yml                     (modify — add postgres service + volume)
local-dev/entrypoint-setup.sh                    (modify — start + smoke Postgres)
routes/web.php                                   (modify — new databases.* routes + mysql.* aliases)
resources/js/Pages/Databases/Index.jsx           (new)
resources/js/Pages/Databases/Partials/CreateDatabaseForm.jsx (new)
resources/js/Pages/Databases/Partials/EditDatabaseForm.jsx   (new)
resources/js/Pages/Databases/Partials/CreateDatabaseForm.test.jsx (new — Vitest)
tests/Feature/Database/EngineManagerTest.php     (new)
tests/Feature/Database/MysqlDriverTest.php       (new)
tests/Feature/Database/PostgresDriverTest.php    (new)
tests/Feature/Database/CreateDatabaseServiceTest.php (new)
tests/Feature/Database/DatabasesControllerTest.php  (new)
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
- Admin view of all users' databases (currently scoped to `scopeMine()` + Gate; admin impersonation covers the use case).

## Open questions

1. **`mysql_admin` credentials source:** should the privileged MySQL admin connection use the same root credentials as the panel's MySQL connection, or a dedicated `laranode_admin` MySQL account created by the installer? A dedicated account with only `CREATE/DROP DATABASE` + `CREATE/DROP USER` + `GRANT/REVOKE` privileges is safer — confirm before the implementation plan is written.

2. **MariaDB detection:** `systemctl is-active mysql` returns active on some Ubuntu MariaDB installs (the `mysql` service alias). Should availability detection use both `mysql` and `mariadb` service names and deduplicate by port, or rely on `mysqladmin version` output to distinguish? Decision affects `EngineManager::available()` logic and the config map.

3. **Postgres DB user model:** Postgres's `CREATE USER` grants login access to all databases by default until `REVOKE CONNECT` is applied per-database. Should `laranode-postgres.sh` issue an explicit `REVOKE CONNECT ON DATABASE $name FROM PUBLIC` after creation to limit access to the created user only, matching MySQL's explicit per-database GRANT model?

4. **`GetDatabasesWithStatsService` performance:** calling `stats()` per row means N driver calls (N information_schema queries for MySQL or N pg_database_size calls for Postgres). With many databases this will be slow. Should stats be batched (one query for all MySQL databases, one for all Postgres) in the initial implementation, or deferred behind a lazy-load / separate AJAX endpoint (matching the current pattern in `GetDatabasesWithStatsAction` which already does this per-row)?

5. **Back-compat alias lifetime:** the `mysql.*` redirect aliases create a split between two route name sets. Should they be removed at the end of this sub-project (once the frontend is updated) or kept until a dedicated "cleanup" pass? Keeping them indefinitely adds noise; removing them too soon breaks any user-bookmarked direct links.
