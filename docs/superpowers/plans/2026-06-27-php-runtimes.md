# PHP Runtimes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each website a per-site PHP runtime choice. Today every site runs under a PHP-FPM Unix-socket pool managed by `AddVhostEntryService` + `laranode-add-vhost.sh`. This feature adds FrankenPHP as a v1 alternative runtime: a persistent app server on a loopback TCP port (9100–9499), proxied by Apache via `mod_proxy` + `mod_proxy_http`. Switching a site's runtime is an async `OperationJob` that broadcasts live output via `OperationUpdated` (same pattern as `GenerateSslOperationJob` / `toggleSsl`).

**Architecture:** `WebsiteController::switchRuntime()` (thin) → `SwitchRuntimeRequest` (FormRequest, enum validation) → `Operation::create()` + `SwitchRuntimeOperationJob::dispatch()` (async) → `SwitchRuntimeService::handle()` (orchestration, calls sub-services + scripts) → `laranode-runtime-install.sh` / `laranode-runtime-manage.sh` / `laranode-vhost-switch.sh` (privileged scripts, argument-validated).

**Key constraints:**
- `websites.runtime` (`php-fpm` | `frankenphp`; `swoole` is v2). Default `php-fpm`. `websites.runtime_port` nullable, set on non-FPM runtimes, cleared on revert.
- Port range 9100–9499. Allocated by `PortAllocatorService` (reads live `runtime_port` values, finds first gap). No DB unique constraint in v1 (documented concurrency risk).
- Three new privileged scripts (`laranode-runtime-install.sh`, `laranode-runtime-manage.sh`, `laranode-vhost-switch.sh`) each with `set -euo pipefail`, hard argument-count checks, regex validation rejecting leading-dash and control characters, and minimum run-as scope.
- New sudoers drop-in: `laranode-scripts/etc/sudoers.d/laranode-runtimes` (three scripts, `(ALL)` run-as required for system-path writes + systemd control; same pattern as existing `laranode-panel` drop-in).
- `DeleteWebsiteService` must gain `teardownRuntime()` — this is a **required** v1 addition (not deferred).
- `UpdateWebsitePHPVersionService` must reject non-FPM sites with 422.
- `SwitchRuntimeOperationJob` extends `app/Jobs/OperationJob.php` exactly as `GenerateSslOperationJob` does.
- No changes to `OperationJob`, `OperationUpdated`, `useOperation`, or `OperationProgress`.
- Frontend: mirrors `sslOp` pattern in `resources/js/Pages/Websites/Index.jsx` — new `runtimeOp` state + `OperationProgress` widget + Runtime column with `<select>`.

**Tech stack:** Laravel 12, Pest 3, Inertia + React (JSX, not TS), `Process` facade, MySQL (prod) / SQLite `:memory:` (tests).
**Branch:** `feature/php-runtimes` (off `development`).
**Suite:** `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test'` (PowerShell for `make`/`docker compose`; any shell for `docker exec`).

---

> **Execution order:** Task 1 → Task 2 → Task 3 → Task 4 → Task 5 → Task 6 → Task 7 → Task 8 → Task 9 → Task 10 (final gate). Each task depends on the previous.

---

### Task 1 (TDD): Migration + `Website` model changes

**Files:**
- Create: `database/migrations/2026_06_27_000002_add_runtime_to_websites_table.php`
- Modify: `app/Models/Website.php`
- Create: `tests/Feature/Websites/WebsiteRuntimeModelTest.php`

**Scope:**
- Migration: `Schema::table('websites', ...)` adding `runtime` (`string(20)`, default `'php-fpm'`, after `php_version_id`) and `runtime_port` (`unsignedSmallInteger`, nullable, after `runtime`). No data migration needed — existing rows default to `php-fpm` / null.
- `Website::$fillable`: append `'runtime'`, `'runtime_port'`.
- `Website::$casts`: append `'runtime_port' => 'integer'`.
- Add `getRuntimeLabelAttribute(): string` accessor using `match($this->runtime)` → `'FrankenPHP'` | `'Swoole (Octane)'` | `'PHP-FPM'`. Declared via the `$appends` array or accessed directly (not auto-appended to avoid breaking existing Inertia serialisation — verify before appending).

**Acceptance criteria:**
- `php artisan migrate --pretend` shows two `alter table` operations, no errors.
- Test: a `Website` factory row without `runtime` set → `$website->runtime === 'php-fpm'`, `$website->runtime_port === null`.
- Test: `$website->runtime = 'frankenphp'; $website->runtime_label` → `'FrankenPHP'`.
- Test: `$website->runtime = 'swoole'; $website->runtime_label` → `'Swoole (Octane)'`.
- Test: existing `Website` factory rows (from other test files) continue to pass — no column-not-found errors.
- `php artisan test --filter=WebsiteRuntimeModelTest` → green.

