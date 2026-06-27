# Sub-project D8 — DB Service Control (`db-service-control`)

- **Date:** 2026-06-27
- **Status:** Draft
- **Roadmap:** Phase N, sub-project D8 (databases area)
- **Branch:** `feature/db-service-control` (off `development`)

## Goal

Let the admin start, stop, or restart any configured DB engine service from the Databases panel UI. A new `laranode-db-service.sh` translates an engine key (e.g. `mysql`) to a systemd service name (from `config('laranode.db_engines')`) and runs `systemctl <start|stop|restart> <service>`. The engine key is validated against the allowlist from config; arbitrary service names are never accepted. Because `restart` can take several seconds and produces meaningful output (systemd feedback), the action is wrapped as an `OperationJob` — same pattern as SSL and backups — with live progress via `OperationProgress` + Reverb. The Databases page already shows per-engine rows via `EngineManager::available()`; this feature adds a service-status indicator and three action buttons per engine.

**Why:** Panel admins need to restart the DB engine after config changes, upgrades, or when a service drops. SSH access for this is error-prone; the panel should expose it safely and leave an audit trail.

## Architecture

Pattern: **Controller (thin) → FormRequest (admin guard + engine validation) → `Operation::create` → `DbServiceOperationJob::dispatch` → `laranode-db-service.sh` via `Process::run` → `Operation` lifecycle (markRunning / appendOutput / markFinished) → Reverb broadcast → `OperationProgress` UI**.

This follows the same async path as `GenerateSslOperationJob` and `BackupJob`: the HTTP request creates an `Operation` row (status `queued`), dispatches the job, returns `operation_id` as JSON; the React UI polls via the `useOperation` hook over the `operations.{userId}` Reverb private channel; `OperationProgress` renders live status.

```
POST /admin/databases/service
  DbServiceRequest::authorize() [admin only] + rules() [engine in allowlist]
  DbServiceController::action()
    Operation::create([type='db.service.restart', target='{engine}:{service}', status='queued'])
    DbServiceOperationJob::dispatch($operation, $engine, $service, $action)
    return response()->json(['operation_id' => $operation->id])

DbServiceOperationJob (extends OperationJob):
  run(callable $emit):
    $emit("Running: systemctl {$action} {$service}...")
    Process::run(['sudo', bin_path.'/laranode-db-service.sh', $action, $engine])
    if failed: throw DbServiceException  <- OperationJob base marks failed + re-throws
    $emit("systemctl {$action} {$service} completed.")
    return 0
```

Read-only service status (shown in the UI without a button action) is fetched directly from `EngineManager::available()` which already calls `systemctl is-active` — no new code required for that.

### Why OperationJob (not inline sync)?

`systemctl restart mysql` can take 3–8 seconds on a loaded server; `systemctl stop` can take longer if the engine has open connections. An inline synchronous call risks an HTTP timeout and gives no progress visibility. The `OperationJob` pattern (already proven by `GenerateSslOperationJob` and `BackupJob`) handles this cleanly: the HTTP response is immediate, the job runs on the queue worker, and the admin sees live output through `OperationProgress`.

## Components (real file names)

### `laranode-scripts/bin/laranode-db-service.sh` (new)

Accepts exactly two arguments: `<action>` and `<engine>`.

```
laranode-db-service.sh <action: start|stop|restart> <engine: mysql|mariadb|postgres>
```

**Argument validation (in the script, before touching systemd):**

1. Reject if `$#` != 2.
2. Reject `$1` (action) if it does not match `^(start|stop|restart)$` — leading-dash check: `[[ "$ACTION" == -* ]]` exits non-zero.
3. Reject `$2` (engine) if it does not match the hardcoded allowlist `(mysql|mariadb|postgres)` — same leading-dash guard.
4. Resolve the service name from a `case` statement (mirrors `config('laranode.db_engines')`): `mysql → mysql`, `mariadb → mariadb`, `postgres → postgresql`. The script resolves the service name itself; PHP passes the engine key only, never a raw service name.
5. Run `systemctl "$ACTION" "$SERVICE"`.
6. Output the exit code-annotated result line.

