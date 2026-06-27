# PHP Runtimes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each website a per-site PHP runtime choice. Today every site runs under a PHP-FPM Unix-socket pool managed by `AddVhostEntryService` + `laranode-add-vhost.sh`. This feature adds FrankenPHP as a v1 alternative runtime: a persistent app server on a loopback TCP port (9100–9499), proxied by Apache via `mod_proxy` + `mod_proxy_http`. Switching a site's runtime is an async `OperationJob` that broadcasts live output via `OperationUpdated` (same pattern as `GenerateSslOperationJob` / `toggleSsl`).

**Architecture:** `WebsiteController::switchRuntime()` (thin) → `SwitchRuntimeRequest` (FormRequest, enum validation) → `Operation::create()` + `SwitchRuntimeOperationJob::dispatch()` (async) → `SwitchRuntimeService::handle()` (orchestration, calls sub-services + scripts) → `laranode-runtime-install.sh` / `laranode-runtime-manage.sh` / `laranode-runtime-unit.sh` / `laranode-vhost-switch.sh` (privileged scripts, argument-validated).

**Key constraints (post-review):**
- `websites.runtime` (`php-fpm` | `frankenphp`; `swoole` is v2). Default `php-fpm`. `websites.runtime_port` nullable, set on non-FPM runtimes only after `systemctl start` succeeds (FIXED: port not burned on failed start), cleared on revert.
- Port range 9100–9499. Allocated by `PortAllocatorService`. No DB unique constraint in v1 (documented concurrency risk; v2 fix: `lockForUpdate`).
- **Four** new privileged scripts (FIXED: `laranode-runtime-unit.sh` extracted from vhost-switch): `laranode-runtime-install.sh`, `laranode-runtime-manage.sh`, `laranode-runtime-unit.sh`, `laranode-vhost-switch.sh`. Each with `set -euo pipefail`, argument-count checks, regex validation.
- `laranode-vhost-switch.sh` writes Apache vhost **only** (FIXED: no dual-privilege).
- `laranode-runtime-unit.sh` writes systemd unit file + runs `daemon-reload` (FIXED: sequencing).
- `laranode-runtime-manage.sh` includes `remove` sub-command for validated unit-file deletion (FIXED: no raw sudo rm glob).
- `laranode-runtime-install.sh` pins SHA-256 checksum and re-downloads on corrupt binary (FIXED: binary integrity).
- Apache FrankenPHP vhost template includes `ProxyPass /.well-known/acme-challenge/ !` before catch-all (FIXED: SSL/ACME renewal).
- Domain regex: `^[a-zA-Z0-9][a-zA-Z0-9.-]+$` — no leading dot (FIXED: SyslogIdentifier safety).
- Port range check skipped when `runtime=php-fpm` in `laranode-vhost-switch.sh` (FIXED: FPM revert path).
- `teardownRuntime()` called FIRST in `DeleteWebsiteService::handle()`, before `deleteWebsiteFiles()` (FIXED: clean shutdown).
- `WebsiteController::update()` catches `\InvalidArgumentException` → `redirect()->back()->withErrors()` (FIXED: Inertia compat, not JSON 422).
- `SwitchRuntimeOperationJob::run()` calls `$this->website->load('user')` on deserialization (FIXED: stale relation).
- New sudoers drop-in covers 4 scripts. No raw `sudo rm` glob anywhere.
- `DeleteWebsiteService` gains `teardownRuntime()` — **required** v1 addition.
- `UpdateWebsitePHPVersionService` rejects non-FPM sites.
- `SwitchRuntimeOperationJob` extends `app/Jobs/OperationJob.php` exactly as `GenerateSslOperationJob` does.
- No changes to `OperationJob`, `OperationUpdated`, `useOperation`, or `OperationProgress`.
- Frontend: mirrors `sslOp` pattern. Vitest `onDone` test simulates Echo WebSocket event through `useOperation` → `OperationProgress` → `onDone` (FIXED: not direct prop call).

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
- Add `getRuntimeLabelAttribute(): string` using `match($this->runtime)` → `'FrankenPHP'` | `'Swoole (Octane)'` | `'PHP-FPM'`. Verify before appending to `$appends` (avoid breaking existing Inertia serialisation).

**Acceptance criteria:**
- `php artisan migrate --pretend` shows two `alter table` operations, no errors.
- Test: factory row without `runtime` set → `$website->runtime === 'php-fpm'`, `$website->runtime_port === null`.
- Test: `$website->runtime = 'frankenphp'; $website->runtime_label` → `'FrankenPHP'`.
- Test: `$website->runtime = 'swoole'; $website->runtime_label` → `'Swoole (Octane)'`.
- Test: existing `Website` factory rows (from other test files) continue to pass.
- `php artisan test --filter=WebsiteRuntimeModelTest` → green.