- [ ] Write failing model test
- [ ] Write migration
- [ ] Modify `Website` model (`$fillable`, `$casts`, accessor)
- [ ] Run `php artisan migrate` in container (or `RefreshDatabase` picks it up in tests)
- [ ] Verify test passes
- [ ] Run Pint on modified PHP
- [ ] Commit: `feat(runtimes): add runtime + runtime_port columns to websites table`

---

### Task 2 (TDD): `PortAllocatorService` + unit tests

**Files:**
- Create: `app/Services/Websites/PortAllocatorService.php`
- Create: `tests/Unit/PortAllocatorServiceTest.php`

**Scope:**
- `PortAllocatorService::allocate(Website $excludeWebsite): int` — queries `Website::whereNotNull('runtime_port')->where('id', '!=', $excludeWebsite->id)->pluck('runtime_port')->toArray()`; iterates 9100–9499 and returns the first port not in `$used`; throws `\RuntimeException('No available runtime ports in range 9100–9499.')` if exhausted.
- No lock in v1 (documented concurrency risk per spec open question 6).

**Acceptance criteria:**
- Test: no other websites → `allocate()` returns `9100`.
- Test: website with `runtime_port=9100` exists (different `id`) → returns `9101`.
- Test: all ports 9100–9499 occupied by other websites → throws `\RuntimeException`.
- Test: `$excludeWebsite` own `runtime_port` (same `id`) is excluded from the used set → does not block self re-allocation.
- `php artisan test --filter=PortAllocatorServiceTest` → green.

- [ ] Write failing unit test (table-driven dataset)
- [ ] Write `PortAllocatorService`
- [ ] Verify test passes
- [ ] Run Pint
- [ ] Commit: `feat(runtimes): PortAllocatorService (9100–9499, first-gap allocation)`

---

### Task 3 (TDD): `SwitchRuntimeRequest` + request validation unit tests

**Files:**
- Create: `app/Http/Requests/SwitchRuntimeRequest.php`
- Create: `tests/Unit/SwitchRuntimeRequestTest.php`

**Scope:**
- `SwitchRuntimeRequest::rules()`: `'runtime' => ['required', 'string', Rule::in(['php-fpm', 'frankenphp'])]`. (`swoole` deferred to v2, intentionally absent.)
- `SwitchRuntimeRequest::authorize()`: `return auth()->check();` — ownership gated by `Gate::authorize('update', $website)` in the controller.

**Acceptance criteria:**
- Test: `runtime=php-fpm` → passes validation.
- Test: `runtime=frankenphp` → passes validation.
- Test: `runtime=swoole` → fails (not in v1 allowlist), 422.
- Test: `runtime=` (empty) → fails, 422.
- Test: `runtime` key missing → fails, 422.
- Test: `runtime=../etc/passwd` → fails, 422.
- Test: `runtime=; rm -rf /` → fails, 422.
- `php artisan test --filter=SwitchRuntimeRequestTest` → green.

- [ ] Write failing validation tests
- [ ] Write `SwitchRuntimeRequest`
- [ ] Verify tests pass
- [ ] Run Pint
- [ ] Commit: `feat(runtimes): SwitchRuntimeRequest (php-fpm + frankenphp only in v1)`

---

### Task 4: Privileged scripts + sudoers drop-in + installer/entrypoint changes

**Files:**
- Create: `laranode-scripts/bin/laranode-runtime-install.sh`
- Create: `laranode-scripts/bin/laranode-runtime-manage.sh`
- Create: `laranode-scripts/bin/laranode-vhost-switch.sh`
- Create: `laranode-scripts/etc/sudoers.d/laranode-runtimes`
- Modify: `laranode-scripts/bin/laranode-installer.sh`
- Modify: `local-dev/entrypoint-setup.sh`

**Scope of each script:**

`laranode-runtime-install.sh <runtime>`:
- `set -euo pipefail`. Arg count: exactly 1. `$1` must match `^(frankenphp|swoole)$`; any other value → `exit 1` immediately.
- `frankenphp` branch: if `/usr/local/bin/frankenphp` exists and `frankenphp --version` exits 0 → skip (idempotent). Otherwise download pinned release binary from GitHub to `/usr/local/bin/frankenphp`, `chmod 0755`, verify `frankenphp --version` exits 0.
- No leading-dash or control-character check needed beyond the enum regex (the runtime arg is the only user-controlled value).

`laranode-runtime-manage.sh <action> <unit-name>`:
- `set -euo pipefail`. Arg count: exactly 2.
- `$1` (action) must match `^(enable|disable|start|stop|restart|status)$`; else `exit 1`.
- `$2` (unit name) must match `^laranode-(frankenphp|swoole)-[a-zA-Z0-9._-]+\.service$`; else `exit 1`. This blocks arbitrary unit names (`sshd.service`, `../../etc/...`).
- Executes: `systemctl "$ACTION" "$UNIT"`.