The script never accepts an arbitrary service name from the caller. The engine-to-service map in the script must be kept in sync with `config/laranode.php`'s `db_engines` key.

`set -euo pipefail` at top. Output goes to stdout so `Process::run` captures it via `appendOutput`.

**Postgres variant:** on Ubuntu 24.04, `postgresql@16-main` is the active unit, not the `postgresql` alias. The script should try `postgresql` first and, on non-zero exit for the `start`/`stop`/`restart` call itself, also try `postgresql@16-main`. This mirrors the `$extraCandidates` pattern in `EngineManager`.

### `laranode-scripts/etc/sudoers.d/laranode-panel` (modify)

Add two lines to the existing `laranode-scripts/etc/sudoers.d/laranode-panel` file (which is deployed by `laranode-installer.sh` to `/etc/sudoers.d/laranode-panel`):

```
Defaults!/home/laranode_ln/panel/laranode-scripts/bin/laranode-db-service.sh !requiretty
www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-db-service.sh
```

The `(ALL)` run-as is consistent with every other entry in `laranode-panel` (the existing panel sudoers pattern); the script itself is the security boundary — it validates its inputs and calls only the resolved service name via `systemctl`. No `SETENV`.

`laranode-installer.sh` already deploys `laranode-panel` via `install -m 440`; no change to the installer is needed beyond adding the two lines above to the source file.

The `local-dev/entrypoint-setup.sh` uses a wildcard grant:

```bash
www-data ALL=(ALL) NOPASSWD: $BIN/*.sh, /usr/sbin/a2dissite, /bin/rm /etc/apache2/sites-available/*.conf
```

This already covers any `*.sh` under `$BIN`, so `laranode-db-service.sh` is automatically permitted in the container once it is copied there by the `cp` loop (line 60-62 of `entrypoint-setup.sh`). No change to `entrypoint-setup.sh` is needed.

### `App\Jobs\DbServiceOperationJob` (new, `app/Jobs/DbServiceOperationJob.php`)

Extends the abstract `OperationJob`. Constructor receives `Operation $operation`, `string $engine`, `string $service`, `string $action`.

```php
class DbServiceOperationJob extends OperationJob
{
    public function __construct(
        Operation $operation,
        public string $engine,
        public string $service,
        public string $action,
    ) {
        parent::__construct($operation);
    }

    protected function run(callable $emit): int
    {
        $emit("Running: systemctl {$this->action} {$this->service}...");
        $result = Process::run([
            'sudo',
            config('laranode.laranode_bin_path') . '/laranode-db-service.sh',
            $this->action,
            $this->engine,
        ]);
        $emit($result->output());
        if ($result->failed()) {
            throw new DbServiceException($result->errorOutput());
        }
        $emit("systemctl {$this->action} {$this->service} completed.");
        return 0;
    }
}

class DbServiceException extends \Exception {}
```

The `OperationJob` base class's `handle()` calls `markRunning()`, invokes `run()`, calls `markFinished($exit)`, and re-throws any `\Throwable` (recording it in `failed_jobs`). No extra lifecycle code is needed in the subclass.

### `App\Services\Database\DbServiceStatusService` (new, `app/Services/Database/DbServiceStatusService.php`)

Retrieves per-engine service status for the UI. Injected with `EngineManager`. Called by `DbServiceController::status()` and by `DatabasesController::index()`.

```php
class DbServiceStatusService
{
    public function __construct(private EngineManager $engineManager) {}

    /** @return array<string, array{service: string, active: bool}> */
    public function handle(): array
    {
        $engines = config('laranode.db_engines', []);
        $active = $this->engineManager->available(); // memoized; calls systemctl is-active

        $result = [];
        foreach ($engines as $key => $cfg) {
            $result[$key] = [
                'service' => $cfg['service'],
                'active' => isset($active[$key]),
            ];
        }
        return $result;
    }
}
```

