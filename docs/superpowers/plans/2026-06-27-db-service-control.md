# DB Service Control — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let panel admins start, stop, or restart any configured DB engine service from the Databases page. A new `laranode-db-service.sh` maps an engine key to a systemd service name and calls `systemctl <action> <service>`. Because `systemctl restart` can take 3–8 s, the action runs as an `OperationJob` (same pattern as `GenerateSslOperationJob` and `BackupJob`), returning an `operation_id` immediately so `OperationProgress` can stream live output via Reverb. No new migrations; the existing `operations` table carries the audit trail.

**Architecture:** `POST /admin/databases/service` → `DbServiceRequest` (admin gate + allowlist) → `Operation::create` → `DbServiceOperationJob::dispatch` → JSON `{operation_id}` → `laranode-db-service.sh` via `Process::run` → `Operation` lifecycle (markRunning / appendOutput / markFinished) → `OperationUpdated` broadcast → `OperationProgress` UI. Read-only status comes from `DbServiceStatusService` (delegates to `EngineManager::available()`).

**Key constraints:**
- Admin-only: `DbServiceRequest::authorize()` + `AdminMiddleware` on the route group.
- Engine validated against `array_keys(config('laranode.db_engines'))` in PHP and against a hardcoded `case` block in the script — PHP never passes a raw service name to the script.
- Action allowlist is exactly `['start', 'stop', 'restart']`.
- Script validates both args (leading-dash guard + `case` blocks) before touching systemd.
- `DbServiceOperationJob` extends `OperationJob` (abstract base in `app/Jobs/OperationJob.php`); no lifecycle duplication.
- No new migrations; no new models; no changes to `EngineManager`, `DatabasesController`, or existing routes.
- `SidebarNavi.jsx` is **not** modified — "Databases" nav link already exists.
- `laranode-scripts/etc/sudoers.d/laranode-panel` gains two lines; `entrypoint-setup.sh` is unchanged (wildcard `*.sh` grant already covers the new script).

**Tech stack:** Laravel 12, Pest 3, Inertia + React (JSX), `Process` facade, MySQL (prod) / SQLite `:memory:` (tests), Reverb.
**Branch:** `feature/db-service-control` (off `development`).
**Suite:** `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test'` (PowerShell for `make`/`docker compose`; any shell for `docker exec`).

---

> **Execution order:** Task 1 → Task 2 → Task 3 → Task 4 → Task 5 → Task 6. Each task depends on the previous.

---

### Task 1: `laranode-db-service.sh` + sudoers drop-in

**TDD: Write the system-test scaffold first (skipped without flag), then the script.**

**Files:**
- Create: `laranode-scripts/bin/laranode-db-service.sh`
- Modify: `laranode-scripts/etc/sudoers.d/laranode-panel` (add two lines)
- Create: `tests/Feature/Database/DbServiceSystemTest.php` (gated `LARANODE_SYSTEM_TESTS=1`)

**Acceptance criteria for `laranode-db-service.sh`:**
- `set -euo pipefail` at top; `chmod +x` set.
- Accepts exactly two positional args: `<action>` and `<engine>`. Exits 1 with usage message on wrong arg count.
- Leading-dash guard on both args: `[[ "$ACTION" == -* ]]` or `[[ "$ENGINE" == -* ]]` → exit 1.
- `$ACTION` validated via `case` block: `start|stop|restart` pass; anything else exits 1 with "ERROR: invalid action".
- `$ENGINE` validated via `case` block: `mysql → SERVICE=mysql`, `mariadb → SERVICE=mariadb`, `postgres → SERVICE=postgresql`; anything else exits 1 with "ERROR: unknown engine".
- For `postgres`: on `systemctl "$ACTION" postgresql` non-zero exit, retries with `postgresql@16-main`; if retry also fails, exits non-zero. All other engines fail immediately on `systemctl` non-zero exit.
- Output goes to stdout (captured by `appendOutput`). Prints `"Running: systemctl $ACTION $SERVICE"` before the call and `"Done: systemctl $ACTION $SERVICE"` on success.