`laranode-vhost-switch.sh <domain> <runtime> <port> <system_user> <php_version> <document_root> <template_dir>`:
- `set -euo pipefail`. Arg count: exactly 7.
- Validate `$1` (domain): `^[a-zA-Z0-9.-]+$`, no leading dash.
- Validate `$2` (runtime): `^(php-fpm|frankenphp|swoole)$`.
- Validate `$3` (port): `^[0-9]+$`, numeric range 9100–9499 (check: `[ "$PORT" -ge 9100 ] && [ "$PORT" -le 9499 ]`). Port check is skipped (or any value accepted) when runtime is `php-fpm`.
- Validate `$4` (system_user): must end in `_ln` (`[[ "$4" == *_ln ]]`).
- Selects `apache-vhost-frankenphp.template` for `frankenphp`, `apache-vhost.template` for `php-fpm`. Performs placeholder substitution and writes `/etc/apache2/sites-available/{domain}.conf`. Runs `a2ensite {domain}` and `apache2ctl graceful`.
- Also writes the systemd unit file from `laranode-frankenphp.service.template` into `/etc/systemd/system/laranode-frankenphp-{domain}.service` when runtime is `frankenphp`, then runs `systemctl daemon-reload`.

`laranode-scripts/etc/sudoers.d/laranode-runtimes`:
```
Defaults!/home/laranode_ln/panel/laranode-scripts/bin/laranode-runtime-install.sh !requiretty
Defaults!/home/laranode_ln/panel/laranode-scripts/bin/laranode-runtime-manage.sh !requiretty
Defaults!/home/laranode_ln/panel/laranode-scripts/bin/laranode-vhost-switch.sh !requiretty

www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-runtime-install.sh
www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-runtime-manage.sh
www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-vhost-switch.sh
```
`(ALL)` run-as is required: install writes to `/usr/local/bin`; vhost-switch writes to `/etc/apache2` and `/etc/systemd/system`; runtime-manage calls `systemctl`. Pattern matches existing `laranode-panel` drop-in.

`laranode-scripts/bin/laranode-installer.sh` additions (in order, before first `systemctl restart apache2`):
1. `a2enmod proxy proxy_http`
2. Deploy: `cp -f "$PANEL/laranode-scripts/etc/sudoers.d/laranode-runtimes" /etc/sudoers.d/laranode-runtimes && chmod 0440 /etc/sudoers.d/laranode-runtimes`

`local-dev/entrypoint-setup.sh` additions (in the sudoers section, after the existing `laranode-cron` drop-in block at line ~103):
1. `a2enmod proxy proxy_http` (before `systemctl reload apache2`)
2. Deploy: `cp -f "$PANEL/laranode-scripts/etc/sudoers.d/laranode-runtimes" /etc/sudoers.d/laranode-runtimes && chmod 440 /etc/sudoers.d/laranode-runtimes`

Note: `testuser_ln` and `testuser2_ln` are already provisioned by the existing `entrypoint-setup.sh` (lines 145–147). No further system-user provisioning needed for v1.

**Acceptance criteria (verified in Task 9 system tests; here: script-level):**
- `laranode-runtime-install.sh` with arg `badvalue` → exits non-zero without touching filesystem.
- `laranode-runtime-install.sh` with arg `frankenphp` → exits 0; `/usr/local/bin/frankenphp --version` exits 0.
- `laranode-runtime-install.sh` called again (idempotent) → exits 0 without re-downloading.
- `laranode-runtime-manage.sh start sshd.service` → exits non-zero (invalid unit name).
- `laranode-runtime-manage.sh start laranode-frankenphp-example.test.service` → calls `systemctl start` (valid).
- `laranode-vhost-switch.sh` with domain `../../etc/passwd` → exits non-zero.
- `laranode-vhost-switch.sh` with port `9099` → exits non-zero (below range).
- `laranode-vhost-switch.sh` with port `9500` → exits non-zero (above range).
- `laranode-vhost-switch.sh` with valid args for `frankenphp` → writes correct vhost + unit file, exits 0.
- `visudo -c -f /etc/sudoers.d/laranode-runtimes` → syntax valid.

- [ ] Write `laranode-runtime-install.sh` (arg validation + idempotent install)
- [ ] Write `laranode-runtime-manage.sh` (action + unit-name validation + systemctl)
- [ ] Write `laranode-vhost-switch.sh` (7-arg validation + template selection + vhost write + unit write + a2ensite + graceful)
- [ ] Write `laranode-scripts/etc/sudoers.d/laranode-runtimes`
- [ ] Add `a2enmod` + sudoers deploy to `laranode-installer.sh`
- [ ] Add `a2enmod` + sudoers deploy to `local-dev/entrypoint-setup.sh`
- [ ] Commit: `feat(runtimes): privileged scripts (install/manage/vhost-switch) + sudoers drop-in`

---

### Task 5: Apache vhost template + systemd unit template + config key

**Files:**
- Create: `laranode-scripts/templates/apache-vhost-frankenphp.template`
- Create: `laranode-scripts/templates/laranode-frankenphp.service.template`
- Modify: `config/laranode.php`

**Scope:**