This is read-only; `Process::run` is called inside `EngineManager::available()` — nothing new.

### `App\Http\Controllers\DbServiceController` (new, `app/Http/Controllers/DbServiceController.php`)

Admin-only. Two endpoints: `action()` (dispatches the job) and `status()` (returns current service statuses as JSON).

```php
class DbServiceController extends Controller
{
    public function __construct(private EngineManager $engineManager) {}

    // POST /admin/databases/service — dispatches DbServiceOperationJob
    public function action(DbServiceRequest $request): JsonResponse
    {
        $validated = $request->validated();
        $engine  = $validated['engine'];
        $action  = $validated['action'];

        // Resolve service name from config (PHP-side secondary validation)
        $engines = config('laranode.db_engines');
        $service = $engines[$engine]['service'];

        $operation = Operation::create([
            'user_id' => $request->user()->id,
            'type'    => "db.service.{$action}",
            'target'  => "{$engine}:{$service}",
            'status'  => 'queued',
        ]);

        DbServiceOperationJob::dispatch($operation, $engine, $service, $action);

        return response()->json(['operation_id' => $operation->id]);
    }

    // GET /admin/databases/service/status — returns per-engine active status
    public function status(): JsonResponse
    {
        $statuses = (new DbServiceStatusService($this->engineManager))->handle();
        return response()->json(['statuses' => $statuses]);
    }
}
```

The controller does not call `markRunning()` — that is `OperationJob::handle()`'s responsibility. The HTTP response is returned before the job runs.

### `App\Http\Requests\DbServiceRequest` (new, `app/Http/Requests/DbServiceRequest.php`)

```php
class DbServiceRequest extends FormRequest
{
    public function authorize(): bool
    {
        return $this->user()?->isAdmin() ?? false;
    }

    public function rules(): array
    {
        $allowedEngines = array_keys(config('laranode.db_engines', []));
        return [
            'engine' => ['required', 'string', Rule::in($allowedEngines)],
            'action' => ['required', 'string', Rule::in(['start', 'stop', 'restart'])],
        ];
    }
}
```

`authorize()` returns `false` for non-admins, producing a 403 before `rules()` runs. `Rule::in($allowedEngines)` means a config-driven allowlist: if an engine is removed from `config/laranode.php`, it is automatically blocked here too. Leading-dash and injection are handled by the enum-style validation (no regex needed in PHP — the script adds its own defense-in-depth guard).

### Routes (modify `routes/web.php`)

```php
// DB Service Control [Admin only]
Route::middleware(['auth', AdminMiddleware::class])->group(function () {
    Route::post('/admin/databases/service', [\App\Http\Controllers\DbServiceController::class, 'action'])
        ->name('databases.service.action');
    Route::get('/admin/databases/service/status', [\App\Http\Controllers\DbServiceController::class, 'status'])
        ->name('databases.service.status');
});
```

These live under `/admin/databases/service` to keep them separate from the user-facing `/databases` resource routes and to make the admin-only scope obvious in the URL.

### Frontend — `resources/js/Pages/Databases/Partials/DbServiceControl.jsx` (new)

A self-contained component rendered inside `resources/js/Pages/Databases/Index.jsx` (admin-only, below the database table). It:

1. Fetches `/admin/databases/service/status` via `axios.get` on mount and after each completed operation (using `onDone` from `OperationProgress`).
2. Renders a compact table of configured engines — one row per engine key from the response — with columns: Engine, Service, Status (green "active" / red "inactive" badge), and three buttons: "Start", "Stop", "Restart".
3. On button click, calls `axios.post(route('databases.service.action'), { engine, action })` which returns `{ operation_id }`.
4. Renders `<OperationProgress operationId={operationId} onDone={handleDone} />` (from `resources/js/Components/OperationProgress.jsx`) below the table once an operation is in flight.
5. On `onDone`, re-fetches the status to update the active badges.
6. Disables all buttons while an operation is in flight (`loading` state).