- [ ] Write failing model test
- [ ] Write migration
- [ ] Modify `Website` model (`$fillable`, `$casts`, accessor)
- [ ] Verify test passes
- [ ] Run Pint on modified PHP
- [ ] Commit: `feat(runtimes): add runtime + runtime_port columns to websites table`

---

### Task 2 (TDD): `PortAllocatorService` + unit tests

**Files:**
- Create: `app/Services/Websites/PortAllocatorService.php`
- Create: `tests/Unit/PortAllocatorServiceTest.php`

**Scope:**
- `PortAllocatorService::allocate(Website $excludeWebsite): int` — queries `Website::whereNotNull('runtime_port')->where('id', '!=', $excludeWebsite->id)->pluck('runtime_port')->toArray()`; iterates 9100–9499 and returns first free port; throws `\RuntimeException('No available runtime ports in range 9100–9499.')` if exhausted.
- No lock in v1 (concurrency risk documented; v2 adds `lockForUpdate`).

**Acceptance criteria:**
- Test: no other websites → `allocate()` returns `9100`.
- Test: website with `runtime_port=9100` exists (different `id`) → returns `9101`.
- Test: all 9100–9499 occupied by other websites → throws `\RuntimeException`.
- Test: `$excludeWebsite` own port (same `id`) excluded from used set → does not block self.
- **Concurrent race test (FIXED):** two concurrent allocations for different sites on the
  same initial DB state → assert that after the second job's `systemctl start` fails,
  the second site's `runtime_port` remains `null` (not written to DB on failed start).
- `php artisan test --filter=PortAllocatorServiceTest` → green.

- [ ] Write failing unit test (table-driven dataset)
- [ ] Write `PortAllocatorService`
- [ ] Write concurrent race test
- [ ] Verify tests pass
- [ ] Run Pint
- [ ] Commit: `feat(runtimes): PortAllocatorService (9100–9499, first-gap allocation)`

---

### Task 3 (TDD): `SwitchRuntimeRequest` + request validation unit tests

**Files:**
- Create: `app/Http/Requests/SwitchRuntimeRequest.php`
- Create: `tests/Unit/SwitchRuntimeRequestTest.php`

**Scope:**
- `SwitchRuntimeRequest::rules()`: `'runtime' => ['required', 'string', Rule::in(['php-fpm', 'frankenphp'])]`. (`swoole` deferred to v2.)
- `SwitchRuntimeRequest::authorize()`: `return auth()->check();` — ownership gated by `Gate::authorize` in controller.

**Acceptance criteria:**
- `runtime=php-fpm` and `runtime=frankenphp` pass.
- `runtime=swoole` fails (422).
- Empty, missing, `../etc/passwd`, `; rm -rf /` all fail (422).
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
- Create: `laranode-scripts/bin/laranode-runtime-unit.sh`  ← NEW (FIXED: extracted from vhost-switch)
- Create: `laranode-scripts/bin/laranode-vhost-switch.sh`
- Create: `laranode-scripts/etc/sudoers.d/laranode-runtimes`
- Modify: `laranode-scripts/bin/laranode-installer.sh`
- Modify: `local-dev/entrypoint-setup.sh`

**Scope of each script:**