`apache-vhost-frankenphp.template`: `<VirtualHost *:80>` block with `ServerName {domain}`, `ServerAlias www.{domain}`, `DocumentRoot /home/{user}/domains/{domain}{document_root}`, `ErrorLog`/`CustomLog` matching existing template paths, `ProxyPreserveHost On`, `ProxyPass / http://127.0.0.1:{port}/`, `ProxyPassReverse / http://127.0.0.1:{port}/`, inner `<Directory>` with `AllowOverride None`. No `<FilesMatch \.php$>` block (PHP handled by app server). Placeholders: `{domain}`, `{user}`, `{document_root}`, `{port}`.

`laranode-frankenphp.service.template`: `[Unit]` / `[Service]` / `[Install]` systemd unit. `User={user}`, `Group={user}` (site user, not root or www-data). `WorkingDirectory=/home/{user}/domains/{domain}{document_root}`. `ExecStart=/usr/local/bin/frankenphp php-server --listen 127.0.0.1:{port} --root /home/{user}/domains/{domain}{document_root}`. `Restart=on-failure`, `RestartSec=5s`. Placeholders: `{user}`, `{domain}`, `{document_root}`, `{port}`.

`config/laranode.php`: add key `'apache_vhost_frankenphp_template' => base_path('laranode-scripts/templates/apache-vhost-frankenphp.template')` alongside the existing `'apache_vhost_template'` entry.

**Acceptance criteria:**
- Both template files exist with correct placeholder tokens matching the script's substitution logic from Task 4.
- `config('laranode.apache_vhost_frankenphp_template')` returns the correct absolute path.
- `config('laranode.apache_vhost_template')` still returns the original FPM template path (unchanged).
- `php artisan config:clear` + `php artisan tinker --execute "echo config('laranode.apache_vhost_frankenphp_template');"` → prints valid path.

- [ ] Create `apache-vhost-frankenphp.template`
- [ ] Create `laranode-frankenphp.service.template`
- [ ] Add config key to `config/laranode.php`
- [ ] Verify both templates' placeholders match `laranode-vhost-switch.sh` substitution patterns
- [ ] Commit: `feat(runtimes): Apache proxy + systemd unit templates + config key`

---

### Task 6 (TDD): `InstallRuntimeService` + `SwitchRuntimeService` + `PortAllocatorService` wiring + `SwitchRuntimeOperationJob`

**Files:**
- Create: `app/Services/Websites/InstallRuntimeService.php` (includes `InstallRuntimeException`)
- Create: `app/Services/Websites/SwitchRuntimeService.php` (includes `SwitchRuntimeException`)
- Create: `app/Jobs/SwitchRuntimeOperationJob.php`
- Modify: `app/Services/Websites/UpdateWebsitePHPVersionService.php`
- Modify: `app/Services/Websites/DeleteWebsiteService.php`
- Create: `tests/Feature/Websites/SwitchRuntimeTest.php`
- Create: `tests/Feature/Websites/SwitchRuntimeBackToFpmTest.php`

**Scope:**

`InstallRuntimeService::ensureInstalled(string $runtime, callable $emit): void`:
- Calls `Process::run(['sudo', config('laranode.laranode_bin_path') . '/laranode-runtime-install.sh', $runtime])`.
- Calls `$emit("Installing $runtime runtime...")` before.
- Throws `InstallRuntimeException` if `$result->failed()`.

`SwitchRuntimeService::handle()` (9 ordered steps, each calling `$emit`):
1. Validate `$runtime` is in `['php-fpm', 'frankenphp']`. Throw `SwitchRuntimeException` otherwise.
2. If `$runtime !== 'php-fpm'`, call `PortAllocatorService::allocate($website)` → `$port`.
3. Call `InstallRuntimeService::ensureInstalled($runtime, $emit)` (if non-FPM).
4. If old `$website->runtime !== 'php-fpm'`, call `laranode-runtime-manage.sh stop laranode-{old_runtime}-{domain}.service` via `Process::run(['sudo', ..., 'stop', ...])`.
5. If new `$runtime !== 'php-fpm'`: call `laranode-vhost-switch.sh {domain} frankenphp {port} {systemUsername} {phpVersion} {document_root} {template_dir}` via `Process::run(['sudo', ...])`. Throws `SwitchRuntimeException` on failure.
6. If new `$runtime !== 'php-fpm'`: call `laranode-runtime-manage.sh enable laranode-frankenphp-{domain}.service` then `laranode-runtime-manage.sh start ...`.
7. If new `$runtime === 'php-fpm'`: call `laranode-vhost-switch.sh {domain} php-fpm 0 ...` (port 0 is ignored by the script for FPM). Set `$port = null`.
8. Update: `$website->update(['runtime' => $runtime, 'runtime_port' => $port])`.
9. Emit success line.

`SwitchRuntimeOperationJob extends OperationJob`:
```php
public function __construct(Operation $operation, public Website $website, public string $runtime)
{
    parent::__construct($operation);
}

protected function run(callable $emit): int
{
    (new SwitchRuntimeService($this->website, $this->runtime, $emit))->handle();
    return 0;
}
```
Mirrors `GenerateSslOperationJob` exactly. Base `OperationJob::handle()` calls `markRunning()`, calls `run($emit)`, calls `markFinished($exit)`, wraps exceptions in `markFinished(1)`.