```jsx
import { useState, useEffect } from 'react';
import axios from 'axios';
import OperationProgress from '@/Components/OperationProgress';

export default function DbServiceControl() {
    const [statuses, setStatuses] = useState({});
    const [operationId, setOperationId] = useState(null);
    const [loading, setLoading] = useState(false);

    const fetchStatuses = () =>
        axios.get(route('databases.service.status'))
             .then(r => setStatuses(r.data.statuses ?? {}));

    useEffect(() => { fetchStatuses(); }, []);

    const doAction = async (engine, action) => {
        setLoading(true);
        const r = await axios.post(route('databases.service.action'), { engine, action });
        setOperationId(r.data.operation_id);
        // setLoading(false) happens via onDone
    };

    const handleDone = () => { setLoading(false); fetchStatuses(); };

    return (
        <div className="mt-8">
            <h3 className="text-lg font-semibold mb-3">DB Engine Services</h3>
            <table className="w-full text-sm ...">
                <thead>...</thead>
                <tbody>
                    {Object.entries(statuses).map(([engine, info]) => (
                        <tr key={engine}>
                            <td>{engine}</td>
                            <td>{info.service}</td>
                            <td>
                                <span className={info.active ? 'text-green-600' : 'text-red-600'}>
                                    {info.active ? 'active' : 'inactive'}
                                </span>
                            </td>
                            <td>
                                {['start', 'stop', 'restart'].map(action => (
                                    <button key={action}
                                        disabled={loading}
                                        onClick={() => doAction(engine, action)}
                                        className="..."
                                    >
                                        {action}
                                    </button>
                                ))}
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>
            {operationId && (
                <OperationProgress operationId={operationId} onDone={handleDone} />
            )}
        </div>
    );
}
```

### `resources/js/Pages/Databases/Index.jsx` (modify)

Import `DbServiceControl` and render it at the bottom of the page, guarded by `auth.user.role === 'admin'`:

```jsx
{auth.user.role === 'admin' && <DbServiceControl />}
```

No new nav item is needed — this feature is accessed from the existing "Databases" nav link, which is already in `SidebarNavi.jsx` with the `TbBrandMysql` icon.

## Data Model / Migrations

No new migrations. This feature adds no DB columns. The existing `operations` table captures the audit trail:

| Column | Value for this feature |
|---|---|
| `type` | `db.service.start` / `db.service.stop` / `db.service.restart` |
| `target` | `{engine}:{service}` e.g. `mysql:mysql` or `postgres:postgresql` |
| `user_id` | acting admin user |
| `status` | `queued` → `running` → `succeeded` / `failed` |
| `output` | systemctl output lines + error text |

`Operation` rows are pruned after 30 days by the existing `MassPrunable` + `schedule:run` setup (`model:prune --model=App\Models\Operation`).

## Privileged Scripts and Sudoers

### `laranode-db-service.sh` — full validation flow

```bash
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <start|stop|restart> <engine: mysql|mariadb|postgres>" >&2
    exit 1
fi

ACTION="$1"
ENGINE="$2"

# Guard against leading-dash flag injection
if [[ "$ACTION" == -* ]] || [[ "$ENGINE" == -* ]]; then
    echo "ERROR: invalid argument (leading dash)" >&2
    exit 1
fi

case "$ACTION" in
    start|stop|restart) ;;
    *) echo "ERROR: invalid action '$ACTION'" >&2; exit 1 ;;
esac

case "$ENGINE" in
    mysql)   SERVICE="mysql" ;;
    mariadb) SERVICE="mariadb" ;;
    postgres) SERVICE="postgresql" ;;
    *) echo "ERROR: unknown engine '$ENGINE'" >&2; exit 1 ;;
esac

echo "Running: systemctl $ACTION $SERVICE"
if ! systemctl "$ACTION" "$SERVICE"; then
    # For postgres, also try versioned unit (Ubuntu 24.04 default)
    if [[ "$ENGINE" == "postgres" ]]; then
        echo "Retrying with postgresql@16-main..."
        systemctl "$ACTION" "postgresql@16-main"
    else
        echo "ERROR: systemctl $ACTION $SERVICE failed" >&2
        exit 1
    fi
fi

echo "Done: systemctl $ACTION $SERVICE"
```