**Acceptance criteria for sudoers (modify `laranode-scripts/etc/sudoers.d/laranode-panel`):**
- Add exactly two lines in the same pattern as existing entries:
  ```
  Defaults!/home/laranode_ln/panel/laranode-scripts/bin/laranode-db-service.sh !requiretty
  www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-db-service.sh
  ```
- Existing lines are preserved verbatim. File remains mode 0440.
- `laranode-installer.sh` already deploys this file via `install -m 440` — no installer change needed.
- `local-dev/entrypoint-setup.sh` wildcard `$BIN/*.sh` grant already covers the new script — no entrypoint change needed.

**Acceptance criteria for `DbServiceSystemTest.php`:**
- Gated: `if (!env('LARANODE_SYSTEM_TESTS')) $this->markTestSkipped('requires LARANODE_SYSTEM_TESTS=1');` at top of each test or in `beforeEach`.
- Test 1 (invalid engine): `laranode-db-service.sh start invalid_engine` → exit non-zero.
- Test 2 (leading-dash action): `laranode-db-service.sh -p mysql` → exit non-zero.
- Test 3 (leading-dash engine): `laranode-db-service.sh restart -mysql` → exit non-zero.
- Test 4 (restart mysql): `laranode-db-service.sh restart mysql` → exit 0; `systemctl is-active mysql` returns `active`.
- Test 5 (status round-trip): `GET /admin/databases/service/status` as admin → `statuses.mysql.active === true` in JSON response. (Can be done here or in Task 3's controller test — mark it pending until Task 3 is done.)
- Standard suite (no flag): 4 tests marked skipped, zero failures.
- System suite: `LARANODE_SYSTEM_TESTS=1 php artisan test --filter=DbServiceSystemTest` → all passing inside container.

- [ ] Write `DbServiceSystemTest.php` scaffold (tests skipped without flag)
- [ ] Write `laranode-db-service.sh` with arg validation and postgres retry logic
- [ ] Modify `laranode-scripts/etc/sudoers.d/laranode-panel` (+2 lines)
- [ ] Run standard suite: all green (system tests skipped)
- [ ] Commit: `feat(db-service): laranode-db-service.sh + sudoers entry`

---

### Task 2: `DbServiceRequest` — admin gate + allowlist validation

**TDD: Write the failing feature test first, then the FormRequest.**

**Files:**
- Create: `app/Http/Requests/DbServiceRequest.php`
- Create: `tests/Feature/Database/DbServiceRequestTest.php`

**Acceptance criteria for `DbServiceRequest`:**
- `authorize()`: returns `$this->user()?->isAdmin() ?? false`. Returns `false` for non-admins → 403 before `rules()` runs.
- `rules()`:
  - `engine`: `['required', 'string', Rule::in(array_keys(config('laranode.db_engines', [])))]`
  - `action`: `['required', 'string', Rule::in(['start', 'stop', 'restart'])]`
- No `withValidator()` hook; no cap check (admin-only, unlimited use).
- `Rule::in` with a closed enum implicitly rejects leading dashes, control chars, and arbitrary strings — no additional regex needed.

**Acceptance criteria for `DbServiceRequestTest.php` (all use `Process::fake()`):**
- Security: Non-admin POST → 403 (authorize() fires before rules()).
- Engine allowlist: `engine=invalid_engine` → 422.
- Engine leading-dash: `engine=-mysql` → 422.
- Action allowlist: `action=nuke` → 422.
- Action leading-dash: `action=--help` → 422.
- Valid payload `{engine: 'mysql', action: 'restart'}` as admin → not 403/422 (will be 200 once controller exists; at this stage test that authorize() + rules() pass by asserting the request validates without errors, or mock the controller).
- Test using `$this->postJson('/admin/databases/service', [...])` as non-admin → 403.
- Test layer: **Pest feature** (no real Linux required; `Process::fake()` not needed for pure validation tests — no Process calls happen in FormRequest).

- [ ] Write failing `DbServiceRequestTest.php`
- [ ] Write `DbServiceRequest`
- [ ] Verify tests pass
- [ ] Run Pint on new PHP
- [ ] Commit: `feat(db-service): DbServiceRequest (admin gate + engine/action allowlist)`

---

### Task 3: `DbServiceStatusService` + `DbServiceController` + routes + Pest feature tests

**TDD: Write failing controller tests first, then service + controller.**

**Files:**
- Create: `app/Services/Database/DbServiceStatusService.php`
- Create: `app/Http/Controllers/DbServiceController.php`
- Modify: `routes/web.php` (add two routes under admin middleware group)
- Create: `tests/Feature/Database/DbServiceControllerTest.php`

**Acceptance criteria for `DbServiceStatusService`:**
- Constructor: `public function __construct(private EngineManager $engineManager) {}`
- `handle()`: iterates `config('laranode.db_engines', [])` and calls `$this->engineManager->available()` (already memoized). Returns `array<string, array{service: string, active: bool}>` keyed by engine key.
- Read-only; no `Process::run` call in this class — that is inside `EngineManager::available()`.

**Acceptance criteria for `DbServiceController`:**
- Constructor: `public function __construct(private EngineManager $engineManager) {}`
- `action(DbServiceRequest $request): JsonResponse`:
  - Reads `$validated['engine']` and `$validated['action']`.
  - Resolves service: `$service = config('laranode.db_engines')[$engine]['service']` (PHP-side secondary validation; engine is already allowlist-validated by FormRequest).
  - Creates `Operation::create(['user_id' => $request->user()->id, 'type' => "db.service.{$action}", 'target' => "{$engine}:{$service}", 'status' => 'queued'])`.
  - Dispatches `DbServiceOperationJob::dispatch($operation, $engine, $service, $action)`.
  - Returns `response()->json(['operation_id' => $operation->id])`.
  - Does NOT call `markRunning()` — that is `OperationJob::handle()`'s responsibility.
- `status(): JsonResponse`:
  - Calls `(new DbServiceStatusService($this->engineManager))->handle()`.
  - Returns `response()->json(['statuses' => $statuses])`.

**Acceptance criteria for routes (modify `routes/web.php`):**
- Add inside a new `Route::middleware(['auth', AdminMiddleware::class])->group(...)` block (consistent with `firewall.*` and `operations.index` pattern):
  ```php
  Route::post('/admin/databases/service', [DbServiceController::class, 'action'])
      ->name('databases.service.action');
  Route::get('/admin/databases/service/status', [DbServiceController::class, 'status'])
      ->name('databases.service.status');
  ```
- Import `App\Http\Controllers\DbServiceController` at top of `routes/web.php`.
- Existing `/databases` resource routes are untouched.

**Acceptance criteria for `DbServiceControllerTest.php` (all use `Process::fake()` and mock `EngineManager`):**
- Admin gate on `action`: non-admin `POST /admin/databases/service` → 403.
- Admin gate on `status`: non-admin `GET /admin/databases/service/status` → 403.
- Engine allowlist rejection: admin, `engine=invalid_engine` → 422.
- Engine leading-dash rejection: admin, `engine=-mysql` → 422.
- Action allowlist rejection: admin, `action=nuke` → 422.
- Successful dispatch: admin, `{engine: 'mysql', action: 'restart'}` → 200 JSON `{operation_id: <int>}`; `Operation` row exists with `type='db.service.restart'`, `target='mysql:mysql'`, `status='queued'`; `DbServiceOperationJob` dispatched (assert via `Queue::fake()` / `Bus::fake()`).
- Status endpoint: `GET /admin/databases/service/status` as admin → 200 JSON `{statuses: {mysql: {service: 'mysql', active: true}}}` (mock `EngineManager::available()` to return `['mysql' => 'mysql']`).
- Status endpoint unauthenticated → 302 to login.
- Test layer: **Pest feature** (mocked `EngineManager` via `app()->instance(EngineManager::class, $mock)` — same pattern as `DatabasesControllerTest.php`).

- [ ] Write failing `DbServiceControllerTest.php`
- [ ] Write `DbServiceStatusService`
- [ ] Write `DbServiceController`
- [ ] Add routes to `routes/web.php`
- [ ] Verify tests pass
- [ ] Run Pint on new PHP
- [ ] Commit: `feat(db-service): DbServiceStatusService + DbServiceController + routes`

---

### Task 4: `DbServiceOperationJob` + job-level Pest tests

**TDD: Write failing job tests first, then the job class.**

**Files:**
- Create: `app/Jobs/DbServiceOperationJob.php` (includes `DbServiceException` in same file)
- Create: `tests/Feature/Database/DbServiceOperationJobTest.php`

**Acceptance criteria for `DbServiceOperationJob`:**
- Extends `OperationJob` (from `app/Jobs/OperationJob.php`).
- Constructor:
  ```php
  public function __construct(
      Operation $operation,
      public string $engine,
      public string $service,
      public string $action,
  ) {
      parent::__construct($operation);
  }
  ```
- `protected function run(callable $emit): int`:
  - `$emit("Running: systemctl {$this->action} {$this->service}...");`
  - `$result = Process::run(['sudo', config('laranode.laranode_bin_path') . '/laranode-db-service.sh', $this->action, $this->engine]);`
  - `$emit($result->output());`
  - If `$result->failed()`: `throw new DbServiceException($result->errorOutput());`
  - `$emit("systemctl {$this->action} {$this->service} completed.");`
  - `return 0;`
- PHP never passes `$this->service` (the raw service name) to the script; only `$this->action` and `$this->engine` are passed. The script resolves the service name itself.
- `DbServiceException extends \Exception {}` declared in the same file.
- The `OperationJob` base `handle()` method calls `markRunning()`, invokes `run()`, calls `markFinished($exit)`, and re-throws any `\Throwable`. No duplication in the subclass.

**Acceptance criteria for `DbServiceOperationJobTest.php`:**
- Success path: `Process::fake(['*' => Process::result(output: "Running...\nDone.", exitCode: 0)])`; `DbServiceOperationJob::dispatchSync($op, 'mysql', 'mysql', 'restart')` → `$op->fresh()->status === 'succeeded'`; `$op->fresh()->output` contains "Running:" and "completed."; exit code 0 in DB.
- Failure path: `Process::fake(['*' => Process::result(output: '', errorOutput: 'Unit mysql not found', exitCode: 1)])`; `dispatchSync(...)` throws `DbServiceException`; `$op->fresh()->status === 'failed'`; output contains "ERROR: Unit mysql not found".
- Output capture: verify `appendOutput` is called with the captured stdout of the script (assert `$op->fresh()->output` contains the faked output string).
- Correct args to `Process::run`: `Process::fake()` with an assertion that the command array contains `'laranode-db-service.sh'`, `'restart'`, and `'mysql'` (engine, not service name).
- Test layer: **Pest feature** (uses `Process::fake()` + `RefreshDatabase`).

- [ ] Write failing `DbServiceOperationJobTest.php`
- [ ] Write `DbServiceOperationJob` + `DbServiceException`
- [ ] Verify tests pass
- [ ] Run Pint on new PHP
- [ ] Commit: `feat(db-service): DbServiceOperationJob (extends OperationJob) + DbServiceException`

---

### Task 5: React UI — `DbServiceControl.jsx` + `Databases/Index.jsx` modification + Vitest

**TDD: Write failing Vitest tests first, then the component.**

**Files:**
- Create: `resources/js/Pages/Databases/Partials/DbServiceControl.jsx`
- Create: `resources/js/Pages/Databases/DbServiceControl.test.jsx`
- Modify: `resources/js/Pages/Databases/Index.jsx` (add admin-only `<DbServiceControl />`)

**Acceptance criteria for `DbServiceControl.jsx`:**
- Imports: `useState`, `useEffect` from React; `axios`; `OperationProgress` from `@/Components/OperationProgress`.
- State: `statuses` (object, default `{}`), `operationId` (null), `loading` (false).
- On mount: `axios.get(route('databases.service.status'))` → `setStatuses(r.data.statuses ?? {})`.
- Renders a table with one row per engine in `statuses`: columns Engine, Service, Status (green "active" / red "inactive" badge), and buttons "Start", "Stop", "Restart".
- Button `onClick`: calls `axios.post(route('databases.service.action'), { engine, action })` → sets `operationId` from `r.data.operation_id`; sets `loading = true`. `loading` is cleared via `onDone`.
- All action buttons have `disabled={loading}` while an operation is in flight.
- Renders `<OperationProgress operationId={operationId} onDone={handleDone} />` below the table when `operationId` is non-null.
- `handleDone`: `setLoading(false); fetchStatuses();` — re-fetches status on completion to refresh active badges.
- Component is self-contained; no new nav link needed.

**Acceptance criteria for `DbServiceControl.test.jsx` (Vitest + RTL + `vi.mock('axios')`):**
- Renders status table: mock `axios.get` returns `{statuses: {mysql: {service:'mysql', active:true}}}` → asserts "mysql", "active" text, and three buttons ("start", "stop", "restart") are in the document.
- Active badge: `active: true` → element with green class present; `active: false` → "inactive" text with red class.
- Dispatches action: mock `axios.post` returns `{operation_id: 42}` → click "restart" button → assert `axios.post` called with `{engine:'mysql', action:'restart'}`; `OperationProgress` rendered with `operationId=42` (mock `OperationProgress` via `vi.mock` or assert its props).
- Buttons disabled during operation: after click (before `onDone`), all three buttons have `disabled` attribute.
- Status refresh on done: after `onDone` fires, `axios.get` is called a second time.
- Mock `OperationProgress` as a simple stub (`vi.mock('@/Components/OperationProgress', () => ({ default: ({ operationId }) => <div data-testid="op-progress">{operationId}</div> }))`).
- Mock `route()` global: `global.route = (name) => ({ 'databases.service.status': '/admin/databases/service/status', 'databases.service.action': '/admin/databases/service' }[name])`.

**Acceptance criteria for `Databases/Index.jsx` modification:**
- Import `DbServiceControl` at top: `import DbServiceControl from './Partials/DbServiceControl';`
- Add inside the return, after the database table and before `<Tooltip />`:
  ```jsx
  {auth.user.role === 'admin' && <DbServiceControl />}
  ```
- Non-admins see no change. The existing `const { auth } = usePage().props;` is already present in the component.
- No other changes to `Index.jsx`.

**Build check:** `npm run build` succeeds with no import errors.

- [ ] Write failing `DbServiceControl.test.jsx`
- [ ] Write `DbServiceControl.jsx`
- [ ] Modify `resources/js/Pages/Databases/Index.jsx`
- [ ] Verify Vitest tests pass (`npm run test`)
- [ ] Build assets (`npm run build`)
- [ ] Commit: `feat(db-service): DbServiceControl component + Databases/Index admin section + Vitest`

---

### Task 6: System integration test + final verification gate

**Files:**
- Modify: `tests/Feature/Database/DbServiceSystemTest.php` (complete Test 5 from Task 1 scaffold once routes exist)

**Acceptance criteria for completed system test suite:**
- All 5 system tests pass inside the `local-dev` container under `LARANODE_SYSTEM_TESTS=1`:
  - Test 1: `laranode-db-service.sh start invalid_engine` → exit non-zero.
  - Test 2: `laranode-db-service.sh -p mysql` → exit non-zero.
  - Test 3: `laranode-db-service.sh restart -mysql` → exit non-zero.
  - Test 4: `laranode-db-service.sh restart mysql` → exit 0; `systemctl is-active mysql` returns `active`.
  - Test 5: `GET /admin/databases/service/status` as admin → `statuses.mysql.active === true`.
- Standard suite (no flag): all system tests marked skipped, zero failures.

**Final verification gate — all of the following must pass before the branch is considered done:**

1. **Pest standard suite** (no system flag):
   - `php artisan test` → zero failures; `DbServiceSystem*` tests marked skipped.
   - New test files: `DbServiceControllerTest`, `DbServiceOperationJobTest`, `DbServiceRequestTest`, `DbServiceSystemTest`.

2. **Pest system suite** (inside `local-dev` container):
   - `LARANODE_SYSTEM_TESTS=1 php artisan test --filter=DbServiceSystemTest` → 5 passing.

3. **Vitest**:
   - `npm run test` → `DbServiceControl.test.jsx` all green; existing `CreateDatabaseForm.test.jsx` still green.

4. **Pint**:
   - `./vendor/bin/pint --test` → zero violations on all new PHP files.

5. **Asset build**:
   - `npm run build` → exits 0; no import errors.

6. **Scheduler unchanged**:
   - `php artisan schedule:list` still shows `model:prune --model=App\Models\Operation` daily entry and nothing new.

7. **Operations page**:
   - `GET /admin/operations` renders rows with `type=db.service.*` automatically — no `OperationsController` change needed.

8. **Back-compat check**:
   - Non-admin `GET /databases` → 200, unchanged behavior, no `DbServiceControl` visible.
   - `GET /mysql` (back-compat alias) → 200, unchanged.

- [ ] Complete `DbServiceSystemTest.php` Test 5 (status endpoint round-trip)
- [ ] Run standard Pest suite: zero failures
- [ ] Run system Pest suite inside container: 5 passing
- [ ] Run Vitest: all green
- [ ] Run Pint: zero violations
- [ ] Run `npm run build`: exits 0
- [ ] Verify `php artisan schedule:list` unchanged
- [ ] Commit: `test(db-service): system integration test + final verification gate`

---

## File Inventory

```
laranode-scripts/bin/laranode-db-service.sh                              (new)
laranode-scripts/etc/sudoers.d/laranode-panel                            (modify: +2 lines)
app/Jobs/DbServiceOperationJob.php                                       (new, includes DbServiceException)
app/Services/Database/DbServiceStatusService.php                         (new)
app/Http/Controllers/DbServiceController.php                             (new)
app/Http/Requests/DbServiceRequest.php                                   (new)
routes/web.php                                                           (modify: +2 admin routes + DbServiceController import)
resources/js/Pages/Databases/Index.jsx                                   (modify: admin-only <DbServiceControl />)
resources/js/Pages/Databases/Partials/DbServiceControl.jsx               (new)
tests/Feature/Database/DbServiceControllerTest.php                       (new — Pest feature)
tests/Feature/Database/DbServiceOperationJobTest.php                     (new — Pest feature)
tests/Feature/Database/DbServiceRequestTest.php                          (new — Pest feature)
tests/Feature/Database/DbServiceSystemTest.php                           (new — Pest, LARANODE_SYSTEM_TESTS=1)
resources/js/Pages/Databases/DbServiceControl.test.jsx                  (new — Vitest)
```

No new migrations, no new models, no new nav items, no new Eloquent relations, no changes to `EngineManager`, `DatabasesController`, `OperationsController`, `Operations/Index.jsx`, `SidebarNavi.jsx`, or `local-dev/entrypoint-setup.sh`.

---

## Back-compat / Notes

- `Operation` rows with `type=db.service.*` render automatically in `/admin/operations` via the existing generic paginated table — no `OperationsController` change.
- `bootstrap/app.php` scheduler hook and `laranode-queue-worker.service` are unchanged; `DbServiceOperationJob` runs on the default queue.
- `laranode-scripts/etc/sudoers.d/laranode-panel` is deployed by `laranode-installer.sh` via `install -m 440` (existing mechanism); the two new lines require a re-run of the installer or manual `install` on upgrade.
- Existing `laranode-cron` sudoers drop-in is a separate file; unaffected.
- `EngineManager::extraCandidates` (`postgres => ['postgresql@16-main']`) is the PHP-layer detection strategy; the script's postgres retry mirrors it independently as a defense-in-depth copy of the same knowledge.