`UpdateWebsitePHPVersionService::handle()` modification: at the top, add a guard:
```php
if ($this->website->runtime !== 'php-fpm') {
    throw new \InvalidArgumentException('PHP version switching is not supported for this runtime.');
}
```
The controller will catch this and return a 422.

`DeleteWebsiteService::handle()` modification: add `$this->teardownRuntime()` call before `$this->syncPhpFpmPools()`. New private method `teardownRuntime()`: if `$this->website->runtime !== 'php-fpm'`, call `Process::run(['sudo', ..., 'laranode-runtime-manage.sh', 'stop', "laranode-{$runtime}-{$url}.service"])` and `Process::run(['sudo', ..., 'laranode-runtime-manage.sh', 'disable', ...])`. Non-zero exit is logged but does not block deletion (site files are gone; unit cleanup is best-effort). Remove the unit file from `/etc/systemd/system/` (inline `rm` via existing sudoers pattern or new script — check whether `rm /etc/systemd/system/laranode-*.service` is coverable by existing sudoers before adding a new rule; for v1, use `Process::run(['sudo', 'rm', '-f', "/etc/systemd/system/laranode-{$runtime}-{$url}.service"])` and add this to the sudoers drop-in if needed).

**Feature test acceptance criteria (all using `Process::fake()`):**

`SwitchRuntimeTest.php`:
- `POST /websites/{id}/runtime` as owner, `runtime=frankenphp` → 200 JSON `{'operation_id': N}`; `Operation` row with `type='runtime.switch'`, `status='queued'` (sync queue: `status='succeeded'`).
- Same request as non-owner → 403, no `Operation` row created.
- Unauthenticated → redirect to login.
- `runtime=swoole` → 422.
- `runtime=` empty → 422.
- `runtime=../etc/passwd` → 422.
- `Process::fake()` with `laranode-runtime-install.sh` returning exit 1 → `Operation` status `'failed'`; `websites.runtime` unchanged.
- `Process::fake()` with `laranode-vhost-switch.sh` returning exit 1 → `Operation` status `'failed'`; `websites.runtime` unchanged.
- Fully successful job (all `Process::fake()` return exit 0) → `websites.runtime = 'frankenphp'`; `websites.runtime_port` in range 9100–9499; `Operation` status `'succeeded'`.

`SwitchRuntimeBackToFpmTest.php`:
- Site with `runtime='frankenphp'`, `runtime_port=9100` switches to `runtime='php-fpm'` → `Operation` `'succeeded'`; `websites.runtime = 'php-fpm'`; `websites.runtime_port = null`.
- Verifies `Process::fake()` received `laranode-runtime-manage.sh stop` call for the old FrankenPHP unit.
- Verifies `Process::fake()` received `laranode-vhost-switch.sh` with `php-fpm` as the runtime arg.

`WebsiteController::update()` (PHP version change) test: site with `runtime='frankenphp'` → `PATCH /websites/{id}` with `php_version_id` → 422, `websites.php_version_id` unchanged.

`DeleteWebsiteService` test: site with `runtime='frankenphp'` → `DELETE /websites/{id}` → verifies `laranode-runtime-manage.sh stop` + `laranode-runtime-manage.sh disable` called via `Process::fake()`; website row deleted.

- [ ] Write failing feature tests (both files)
- [ ] Write `InstallRuntimeService` (with `InstallRuntimeException`)
- [ ] Write `SwitchRuntimeService` (with `SwitchRuntimeException`, 9-step handle)
- [ ] Write `SwitchRuntimeOperationJob`
- [ ] Modify `UpdateWebsitePHPVersionService` (non-FPM guard)
- [ ] Modify `DeleteWebsiteService` (add `teardownRuntime()`)
- [ ] Verify all feature tests pass
- [ ] Run Pint on all new/modified PHP files
- [ ] Commit: `feat(runtimes): SwitchRuntimeService + SwitchRuntimeOperationJob + delete/version guards`

---

### Task 7: `WebsiteController::switchRuntime()` + route

**Files:**
- Modify: `app/Http/Controllers/WebsiteController.php`
- Modify: `routes/web.php`

**Scope:**

`WebsiteController::switchRuntime(SwitchRuntimeRequest $request, Website $website)`:
```php
Gate::authorize('update', $website);
$runtime = $request->validated()['runtime'];
$operation = Operation::create([
    'user_id' => $request->user()->id,
    'type'    => 'runtime.switch',
    'target'  => $website->url,
    'status'  => 'queued',
]);
SwitchRuntimeOperationJob::dispatch($operation, $website, $runtime);
return response()->json(['operation_id' => $operation->id]);
```
Mirrors `toggleSsl()` (same file, same async JSON-response pattern). Uses `WebsitePolicy::update()` which already gates admin-or-owner — no changes to `WebsitePolicy`.