### Sudoers

Modify `laranode-scripts/etc/sudoers.d/laranode-panel` (two new lines, consistent with existing entries):

```
Defaults!/home/laranode_ln/panel/laranode-scripts/bin/laranode-db-service.sh !requiretty
www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-db-service.sh
```

`laranode-installer.sh` already deploys this file via `install -m 440` (lines 213-218). No installer change needed beyond the two new lines in the source file.

## How It Uses the OperationJob / EngineManager / Dashboard Stack

- **`OperationJob` base class** (`app/Jobs/OperationJob.php`): `DbServiceOperationJob` extends it. The base handles the full lifecycle: `markRunning()` → `run()` → `markFinished($exit)` → re-throw. No duplication.
- **`Operation::markRunning()` / `appendOutput()` / `markFinished()`**: each calls `\App\Events\OperationUpdated::dispatch($this, ...)` which broadcasts on `PrivateChannel('operations.' . $this->operation->user_id)`. The frontend `useOperation` hook (`resources/js/hooks/useOperation.js`) subscribes to this channel and feeds `OperationProgress`.
- **`EngineManager::available()`** (`app/Databases/EngineManager.php`): already used in `DatabasesController::index()`. `DbServiceStatusService` uses it to cheaply derive per-engine active status without duplicating the `systemctl is-active` logic.
- **`config('laranode.db_engines')`**: the PHP-side allowlist for `DbServiceRequest` comes directly from this config. The script's `case` statement is the defense-in-depth copy of the same allowlist.
- **Admin Operations page** (`/admin/operations`, `OperationsController::index()`): `Operation` rows with `type=db.service.*` render automatically in the existing paginated table — no code change needed.
- **`OperationProgress` component** (`resources/js/Components/OperationProgress.jsx`): already handles `onDone` via `useEffect` with `firedRef` fire-once guard. Used as-is.

## Security

1. **Admin-only gate**: `DbServiceRequest::authorize()` calls `$this->user()->isAdmin()`. Non-admin users get a 403 before any validation runs. The route also has `AdminMiddleware` as a belt-and-suspenders guard.

2. **Allowlist validation in PHP**: `Rule::in(array_keys(config('laranode.db_engines')))` and `Rule::in(['start','stop','restart'])` in `DbServiceRequest::rules()`. Laravel's `Rule::in` never passes through control characters, leading dashes, or arbitrary strings.

3. **Allowlist validation in the script**: `laranode-db-service.sh` independently validates both arguments against hardcoded `case` blocks. The script resolves the service name itself — PHP never passes a raw service name to the script. A compromised PHP layer that somehow bypassed FormRequest validation cannot inject an arbitrary service name.

4. **Leading-dash injection**: both PHP (`Rule::in` with a closed enum) and the script (`[[ "$ARG" == -* ]]` guard + `case`) reject arguments starting with `-`. This prevents `--foo` flag injection to `systemctl`.

5. **No arbitrary service control**: the script will never call `systemctl start sshd` or any other service not in the case block. The mapping from engine to service name lives in the script — PHP passes `mysql`, the script calls `mysql`.

6. **Queue worker isolation**: `DbServiceOperationJob` runs in the queue worker process (the `laranode-queue-worker.service` systemd unit), not in the web request. If the web process is compromised, the queue worker limits blast radius to the jobs it already processes.

7. **sudoers scope**: `www-data ALL=(ALL) NOPASSWD:` for the specific script path only — no wildcard on arbitrary commands.

8. **Audit trail**: every action creates an `Operation` row visible to all admins at `/admin/operations`, with `type`, `target`, `output`, and `started_at` / `finished_at` timestamps.