`laranode-runtime-install.sh <runtime>`:
- `set -euo pipefail`. Arg count: exactly 1. `$1` must match `^(frankenphp|swoole)$`; else `exit 1`.
- `frankenphp` branch:
  - If `/usr/local/bin/frankenphp` exists AND `frankenphp --version` exits 0 → skip (idempotent).
  - If binary exists but `--version` fails (corrupt) → re-download (FIXED: corrupt binary branch).
  - Download from pinned URL (`FRANKENPHP_VERSION` + `FRANKENPHP_SHA256` hard-coded in script).
  - After download: `echo "${FRANKENPHP_SHA256}  /tmp/frankenphp" | sha256sum -c -` (FIXED: binary integrity, review fix #1). Exit 1 on mismatch.
  - `mv /tmp/frankenphp /usr/local/bin/frankenphp && chmod 0755 /usr/local/bin/frankenphp`.
  - Verify `frankenphp --version` exits 0.

`laranode-runtime-manage.sh <action> <unit-name>`:
- `set -euo pipefail`. Arg count: exactly 2.
- `$1` (action) must match `^(enable|disable|start|stop|restart|status|remove)$`; else `exit 1`.
- `$2` (unit name) must match `^laranode-(frankenphp|swoole)-[a-zA-Z0-9._-]+\.service$`; else `exit 1`.
  (Rejects `sshd.service`, `laranode-frankenphp-foo/../../sshd.service`, etc.)
- Lifecycle verbs: `systemctl "$ACTION" "$UNIT"`.
- `remove` verb (FIXED: review fix #3): `systemctl disable --now "$UNIT" 2>/dev/null || true; rm -f "/etc/systemd/system/$UNIT"`. Unit name already validated above.

`laranode-runtime-unit.sh <sub-command> <domain> <port> <system_user> <document_root> <template_dir>` (NEW — FIXED: review fix #6):
- `set -euo pipefail`. Arg count: exactly 6.
- `$1` (sub-command): must match `^(write-unit)$`; else `exit 1`.
- `$2` (domain): must match `^[a-zA-Z0-9][a-zA-Z0-9.-]+$` (FIXED: no leading dot, review fix #3); else `exit 1`.
- `$3` (port): `^[0-9]+$`, range 9100–9499; else `exit 1`.
- `$4` (system_user): must end in `_ln`; else `exit 1`.
- Substitutes placeholders in `laranode-frankenphp.service.template`, writes to `/etc/systemd/system/laranode-frankenphp-{domain}.service`.
- Runs `systemctl daemon-reload` after writing (FIXED: sequencing, review fix #7).
- Its sudoers grant covers only `/etc/systemd/system` writes.

`laranode-vhost-switch.sh <domain> <runtime> <port> <system_user> <php_version> <document_root> <template_dir>`:
- `set -euo pipefail`. Arg count: exactly 7.
- `$1` (domain): `^[a-zA-Z0-9][a-zA-Z0-9.-]+$` (FIXED: no leading dot, review fix #3).
- `$2` (runtime): `^(php-fpm|frankenphp|swoole)$`.
- `$3` (port): `^[0-9]+$`. Port range check **only when runtime != php-fpm** (FIXED: review fix #4):
  ```bash
  if [ "$RUNTIME" != "php-fpm" ]; then
      [ "$PORT" -ge 9100 ] && [ "$PORT" -le 9499 ] || { echo "Port out of range"; exit 1; }
  fi
  ```
- `$4` (system_user): must end in `_ln`.
- Selects `apache-vhost-frankenphp.template` or `apache-vhost.template` based on runtime.
- Writes `/etc/apache2/sites-available/{domain}.conf` **only** (FIXED: no unit file, review fix #6).
- Runs `a2ensite {domain}` + `apache2ctl graceful`.
- `php_version` arg ($5) is passed for FPM template substitution; for FrankenPHP template it has no `{phpVersion}` placeholder and is intentionally unused (no silent sed failure, just dead argument — documented in script comment).

`laranode-scripts/etc/sudoers.d/laranode-runtimes`:
```sudoers
Defaults!/home/laranode_ln/panel/laranode-scripts/bin/laranode-runtime-install.sh !requiretty
Defaults!/home/laranode_ln/panel/laranode-scripts/bin/laranode-runtime-manage.sh !requiretty
Defaults!/home/laranode_ln/panel/laranode-scripts/bin/laranode-runtime-unit.sh !requiretty
Defaults!/home/laranode_ln/panel/laranode-scripts/bin/laranode-vhost-switch.sh !requiretty

www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-runtime-install.sh
www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-runtime-manage.sh
www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-runtime-unit.sh
www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-vhost-switch.sh
```
No raw `sudo rm` glob entry. Unit removal handled entirely by `laranode-runtime-manage.sh remove` (FIXED).

`laranode-scripts/bin/laranode-installer.sh` additions (before first `systemctl restart apache2`):
1. `a2enmod proxy proxy_http`
2. `cp -f "$PANEL/laranode-scripts/etc/sudoers.d/laranode-runtimes" /etc/sudoers.d/laranode-runtimes && chmod 0440 /etc/sudoers.d/laranode-runtimes`

`local-dev/entrypoint-setup.sh` additions (after existing `laranode-cron` drop-in block):
1. `a2enmod proxy proxy_http` (before `systemctl reload apache2`)
2. `cp -f "$PANEL/laranode-scripts/etc/sudoers.d/laranode-runtimes" /etc/sudoers.d/laranode-runtimes && chmod 440 /etc/sudoers.d/laranode-runtimes`

**Acceptance criteria (script-level; system-level in Task 9):**
- `laranode-runtime-install.sh badvalue` → non-zero.
- `laranode-runtime-install.sh frankenphp` → exit 0; binary at expected path; `--version` exits 0.
- Corrupt binary re-run → re-downloads; `--version` exits 0 after.
- `laranode-runtime-manage.sh start sshd.service` → non-zero.
- `laranode-runtime-manage.sh start laranode-frankenphp-example.test.service` → calls `systemctl start`.
- `laranode-runtime-manage.sh remove laranode-frankenphp-example.test.service` → calls `systemctl disable --now` + `rm -f`.
- `laranode-runtime-unit.sh write-unit example.test 9100 testuser_ln /public_html /path/to/templates` → writes unit file + `daemon-reload`.
- `laranode-runtime-unit.sh write-unit ..evil.com 9100 testuser_ln ...` → non-zero.
- `laranode-vhost-switch.sh ../../etc/passwd frankenphp 9100 testuser_ln 8.4 /public_html /templates` → non-zero.
- `laranode-vhost-switch.sh example.test php-fpm 0 testuser_ln 8.4 /public_html /templates` → exit 0 (port 0 accepted for FPM — FIXED).
- `laranode-vhost-switch.sh example.test frankenphp 9099 testuser_ln 8.4 /public_html /templates` → non-zero (below range).
- `visudo -c -f /etc/sudoers.d/laranode-runtimes` → syntax valid.

- [ ] Write `laranode-runtime-install.sh` (SHA-256 pin + corrupt-binary re-download + idempotent)
- [ ] Write `laranode-runtime-manage.sh` (action + unit-name validation + systemctl + remove)
- [ ] Write `laranode-runtime-unit.sh` (write-unit sub-command + daemon-reload)
- [ ] Write `laranode-vhost-switch.sh` (7-arg validation + FPM port-skip + Apache vhost only)
- [ ] Write `laranode-scripts/etc/sudoers.d/laranode-runtimes`
- [ ] Add `a2enmod` + sudoers deploy to `laranode-installer.sh`
- [ ] Add `a2enmod` + sudoers deploy to `local-dev/entrypoint-setup.sh`
- [ ] Commit: `feat(runtimes): privileged scripts (install/manage/unit/vhost-switch) + sudoers drop-in`

---

### Task 5: Apache vhost template + systemd unit template + config key

**Files:**
- Create: `laranode-scripts/templates/apache-vhost-frankenphp.template`
- Create: `laranode-scripts/templates/laranode-frankenphp.service.template`
- Modify: `config/laranode.php`

**Scope:**

`apache-vhost-frankenphp.template`: `<VirtualHost *:80>` block with `ServerName {domain}`,
`ServerAlias www.{domain}`, `DocumentRoot /home/{user}/domains/{domain}{document_root}`,
`ErrorLog`/`CustomLog` matching existing template paths.

**ACME challenge exception (FIXED — review fix #2)** — must appear BEFORE the catch-all ProxyPass:
```apache
# ACME challenge served from disk (required for certbot --webroot renewal)
ProxyPass /.well-known/acme-challenge/ !
<Directory /home/{user}/domains/{domain}{document_root}/.well-known/acme-challenge>
    Options None
    AllowOverride None
    Require all granted
</Directory>
```

Then: `ProxyPreserveHost On`, `ProxyPass / http://127.0.0.1:{port}/`, `ProxyPassReverse / ...`,
inner `<Directory>` with `AllowOverride None`. No `<FilesMatch \.php$>` block.
Placeholders: `{domain}`, `{user}`, `{document_root}`, `{port}`.

`laranode-frankenphp.service.template`: `[Unit]` / `[Service]` / `[Install]`. `User={user}`,
`Group={user}`. `WorkingDirectory=/home/{user}/domains/{domain}{document_root}`.
`ExecStart=/usr/local/bin/frankenphp php-server --listen 127.0.0.1:{port} --root /home/{user}/domains/{domain}{document_root}`.
`Restart=on-failure`, `RestartSec=5s`. `SyslogIdentifier=laranode-frankenphp-{domain}`.
Placeholders: `{user}`, `{domain}`, `{document_root}`, `{port}`. No `{phpVersion}` placeholder
(FrankenPHP uses system PHP; the `php_version` arg in `laranode-vhost-switch.sh` is unused for
this template — documented in script, not a silent failure).

`config/laranode.php`: add `'apache_vhost_frankenphp_template' => base_path('laranode-scripts/templates/apache-vhost-frankenphp.template')`.

**Acceptance criteria:**
- Both template files exist with correct placeholder tokens matching script substitution logic.
- FrankenPHP vhost template contains `ProxyPass /.well-known/acme-challenge/ !` before `ProxyPass /`.
- `config('laranode.apache_vhost_frankenphp_template')` returns correct path.
- `config('laranode.apache_vhost_template')` still returns original FPM path.

- [ ] Create `apache-vhost-frankenphp.template` (with ACME exception)
- [ ] Create `laranode-frankenphp.service.template`
- [ ] Add config key to `config/laranode.php`
- [ ] Verify template placeholders match `laranode-runtime-unit.sh` and `laranode-vhost-switch.sh` substitution patterns
- [ ] Commit: `feat(runtimes): Apache proxy (+ ACME exception) + systemd unit templates + config key`

---

### Task 6 (TDD): `InstallRuntimeService` + `SwitchRuntimeService` + `SwitchRuntimeOperationJob` + service guards

**Files:**
- Create: `app/Services/Websites/InstallRuntimeService.php` (includes `InstallRuntimeException`)
- Create: `app/Services/Websites/SwitchRuntimeService.php` (includes `SwitchRuntimeException`)
- Create: `app/Jobs/SwitchRuntimeOperationJob.php`
- Modify: `app/Services/Websites/UpdateWebsitePHPVersionService.php`
- Modify: `app/Services/Websites/DeleteWebsiteService.php`
- Create: `tests/Feature/Websites/SwitchRuntimeTest.php`
- Create: `tests/Feature/Websites/SwitchRuntimeBackToFpmTest.php`
- Create: `tests/Feature/Websites/SwitchRuntimeTeardownTest.php` (FIXED: ordering test)

**Scope:**

`InstallRuntimeService::ensureInstalled(string $runtime, callable $emit): void`:
- `$emit("Installing $runtime runtime...")` before.
- `Process::run(['sudo', config('laranode.laranode_bin_path') . '/laranode-runtime-install.sh', $runtime])`.
- Throws `InstallRuntimeException` if `$result->failed()`.

`SwitchRuntimeService::handle()` — ordered steps with explicit sequencing (FIXED: review fixes #5, #7, #9):
1. Validate `$runtime` in `['php-fpm', 'frankenphp']`. Throw `SwitchRuntimeException` otherwise.
2. If old `$website->runtime !== 'php-fpm'`: `laranode-runtime-manage.sh stop laranode-{old_runtime}-{domain}.service`.
3. If new `$runtime !== 'php-fpm'`:
   a. `$port = PortAllocatorService::allocate($website)`.
   b. `InstallRuntimeService::ensureInstalled($runtime, $emit)`.
   c. `laranode-runtime-unit.sh write-unit {domain} {port} {systemUsername} {document_root} {template_dir}` — writes unit + runs `daemon-reload` (FIXED: `daemon-reload` in script, sequenced before `enable`).
   d. `laranode-runtime-manage.sh enable laranode-frankenphp-{domain}.service`.
   e. `laranode-runtime-manage.sh start laranode-frankenphp-{domain}.service`.
   f. **On start success only**: assign `$port` for DB write (FIXED: port not saved on failed start, review fix #9). On failure: throw `SwitchRuntimeException`.
4. `laranode-vhost-switch.sh {domain} {runtime} {port_or_0} {systemUsername} {phpVersion} {document_root} {template_dir}` — writes Apache vhost only. Port 0 passed for FPM revert (accepted by script, FIXED: review fix #4).
5. `$website->update(['runtime' => $runtime, 'runtime_port' => $portOrNull])`.
6. Emit success line.

`SwitchRuntimeOperationJob extends OperationJob`:
```php
public function __construct(Operation $operation, public Website $website, public string $runtime)
{
    parent::__construct($operation);
}

protected function run(callable $emit): int
{
    $this->website->load('user'); // refresh after deserialization (FIXED: review fix #10)
    (new SwitchRuntimeService($this->website, $this->runtime, $emit))->handle();
    return 0;
}
```

`UpdateWebsitePHPVersionService::handle()` guard:
```php
if ($this->website->runtime !== 'php-fpm') {
    throw new \InvalidArgumentException('PHP version switching is not supported for this runtime.');
}
```

`DeleteWebsiteService::handle()` — `teardownRuntime()` FIRST (FIXED: review fix #5):
```php
public function handle(): void
{
    $this->teardownRuntime(); // FIRST — clean shutdown before files deleted
    $this->deleteWebsiteFiles();
    $this->syncPhpFpmPools();
    // ...
}

private function teardownRuntime(): void
{
    if ($this->website->runtime === 'php-fpm') return;
    $unit = "laranode-{$this->website->runtime}-{$this->website->url}.service";
    // validated removal through manage.sh (FIXED: no raw sudo rm, review fix #3)
    Process::run(['sudo', config('laranode.laranode_bin_path') . '/laranode-runtime-manage.sh', 'remove', $unit]);
    // Non-zero exit logged but does not block deletion.
}
```

**Feature test acceptance criteria:**

`SwitchRuntimeTest.php` (all `Process::fake()`):
- Owner + `runtime=frankenphp` → 200 JSON `{operation_id}`; Operation `queued` (sync: `succeeded`).
- Non-owner → 403.
- Unauthenticated → redirect to login.
- `runtime=swoole` → 422.
- Empty/missing runtime → 422.
- `runtime=../etc/passwd` → 422.
- `laranode-runtime-install.sh` exit 1 → Operation `failed`; `websites.runtime` unchanged.
- `laranode-vhost-switch.sh` exit 1 → Operation `failed`; `websites.runtime` unchanged.
- All scripts exit 0 → `websites.runtime = 'frankenphp'`; `runtime_port` in 9100–9499; Operation `succeeded`.

`SwitchRuntimeBackToFpmTest.php`:
- FrankenPHP → FPM: Operation `succeeded`; `runtime = 'php-fpm'`; `runtime_port = null`.
- Verifies `laranode-runtime-manage.sh stop` called for old unit.
- Verifies `laranode-vhost-switch.sh php-fpm 0 ...` called (FIXED: port 0 passed for FPM revert).
- Assert port 0 does not cause failure (FIXED: review fix #15).

`SwitchRuntimeTeardownTest.php` (FIXED: ordering test, review fix #12):
- FrankenPHP site deleted → assert `Process::fake()` received `laranode-runtime-manage.sh remove` call **before** any file-deletion process call (ordering verified by call index in `Process::fake()` recorded calls).
- php-fpm site deleted → `teardownRuntime()` is no-op; no `laranode-runtime-manage.sh` call.

**PHP version guard test (same file or `SwitchRuntimeTest.php`):**
- `PATCH /websites/{id}` on `runtime='frankenphp'` site → **redirect back with errors** (not JSON 422 — FIXED: review fix #8); `websites.php_version_id` unchanged.

- [ ] Write failing feature tests (all three files)
- [ ] Write `InstallRuntimeService`
- [ ] Write `SwitchRuntimeService` (9-step handle, correct sequencing)
- [ ] Write `SwitchRuntimeOperationJob` (with `load('user')`)
- [ ] Modify `UpdateWebsitePHPVersionService` (non-FPM guard)
- [ ] Modify `DeleteWebsiteService` (teardownRuntime FIRST, uses manage.sh remove)
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

`WebsiteController::update()` — catch non-FPM guard (FIXED: review fix #8):
```php
try {
    (new UpdateWebsitePHPVersionService($website, $validated))->handle();
} catch (\InvalidArgumentException $e) {
    return redirect()->back()->withErrors(['runtime' => $e->getMessage()]);
}
```

Route addition in `routes/web.php`:
```php
Route::post('/websites/{website}/runtime', [WebsiteController::class, 'switchRuntime'])
    ->middleware(['auth'])
    ->name('websites.runtime.switch');
```

**Acceptance criteria:**
- `php artisan route:list --name=websites.runtime.switch` → shows `POST /websites/{website}/runtime`.
- Task 6 feature tests (`SwitchRuntimeTest.php`) pass against this route.
- `PATCH /websites/{id}` on `runtime='frankenphp'` site → redirect back with errors (not JSON 422).
- `php artisan route:list` shows no duplicates.

- [ ] Add `switchRuntime()` to `WebsiteController`
- [ ] Update `update()` to catch `\InvalidArgumentException` → redirect back
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
- `const [runtimeOp, setRuntimeOp] = useState(null);` alongside `sslOp`.
- `switchRuntime(website, runtime)` handler: `axios.post(...)` → `setRuntimeOp(...)`.
- `runtimeOp` progress block (alongside `sslOp` block):
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
- New **Runtime** table column after PHP Version: badge + `<select>` + conditional info banner + PHP version `disabled` guard.

`Websites.runtime.test.jsx` (Vitest + RTL, 7 tests):
- Test 1: `runtime='frankenphp'` → `FrankenPHP` badge; info banner visible.
- Test 2: `runtime='php-fpm'` → `PHP-FPM` badge; info banner absent.
- Test 3: select `FrankenPHP` → `axios.post` called with correct route + body.
- Test 4: **`onDone` via useEffect chain (FIXED — review fix #12)** — do NOT call `onDone` prop
  directly. Simulate Echo WebSocket `completed` event on `window.Echo` mock → assert `useOperation`
  state transitions → assert `OperationProgress` fires `onDone` → assert `router.reload()` called.
  This tests the actual fire-once behavior from commit `ff018e9`.
- Test 5: `runtime='frankenphp'` → PHP version `<select>` is `disabled`.
- Test 6: `runtime='php-fpm'` → PHP version `<select>` NOT `disabled`.
- Test 7: `axios.post` resolves → `runtimeOp` progress block rendered.

Mock setup: `axios`, `router`, `route`, `window.Echo` (same pattern as `CreateDatabaseForm.test.jsx`
and existing `useOperation` tests).

**Acceptance criteria:**
- `npm run test -- --filter=Websites.runtime` → 7 tests green.
- `npm run build` → exits 0.

- [ ] Write failing Vitest tests (7)
- [ ] Modify `Index.jsx` (runtimeOp state + handler + OperationProgress + Runtime column)
- [ ] Verify Vitest tests pass
- [ ] `npm run build` succeeds
- [ ] Commit: `feat(runtimes): Websites index — runtime column, select, OperationProgress, info banner`

---

### Task 9 (TDD): System integration tests (`LARANODE_SYSTEM_TESTS=1`)

**Files:**
- Create: `tests/Feature/Websites/RuntimeSystemTest.php`

**Scope:**

All tests gated: `if (!env('LARANODE_SYSTEM_TESTS')) $this->markTestSkipped('system tests disabled');`

Preconditions (from `local-dev` container after Task 4 entrypoint changes):
- `a2enmod proxy proxy_http` enabled.
- `/etc/sudoers.d/laranode-runtimes` installed.
- `testuser_ln` system account exists.
- Test website row pointing to valid directory under `testuser_ln`'s homedir.

**13 tests** (FIXED: added tests for ACME path, corrupt binary, path-traversal, port-0, leading-dot):

1. **Install FrankenPHP binary** — exit 0; `/usr/local/bin/frankenphp --version` exits 0.
2. **Binary SHA-256 matches pinned value (FIXED — review fix #1)** — `sha256sum /usr/local/bin/frankenphp` output matches `FRANKENPHP_SHA256` value from install script.
3. **Idempotent install** — run again → exit 0, no re-download (file timestamp unchanged).
4. **Corrupt binary triggers re-download (FIXED — review fix #16)** — `echo 'garbage' > /usr/local/bin/frankenphp`; run install; assert binary replaced; `--version` exits 0.
5. **Switch site to FrankenPHP** — Operation `succeeded`; `systemctl is-active laranode-frankenphp-{domain}.service` → `active`; `runtime_port` in 9100–9499.
6. **Apache proxy non-502** — `curl` with `Host` header → HTTP status != 502.
7. **ACME challenge served from disk (FIXED — review fix #11)** — create `{docroot}/.well-known/acme-challenge/testtoken`; curl `/.well-known/acme-challenge/testtoken` with `Host: {domain}` → HTTP 200 with file content (not a proxy response). Verifies `ProxyPass !` exception works for 90-day renewal.
8. **Switch back to FPM** — Operation `succeeded`; unit `inactive`; `/etc/apache2/sites-available/{domain}.conf` lacks `ProxyPass`.
9. **Invalid runtime rejected** — `laranode-runtime-install.sh badvalue` → non-zero.
10. **Invalid unit name rejected** — `laranode-runtime-manage.sh start sshd.service` → non-zero.
11. **Path-traversal unit name rejected (FIXED — review fix #14)** — `laranode-runtime-manage.sh start 'laranode-frankenphp-foo/../../sshd.service'` → non-zero (regex forbids `/`).
12. **Port 0 accepted for FPM revert (FIXED — review fix #15)** — `laranode-vhost-switch.sh {domain} php-fpm 0 testuser_ln 8.4 /public_html {templates}` → exit 0; vhost written without `ProxyPass`.
13. **Domain leading-dot rejected (FIXED — review fix #3)** — `laranode-vhost-switch.sh ..evil.com frankenphp 9100 testuser_ln 8.4 /public_html {templates}` → non-zero.

Note: SSL coexistence (formerly test 6) is covered by test 7 (ACME path verification).
Full certbot-with-Pebble test may be added separately; skip if `PEBBLE_ACME_URL` absent.

**Acceptance criteria:**
- Standard suite (no flag): `php artisan test` → all green; system tests skipped.
- System suite: `LARANODE_SYSTEM_TESTS=1 php artisan test --filter=RuntimeSystemTest` → 13 passing inside container.

- [ ] Write `RuntimeSystemTest.php` (13 tests, gated)
- [ ] Run standard suite: all green (system tests skipped)
- [ ] Run system suite inside container: 13 passing
- [ ] Run Pint on new PHP file
- [ ] Commit: `test(runtimes): system integration tests (13) for FrankenPHP install + switch + ACME + security`

---

### Task 10: Final verification gate

**Files:** None (verification only).

**Steps (all must pass before merging):**
- [ ] `./vendor/bin/pest` → full Pest suite green, zero failures, system tests skipped.
- [ ] `npm run test` → full Vitest suite green, including `Websites.runtime.test.jsx` (7 tests).
- [ ] `./vendor/bin/pint --test` → zero formatting issues.
- [ ] `npm run build` → exits 0.
- [ ] Inside `local-dev` container: `LARANODE_SYSTEM_TESTS=1 php artisan test --filter=RuntimeSystemTest` → 13 passing.
- [ ] `php artisan route:list --name=websites.runtime.switch` → route present.
- [ ] `php artisan schedule:list` → `model:prune --model=App\Models\Operation` daily entry unchanged.
- [ ] `visudo -c -f /etc/sudoers.d/laranode-runtimes` → syntax valid.
- [ ] Confirm no raw `sudo rm` anywhere in new PHP code or scripts (grep check).
- [ ] Confirm `laranode-vhost-switch.sh` contains no unit-file write (grep check).
- [ ] Manual smoke: Websites page → Runtime column renders; select FrankenPHP → OperationProgress widget; curl site → non-502.

---

## File Inventory

```
database/migrations/2026_06_27_000002_add_runtime_to_websites_table.php   (new)
app/Models/Website.php                                                      (modify: $fillable, $casts, getRuntimeLabelAttribute)
app/Services/Websites/PortAllocatorService.php                              (new)
app/Http/Requests/SwitchRuntimeRequest.php                                  (new)
app/Services/Websites/InstallRuntimeService.php                             (new, includes InstallRuntimeException)
app/Services/Websites/SwitchRuntimeService.php                              (new, includes SwitchRuntimeException)
app/Jobs/SwitchRuntimeOperationJob.php                                      (new, load('user') in run())
app/Services/Websites/UpdateWebsitePHPVersionService.php                    (modify: non-FPM guard)
app/Services/Websites/DeleteWebsiteService.php                              (modify: teardownRuntime() FIRST, manage.sh remove)
app/Http/Controllers/WebsiteController.php                                  (modify: switchRuntime() + update() redirect guard)
config/laranode.php                                                         (modify: apache_vhost_frankenphp_template key)
routes/web.php                                                              (modify: websites.runtime.switch route)
laranode-scripts/bin/laranode-runtime-install.sh                            (new, SHA-256 pinned, corrupt-binary re-download)
laranode-scripts/bin/laranode-runtime-manage.sh                             (new, includes 'remove' sub-command)
laranode-scripts/bin/laranode-runtime-unit.sh                               (new, writes unit + daemon-reload)
laranode-scripts/bin/laranode-vhost-switch.sh                               (new, Apache vhost only, FPM port-skip)
laranode-scripts/templates/apache-vhost-frankenphp.template                 (new, ProxyPass ! for ACME)
laranode-scripts/templates/laranode-frankenphp.service.template             (new)
laranode-scripts/etc/sudoers.d/laranode-runtimes                            (new, 4 scripts, no raw rm glob)
laranode-scripts/bin/laranode-installer.sh                                  (modify: a2enmod + sudoers deploy)
local-dev/entrypoint-setup.sh                                               (modify: a2enmod + sudoers deploy)
resources/js/Pages/Websites/Index.jsx                                       (modify: Runtime column, runtimeOp state, OperationProgress)
tests/Feature/Websites/WebsiteRuntimeModelTest.php                          (new, Pest)
tests/Unit/PortAllocatorServiceTest.php                                     (new, Pest unit, includes race test)
tests/Unit/SwitchRuntimeRequestTest.php                                     (new, Pest unit)
tests/Feature/Websites/SwitchRuntimeTest.php                                (new, Pest feature)
tests/Feature/Websites/SwitchRuntimeBackToFpmTest.php                       (new, Pest feature, port-0 test)
tests/Feature/Websites/SwitchRuntimeTeardownTest.php                        (new, Pest feature, ordering test)
tests/Feature/Websites/RuntimeSystemTest.php                                (new, Pest, 13 tests, LARANODE_SYSTEM_TESTS=1)
resources/js/Pages/Websites/Websites.runtime.test.jsx                       (new, 7 Vitest tests, onDone via Echo chain)
```

Total: 30 files (11 new backend, 4 new scripts, 2 new templates, 1 new sudoers, 3 modified services/controller, 3 modified infrastructure files, 6 new Pest test files, 1 new Vitest test file).

---

## Back-compat Notes

- All existing rows default to `runtime='php-fpm'`, `runtime_port=null`. No functional change to any live site.
- `CreateWebsiteService`, `AddVhostEntryService`, `CreatePhpFpmPoolService` unchanged. New sites always start as `php-fpm`.
- `DeleteWebsiteService::syncPhpFpmPools()` unchanged. The new `teardownRuntime()` step runs before it and is a no-op for php-fpm sites.
- `Operation` rows with `type='runtime.switch'` appear in `/admin/operations` generically.
- `Operation` model's `MassPrunable` handles `runtime.*` rows automatically.
- `WebsitePolicy::update()` and `WebsitePolicy::delete()` already cover new authorization. No policy changes.

---

## Review Fixes Checklist

| # | Issue | Status |
|---|---|---|
| 1 | Binary integrity: no SHA-256 check | FIXED: pinned in install script; verified before chmod |
| 2 | SSL/ACME renewal breaks on FrankenPHP | FIXED: `ProxyPass !` exception in template + system test |
| 3 | sudoers rm unscoped; domain allows leading dot | FIXED: `remove` via manage.sh; tightened domain regex |
| 4 | Port 0 fails FPM revert validation | FIXED: port check skipped when runtime=php-fpm |
| 5 | teardownRuntime after deleteWebsiteFiles | FIXED: teardownRuntime called FIRST |
| 6 | vhost-switch writes both vhost and unit | FIXED: extracted to laranode-runtime-unit.sh |
| 7 | daemon-reload not sequenced | FIXED: runtime-unit.sh runs daemon-reload before returning |
| 8 | update() returns JSON 422 for Inertia | FIXED: redirect()->back()->withErrors() |
| 9 | runtime_port saved before start succeeds | FIXED: port saved only after start exits 0 |
| 10 | Stale serialized user relation in job | FIXED: run() calls load('user') |
| 11 | No ACME challenge path test | FIXED: system test 7 |
| 12 | No teardownRuntime ordering test | FIXED: SwitchRuntimeTeardownTest.php |
| 13 | onDone tested directly, not via Echo chain | FIXED: Vitest test 4 simulates Echo event |
| 14 | No path-traversal test for unit name suffix | FIXED: system test 11 |
| 15 | No test that port 0 accepted for FPM revert | FIXED: system test 12 + SwitchRuntimeBackToFpmTest |
| 16 | No test for corrupt binary re-download | FIXED: system test 4 |