`WebsiteController::update()`: add catch for `\InvalidArgumentException` from the new guard in `UpdateWebsitePHPVersionService`; return a 422 JSON response.

Route addition in `routes/web.php` (inside the existing websites `auth` block):
```php
Route::post('/websites/{website}/runtime', [WebsiteController::class, 'switchRuntime'])
    ->middleware(['auth'])
    ->name('websites.runtime.switch');
```

**Acceptance criteria:**
- `php artisan route:list --name=websites.runtime.switch` → shows `POST /websites/{website}/runtime`.
- The HTTP feature tests from Task 6 (`SwitchRuntimeTest.php`) pass against this route.
- `PATCH /websites/{id}` on a `runtime='frankenphp'` site → 422 (via the guard in `UpdateWebsitePHPVersionService`).
- `php artisan route:list` shows no duplicate or conflicting routes.

- [ ] Add `switchRuntime()` method to `WebsiteController`
- [ ] Update `update()` to catch `\InvalidArgumentException` → 422
- [ ] Add route to `routes/web.php`
- [ ] Verify all Task 6 feature tests still pass
- [ ] Run Pint
- [ ] Commit: `feat(runtimes): WebsiteController::switchRuntime() + route`

---

### Task 8 (TDD): React UI — Runtime column + `runtimeOp` state + Vitest

**Files:**
- Modify: `resources/js/Pages/Websites/Index.jsx`
- Create: `resources/js/Pages/Websites/Websites.runtime.test.jsx`

**Scope:**

`Index.jsx` changes:
- Import: `import axios from 'axios'` is already present. No new imports needed (`OperationProgress` already imported).
- Add state: `const [runtimeOp, setRuntimeOp] = useState(null);` alongside existing `const [sslOp, setSslOp] = useState(null);`.
- Add `switchRuntime(website, runtime)` handler: `axios.post(route('websites.runtime.switch', { website: website.id }), { runtime }).then((res) => setRuntimeOp({ id: res.data.operation_id, url: website.url, runtime })).catch(() => toast.error('Failed to start runtime switch'))`.
- Render `runtimeOp` progress block above (or alongside) the `sslOp` block:
  ```jsx
  {runtimeOp && (
      <div className="mb-4 p-3 border rounded">
          <div className="text-sm">Switching {runtimeOp.url} to {runtimeOp.runtime}...</div>
          <OperationProgress
              operationId={runtimeOp.id}
              onDone={() => { setRuntimeOp(null); router.reload(); }}
          />
      </div>
  )}
  ```
- New table column **Runtime** after PHP Version column (add `<th>` header + `<td>` per row). The `<td>` contains:
  1. A runtime badge (e.g. `PHP-FPM` / `FrankenPHP`) based on `website.runtime`.
  2. A `<select>` with options `php-fpm` → label `PHP-FPM` and `frankenphp` → label `FrankenPHP`. `value={website.runtime}`. `onChange` calls `switchRuntime(website, e.target.value)` when the value actually changes.
  3. A conditional info banner shown when `website.runtime !== 'php-fpm'`: `"FrankenPHP mode: .htaccess rewrites are disabled. Apache proxies all requests to the app server."` (small `<p>` with a warning style).
  4. The PHP Version `<select>` is `disabled` with a tooltip title `"PHP version is managed by FrankenPHP"` when `website.runtime !== 'php-fpm'`.

`Websites.runtime.test.jsx` (Vitest + RTL):
- Mock `axios`, `router`, `route` (same pattern as existing tests in `resources/js/Pages/Databases/Partials/CreateDatabaseForm.test.jsx`).
- Test 1: renders with `website.runtime = 'frankenphp'` → Runtime column shows badge with text `FrankenPHP`; info banner is visible.
- Test 2: renders with `website.runtime = 'php-fpm'` → badge shows `PHP-FPM`; info banner is absent.
- Test 3: user selects `FrankenPHP` from the `<select>` → `axios.post` called with `route('websites.runtime.switch', ...)` and body `{ runtime: 'frankenphp' }`.
- Test 4: `onDone` callback fires → `router.reload()` is called.
- Test 5: renders with `runtime = 'frankenphp'` → PHP version `<select>` is `disabled`.
- Test 6: renders with `runtime = 'php-fpm'` → PHP version `<select>` is NOT `disabled`.

**Acceptance criteria:**
- `npm run test -- --filter=Websites.runtime` → 6 tests green.
- `npm run build` → exits 0, no import errors.
- In the running app (or Inertia snapshot): the Websites index page renders the Runtime column for all rows; selecting a different runtime fires the `POST` endpoint and shows the `OperationProgress` widget.

- [ ] Write failing Vitest tests
- [ ] Modify `Index.jsx` (runtimeOp state + switchRuntime handler + OperationProgress block + Runtime column + badges + select + info banner + PHP version disabled guard)
- [ ] Verify Vitest tests pass
- [ ] `npm run build` succeeds
- [ ] Commit: `feat(runtimes): Websites index — runtime column, select, OperationProgress, info banner`