9. **Stop safety**: stopping a DB engine that has active panel connections will cause subsequent requests to fail until the service is restarted. This is expected and intentional for admin control — no additional guard is needed in v1. A future improvement could warn if active connections are detected.

## Testing Strategy

### Pest unit tests (`tests/Unit/DbServiceScriptTest.php`) — new

Table-driven tests for argument validation that the script enforces. Because these exercise the actual bash script, they are gated with `LARANODE_SYSTEM_TESTS=1`. For the non-system suite, the PHP-layer allowlist tests in `DbServiceRequestTest` provide coverage.

### Pest feature tests (`tests/Feature/Database/DbServiceControllerTest.php`) — new

All use `Process::fake()` to mock `systemctl` calls without a real Linux host.

- **Admin gate**: `POST /admin/databases/service` as non-admin → 403; `GET /admin/databases/service/status` as non-admin → 403.
- **Engine allowlist rejection**: `engine=invalid_engine` → 422; `engine=-mysql` (leading dash) → 422.
- **Action allowlist rejection**: `action=nuke` → 422; `action=--help` → 422.
- **Successful dispatch**: valid `{engine: 'mysql', action: 'restart'}` → 200 JSON with `operation_id`; `Operation` row exists with `type='db.service.restart'`, `target='mysql:mysql'`, `status='queued'`; job dispatched.
- **Status endpoint**: `GET /admin/databases/service/status` returns JSON with each configured engine and its `active` state (mocked via `Process::fake()` to return `"active\n"` for mysql).

### Pest feature tests (`tests/Feature/Database/DbServiceOperationJobTest.php`) — new

Uses `Process::fake()`:

- **Success path**: `DbServiceOperationJob::dispatchSync($op, 'mysql', 'mysql', 'restart')` → `$op->status === 'succeeded'`; `$op->output` contains "Running:" and "completed."; exit code 0.
- **Failure path**: `Process::fake()` returns exit code 1 → `$op->status === 'failed'`; job re-throws (recorded in failed_jobs).
- **Output capture**: `appendOutput` called with the captured stdout of the script.

### Pest system integration test (`tests/Feature/Database/DbServiceSystemTest.php`) — new

Gated with `LARANODE_SYSTEM_TESTS=1`. Runs inside the `local-dev` container against the real `laranode-db-service.sh` and real `systemctl`.

- **Test 1 (script allowlist)**: run `laranode-db-service.sh start invalid_engine`; assert exit non-zero.
- **Test 2 (leading dash)**: run `laranode-db-service.sh -p mysql`; assert exit non-zero.
- **Test 3 (restart mysql)**: `laranode-db-service.sh restart mysql`; assert exit 0; assert `systemctl is-active mysql` returns `active`.
- **Test 4 (status endpoint round-trip)**: hit `GET /admin/databases/service/status` as admin; assert `statuses.mysql.active === true`.

These run via `make test-system` (`LARANODE_SYSTEM_TESTS=1 php artisan test --filter=DbServiceSystemTest`).

### Vitest component tests (`resources/js/Pages/Databases/DbServiceControl.test.jsx`) — new

Uses React Testing Library + `vi.mock('axios')`:

- **Renders status table**: mock `axios.get` returning `{statuses: {mysql: {service:'mysql', active:true}}}` → asserts "mysql", "active" badge, and three buttons rendered.
- **Dispatches action**: mock `axios.post` returning `{operation_id: 42}` → click "Restart" button → assert `axios.post` called with `{engine:'mysql', action:'restart'}`; `OperationProgress` rendered with `operationId=42`.
- **Buttons disabled during operation**: after click, all buttons have `disabled` attribute until `onDone` fires.
- **Status refresh on done**: after `onDone` fires, `axios.get` is called again.
- **Inactive badge**: mock `active: false` → assert "inactive" badge with red class.

## Back-compat