---

### Task 9 (TDD): System integration tests (`LARANODE_SYSTEM_TESTS=1`)

**Files:**
- Create: `tests/Feature/Websites/RuntimeSystemTest.php`

**Scope:**

All tests gated: `if (!env('LARANODE_SYSTEM_TESTS')) $this->markTestSkipped('system tests disabled');`

Preconditions (provided by `local-dev` container after Task 4 changes to `entrypoint-setup.sh`):
- `a2enmod proxy proxy_http` enabled.
- `/etc/sudoers.d/laranode-runtimes` installed.
- `testuser_ln` system account exists (already provisioned).
- A test website row pointing to a valid directory under `testuser_ln`'s homedir (create in `setUp()`).
- FrankenPHP binary available after test 1 runs.

Tests:
1. **Install FrankenPHP binary** — `Process::run(['sudo', ..., 'laranode-runtime-install.sh', 'frankenphp'])` → exit 0; assert `/usr/local/bin/frankenphp` exists; assert `frankenphp --version` exits 0.
2. **Idempotent install** — run install again → exit 0, no error (skips re-download).
3. **Switch site to FrankenPHP** — dispatch `SwitchRuntimeOperationJob` for test website to `frankenphp`; poll until `Operation::find($op->id)->status === 'succeeded'` (or use `QUEUE_CONNECTION=sync`); assert `systemctl is-active laranode-frankenphp-{domain}.service` returns `active`; assert `websites.runtime = 'frankenphp'`; assert `websites.runtime_port` in 9100–9499.
4. **Apache proxy responds** — `curl -s -o /dev/null -w '%{http_code}' --header "Host: {domain}" http://127.0.0.1/` returns HTTP status that is not 502 (may be 200 or 404 depending on site content; 502 = proxy failure = fail).
5. **Switch back to FPM** — dispatch job with `php-fpm`; poll; assert `systemctl is-active laranode-frankenphp-{domain}.service` returns `inactive` or `unknown`; assert `websites.runtime = 'php-fpm'`; assert `websites.runtime_port = null`; assert `/etc/apache2/sites-available/{domain}.conf` does not contain `ProxyPass`.
6. **SSL coexistence** — with site at `frankenphp`, assert Apache vhost file contains `ProxyPass` directive; toggle SSL on (via `GenerateSslOperationJob` in local dev with Pebble ACME); assert SSL vhost file contains `ProxyPass` directives in the `:443` block.
7. **Invalid runtime rejected by install script** — `Process::run(['sudo', ..., 'laranode-runtime-install.sh', 'badvalue'])` → exit non-zero; `/usr/local/bin/badvalue` does not exist.
8. **Invalid unit name rejected by manage script** — `Process::run(['sudo', ..., 'laranode-runtime-manage.sh', 'start', 'sshd.service'])` → exit non-zero.
9. **Domain path traversal rejected by vhost-switch script** — `Process::run(['sudo', ..., 'laranode-vhost-switch.sh', '../../etc/passwd', 'frankenphp', '9100', 'testuser_ln', '8.4', '/public_html', ...])` → exit non-zero; `/etc/apache2/sites-available/../../etc/passwd.conf` does not exist.

**Acceptance criteria:**
- Standard suite (no flag): `php artisan test` → all green; system tests marked skipped.
- System suite: `LARANODE_SYSTEM_TESTS=1 php artisan test --filter=RuntimeSystemTest` → 9 passing inside `local-dev` container.
- Test 6 (SSL coexistence) may be skipped if Pebble is not configured in the test run; mark with `$this->markTestSkipped('Pebble not configured')` when `env('PEBBLE_ACME_URL')` is absent.

- [ ] Write `RuntimeSystemTest.php` (9 tests, properly gated)
- [ ] Run standard suite: all green (system tests skipped)
- [ ] Run system suite inside container: 9 passing (or 8 + 1 skipped if Pebble absent)
- [ ] Run Pint on new PHP file
- [ ] Commit: `test(runtimes): system integration tests for real FrankenPHP install + switch (LARANODE_SYSTEM_TESTS=1)`

---

### Task 10: Final verification gate

**Files:** None (verification only).

**Steps (all must pass before merging):**
- [ ] `./vendor/bin/pest` → full Pest suite green, zero failures, system tests skipped (no `LARANODE_SYSTEM_TESTS` flag).
- [ ] `npm run test` → full Vitest suite green, including `Websites.runtime.test.jsx`.
- [ ] `./vendor/bin/pint --test` → zero formatting issues on all new and modified PHP files.
- [ ] `npm run build` → exits 0, no Vite/JS errors.
- [ ] Inside `local-dev` container: `LARANODE_SYSTEM_TESTS=1 php artisan test --filter=RuntimeSystemTest` → 9 passing.
- [ ] `php artisan route:list --name=websites.runtime.switch` → route present.
- [ ] `php artisan schedule:list` → still shows `model:prune --model=App\Models\Operation` daily entry (unchanged).
- [ ] `visudo -c -f /etc/sudoers.d/laranode-runtimes` → syntax valid.
- [ ] Manual smoke: in running panel, navigate to Websites, verify Runtime column renders for all rows; select FrankenPHP for a test site; observe `OperationProgress` widget; verify site URL returns non-502 after completion.

---

## File Inventory

```
database/migrations/2026_06_27_000002_add_runtime_to_websites_table.php   (new)
app/Models/Website.php                                                      (modify: $fillable, $casts, getRuntimeLabelAttribute)
app/Services/Websites/PortAllocatorService.php                              (new)
app/Http/Requests/SwitchRuntimeRequest.php                                  (new)
app/Services/Websites/InstallRuntimeService.php                             (new, includes InstallRuntimeException)
app/Services/Websites/SwitchRuntimeService.php                              (new, includes SwitchRuntimeException)
app/Jobs/SwitchRuntimeOperationJob.php                                      (new)
app/Services/Websites/UpdateWebsitePHPVersionService.php                    (modify: non-FPM guard)
app/Services/Websites/DeleteWebsiteService.php                              (modify: teardownRuntime())
app/Http/Controllers/WebsiteController.php                                  (modify: switchRuntime() + update() 422 guard)
config/laranode.php                                                         (modify: apache_vhost_frankenphp_template key)
routes/web.php                                                              (modify: websites.runtime.switch route)
laranode-scripts/bin/laranode-runtime-install.sh                            (new)
laranode-scripts/bin/laranode-runtime-manage.sh                             (new)
laranode-scripts/bin/laranode-vhost-switch.sh                               (new)
laranode-scripts/templates/apache-vhost-frankenphp.template                 (new)
laranode-scripts/templates/laranode-frankenphp.service.template             (new)
laranode-scripts/etc/sudoers.d/laranode-runtimes                            (new)
laranode-scripts/bin/laranode-installer.sh                                  (modify: a2enmod + sudoers deploy)
local-dev/entrypoint-setup.sh                                               (modify: a2enmod + sudoers deploy)
resources/js/Pages/Websites/Index.jsx                                       (modify: Runtime column, runtimeOp state, OperationProgress)
tests/Feature/Websites/WebsiteRuntimeModelTest.php                          (new, Pest)
tests/Unit/PortAllocatorServiceTest.php                                     (new, Pest unit)
tests/Unit/SwitchRuntimeRequestTest.php                                     (new, Pest unit)
tests/Feature/Websites/SwitchRuntimeTest.php                                (new, Pest feature)
tests/Feature/Websites/SwitchRuntimeBackToFpmTest.php                       (new, Pest feature)
tests/Feature/Websites/RuntimeSystemTest.php                                (new, Pest, LARANODE_SYSTEM_TESTS=1)
resources/js/Pages/Websites/Websites.runtime.test.jsx                       (new, Vitest)
```

Total: 27 files (10 new backend, 3 new scripts, 2 new templates, 1 new sudoers, 3 modified services/controller, 3 modified infrastructure files, 5 new Pest test files, 1 new Vitest test file).

---

## Back-compat Notes

- All existing rows default to `runtime='php-fpm'`, `runtime_port=null` after migration. No functional change to any live site.
- `CreateWebsiteService`, `AddVhostEntryService`, `CreatePhpFpmPoolService` are unchanged. New sites always start as `php-fpm`.
- `DeleteWebsiteService::syncPhpFpmPools()` is unchanged. The new `teardownRuntime()` step is additive, runs before `syncPhpFpmPools()`, and is a no-op when `website->runtime === 'php-fpm'`.
- `Operation` rows with `type='runtime.switch'` appear automatically in `/admin/operations` (`Operations/Index.jsx`) via the generic table. No code changes needed there.
- `Operation` model's `MassPrunable` (30-day prune) handles `runtime.*` rows automatically.
- The existing `WebsitePolicy::update()` and `WebsitePolicy::delete()` methods cover all new authorization checks — no policy changes needed.

## Open Questions (flagged from spec, decision required before implementation)

1. **FrankenPHP binary checksum** — spec recommends pinning SHA-256 in `laranode-runtime-install.sh`. Decide before Task 4: pin checksum or document the risk and defer to v2.
2. **FrankenPHP built-in server vs. worker mode** — spec uses `frankenphp php-server` (no `laravel/octane` required). Confirm this is acceptable for v1 before Task 4 writes the systemd unit template.
3. **SSL + FrankenPHP vhost template** — `laranode-ssl-manager.sh create_ssl_vhost()` copies inner content from the base vhost. Confirm in Task 9 system test 6 that `ProxyPass` directives survive the copy into the `:443` block. If they do not, a `frankenphp` branch in `laranode-ssl-manager.sh` is needed (scope increase).
4. **`teardownRuntime()` unit file removal** — check whether `rm /etc/systemd/system/laranode-*.service` can be covered by extending the existing `laranode-panel` sudoers wildcard, or whether it requires an entry in the new `laranode-runtimes` drop-in. Decide before Task 6.