- No changes to existing models (`User`, `Website`, `Database`, `Operation`).
- No new migrations.
- `Operation` rows with `type=db.service.*` render automatically in the `/admin/operations` page — no change to `OperationsController` or `Operations/Index.jsx`.
- `EngineManager::available()` is unchanged. `DbServiceStatusService` is an additive wrapper that delegates to it.
- Existing `/databases` resource routes are unchanged.
- The `DatabasesController::index()` method is unchanged. The `Databases/Index.jsx` modification adds `<DbServiceControl />` only for admin users — non-admins see no difference.
- The `laranode-cron` sudoers drop-in is a separate file and is unaffected.
- `laranode-scripts/etc/sudoers.d/laranode-panel` modifications are additive; the existing lines are preserved.
- No change to `bootstrap/app.php` scheduler or `withSchedule`.

## File Inventory

```
laranode-scripts/bin/laranode-db-service.sh                              (new)
laranode-scripts/etc/sudoers.d/laranode-panel                            (modify: +2 lines for db-service.sh)
app/Jobs/DbServiceOperationJob.php                                       (new, includes DbServiceException)
app/Services/Database/DbServiceStatusService.php                         (new)
app/Http/Controllers/DbServiceController.php                             (new)
app/Http/Requests/DbServiceRequest.php                                   (new)
routes/web.php                                                           (modify: +2 admin routes under /admin/databases/service)
resources/js/Pages/Databases/Index.jsx                                   (modify: render <DbServiceControl /> for admin)
resources/js/Pages/Databases/Partials/DbServiceControl.jsx               (new)
tests/Feature/Database/DbServiceControllerTest.php                       (new)
tests/Feature/Database/DbServiceOperationJobTest.php                     (new)
tests/Feature/Database/DbServiceSystemTest.php                           (new, LARANODE_SYSTEM_TESTS=1)
resources/js/Pages/Databases/DbServiceControl.test.jsx                  (new, Vitest)
```

No new migrations, no new models, no new nav links, no new Eloquent relations.

## Open Questions

1. **Stop safety warning**: should the UI warn the admin before stopping a service if databases with active panel connections exist? Querying `Database::where('engine', $engine)->count()` would tell us how many panel databases use that engine, but not whether they have live connections. Is a client-side "Are you sure you want to stop MySQL? You have N databases using it." confirmation modal sufficient in v1, or skip entirely?

2. **Postgres versioned unit (postgresql@16-main)**: the retry logic in the script handles the most common case (Ubuntu 24.04 with PostgreSQL 16), but a future install of PG 17 would need `postgresql@17-main`. Should the script try a wider pattern (`systemctl list-units --type=service | grep postgresql@`) or is the hardcoded fallback to `@16-main` acceptable until PG 17 support is explicitly added? `EngineManager` has a separate `$extraCandidates` array for this — the script could accept an optional third arg `<service-override>` to avoid divergence, but that changes the interface.

3. **Job queue**: `DbServiceOperationJob` will run on the default queue (`QUEUE_CONNECTION=database`, `laranode-queue-worker.service`). Should it run on a dedicated `db-service` queue so a slow restart does not block backup or SSL jobs? The queue worker currently processes one queue with no priority.

4. **MariaDB vs MySQL coexistence**: both `mysql` and `mariadb` services can be listed in `config('laranode.db_engines')`, but on most installs only one is active. Should the UI hide Start/Stop buttons for engines where the service is not installed at all (i.e., `systemctl is-active` returns `inactive` vs. `Unit not found`)? Currently `EngineManager::available()` only lists engines whose service is `active`; `DbServiceStatusService` lists all configured engines regardless. This could show buttons for engines not installed on the host.

5. **Restart vs reload**: for MySQL and MariaDB, `systemctl reload` applies config changes without dropping connections. Should a "Reload" action be added alongside "Restart"? PostgreSQL uses `pg_ctl reload`. Deferring to v2 is reasonable; it would just require one more allowed action string and script branch.

6. **Non-admin visibility**: regular users currently see the Databases page with their own databases. They do not need to see engine service status. The current design hides `DbServiceControl` entirely from non-admins — is this the right UX, or should non-admins see a read-only status badge per engine (no action buttons)?
