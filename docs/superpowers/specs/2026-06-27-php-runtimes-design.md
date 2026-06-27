# Sub-project #12 — Alternative PHP Runtimes (`php-runtimes`)

- **Date:** 2026-06-27
- **Status:** Draft (post-review, major-fixes applied)
- **Roadmap:** Phase N, sub-project #12 of `docs/superpowers/specs/2026-06-25-laranode-feature-roadmap.md`
- **Branch:** `feature/php-runtimes` (off `development`)
- **Phasing:** v1 = FrankenPHP only. Swoole/Octane is v2.

---

## Goal

Allow a per-site PHP runtime choice. Today every site runs under a PHP-FPM pool
(Unix socket, `SetHandler proxy:unix:...`). This feature adds two alternative runtimes —
**FrankenPHP** (v1) and **Swoole via Laravel Octane** (v2) — that spin up a persistent
app server on a loopback TCP port and let Apache reverse-proxy to it. The rest of the
panel stack (accounts, websites, filemanager, operations, SSL, firewall) is unchanged.

The panel stores `websites.runtime` (`php-fpm` | `frankenphp` | `swoole`). Switching a
site's runtime is an async `OperationJob` (long-running install + service management).
The per-site runtime process runs as a `systemd` unit, one unit per site.

---

## Phasing

| Phase | Scope |
|---|---|
| **v1 (this spec)** | FrankenPHP runtime only; data model; vhost proxy template; per-site systemd unit + management scripts; install script; UI in Websites section; Pest + Vitest + system integration tests. |
| **v2 (future)** | Swoole via Laravel Octane (`octane:start --server=swoole`); same architecture, second runtime key. |
| **v3 (future)** | RoadRunner; runtime health dashboard widget. |

Everything below describes v1 unless explicitly tagged `[v2]`.

---

## Architecture

Pattern: **Controller (thin) → FormRequest → `SwitchRuntimeService` → `OperationJob`
(queued, async) → sudo scripts + systemd**. The operation broadcasts live output via
`OperationUpdated` / `OperationProgress` on the Websites page, matching the SSL pattern
already used by `GenerateSslOperationJob`.

```
WebsiteController::switchRuntime()
  POST /websites/{website}/runtime
  |
  FormRequest::rules()  →  validate runtime value (enum)
  |
  Operation::create([type=runtime.switch, target=$website->url, status=queued])
  |
  SwitchRuntimeOperationJob::dispatch($operation, $website, $runtime)
    (queued → queue worker)
    |
    SwitchRuntimeJob::run($emit):
      1. InstallRuntimeService::ensureInstalled($runtime, $emit)
         → laranode-runtime-install.sh frankenphp
      2. if old runtime != php-fpm:
           laranode-runtime-manage.sh stop {old-unit}
      3. if new runtime != php-fpm:
           a. PortAllocatorService::allocate($website) → $port
           b. laranode-runtime-unit.sh write-unit {domain} {port} {user} {document_root} {template_dir}
              → writes /etc/systemd/system/laranode-frankenphp-{site}.service
              → runs systemctl daemon-reload
           c. laranode-runtime-manage.sh enable {new-unit}
           d. laranode-runtime-manage.sh start {new-unit}
              → ONLY on success: websites SET runtime_port={port}
      4. laranode-vhost-switch.sh {domain} {runtime} {port} {system_user} {php_version} {document_root} {template_dir}
         → rewrites /etc/apache2/sites-available/{domain}.conf ONLY
         → a2ensite; apache2ctl graceful
      5. if new runtime == php-fpm:
           CreatePhpFpmPoolService + AddVhostEntryService (existing)
      6. websites SET runtime={runtime}, runtime_port={port or null}
```

**Script responsibility boundary (FIXED — review fix #6):**
- `laranode-vhost-switch.sh` writes **only** the Apache vhost (`/etc/apache2/sites-available/`). Its sudoers grant covers only `/etc/apache2`.
- `laranode-runtime-unit.sh` writes **only** the systemd unit file (`/etc/systemd/system/`) and runs `daemon-reload`. Its sudoers grant covers only `/etc/systemd/system`.
- `laranode-runtime-manage.sh` handles `systemctl` verbs and unit file removal. Its sudoers grant covers `systemctl` and targeted `rm` of validated unit names.

This eliminates the dual-privilege-domain blast radius that the review flagged.

For php-fpm → php-fpm switches (runtime unchanged but PHP version changed), the
existing `UpdateWebsitePHPVersionService` path is unaffected.

---

## Data Model

### `websites` table — add two columns (new migration)

| Column | Type | Default | Notes |
|---|---|---|---|
| `runtime` | string(20) | `'php-fpm'` | `php-fpm` \| `frankenphp` \| `swoole` |
| `runtime_port` | unsignedSmallInteger, nullable | null | loopback port for the per-site app server; null for php-fpm |

Migration: `2026_06_27_000002_add_runtime_to_websites_table.php`

```php
Schema::table('websites', function (Blueprint $table) {
    $table->string('runtime', 20)->default('php-fpm')->after('php_version_id');
    $table->unsignedSmallInteger('runtime_port')->nullable()->after('runtime');
});
```

All existing rows default to `php-fpm` with `runtime_port = null`. No data migration
needed.

### `Website` model changes (`app/Models/Website.php`)

Add to `$fillable`:
```php
'runtime', 'runtime_port',
```

Add to `$casts`:
```php
'runtime_port' => 'integer',
```

Add a computed accessor (not stored, computed on boot from DB):
```php
public function getRuntimeLabelAttribute(): string
{
    return match ($this->runtime) {
        'frankenphp' => 'FrankenPHP',
        'swoole'     => 'Swoole (Octane)',
        default      => 'PHP-FPM',
    };
}
```

No new relations needed.

### Port allocation

Per-site loopback ports live in the range **9100–9499** (400 slots; the panel
enforces the range). Port assignment: on `switchRuntime`, the panel picks the
lowest unused port in this range by querying `websites.runtime_port` for current
non-null values and taking the first gap. The port is stored in `runtime_port`
**only after `systemctl start` succeeds** (see FIXED note in PortAllocatorService
section). When switching back to `php-fpm`, `runtime_port` is set back to `null`
(and the corresponding systemd unit is stopped + disabled + removed).

`9100–9499` does not conflict with:
- MySQL (3306), PostgreSQL (5432), Apache HTTP (80), Apache HTTPS (443)
- Reverb (8080 default), PHP-FPM (Unix sockets)

---

## Privileged Scripts

All scripts follow the existing pattern: `set -euo pipefail`, leading-dash/control-char
rejection, run-as only the intended user, and hard-coded argument count checks.

### `laranode-scripts/bin/laranode-runtime-install.sh` (new)

```
Usage: laranode-runtime-install.sh <runtime>
  runtime: frankenphp | swoole
```

Sub-commands:
- `frankenphp` — downloads the official FrankenPHP static binary from a **pinned
  GitHub release URL** (hard-coded version, e.g. `v1.x.y`) to `/usr/local/bin/frankenphp`,
  sets mode `0755`. **Verifies SHA-256 checksum against a hard-coded value in the script
  before marking the binary executable** (FIXED — review fix #1). Verifies `frankenphp --version`
  exits 0 as a secondary check. Idempotent: skips download if binary already exists AND
  `--version` exits 0. If the binary exists but `--version` fails (corrupt binary),
  re-downloads and re-verifies (FIXED — test gap for corrupt binary branch).
- `swoole` [v2] — `apt install php{version}-swoole` + `composer require laravel/octane`
  inside the site root.

**SHA-256 pinning (FIXED — was open question, now required for v1):**
```bash
FRANKENPHP_VERSION="1.x.y"
FRANKENPHP_SHA256="<sha256-hex>"   # pinned at script write time
FRANKENPHP_URL="https://github.com/dunglas/frankenphp/releases/download/v${FRANKENPHP_VERSION}/frankenphp-linux-x86_64"

# After download:
echo "${FRANKENPHP_SHA256}  /usr/local/bin/frankenphp" | sha256sum -c -
```

Upgrade path: edit `FRANKENPHP_VERSION` + `FRANKENPHP_SHA256` in the script, commit,
and re-run `laranode-runtime-install.sh frankenphp` on the server (idempotency check
will detect the version mismatch via `--version` output if desired, or a force-flag
may be added in v2).

Input validation: `$1` must match `^(frankenphp|swoole)$` exactly. Any other value
causes immediate non-zero exit without touching the system.

### `laranode-scripts/bin/laranode-runtime-manage.sh` (new)

```
Usage: laranode-runtime-manage.sh <action> <unit-name>
  action:    enable | disable | start | stop | restart | status | remove
  unit-name: laranode-frankenphp-{site}.service  (or swoole variant)
```

Wraps `systemctl $action $unit` for lifecycle verbs. The `remove` sub-command
performs `systemctl disable --now $unit && rm -f /etc/systemd/system/$unit`
(validated unit name only — FIXED: unit file removal goes through this validated
wrapper, never via inline `sudo rm` or a raw sudoers glob — review fix #3).

The unit name must match
`^laranode-(frankenphp|swoole)-[a-zA-Z0-9._-]+\.service$` — everything else is
rejected with non-zero exit before touching systemd. This prevents a compromised
PHP layer from manipulating arbitrary system units.

The action `remove` is the **only** way the panel deletes unit files. No raw
`sudo rm /etc/systemd/system/*.service` glob is added to any sudoers file.

### `laranode-scripts/bin/laranode-runtime-unit.sh` (new — FIXED: extracted from vhost-switch, review fix #6)

```
Usage: laranode-runtime-unit.sh <sub-command> <domain> <port> <system_user> <document_root> <template_dir>
  sub-command: write-unit
  domain:      validated site domain
  port:        loopback port (9100-9499)
  system_user: must end in _ln
```

Writes the systemd unit file from `laranode-frankenphp.service.template` to
`/etc/systemd/system/laranode-frankenphp-{domain}.service` and runs
`systemctl daemon-reload`. Its sudoers grant covers `/etc/systemd/system/laranode-*.service`
writes only — **not** `/etc/apache2`, which is covered by `laranode-vhost-switch.sh`.

Validation:
- `$1` (sub-command): must match `^(write-unit)$`; else exit 1.
- `$2` (domain): must match `^[a-zA-Z0-9][a-zA-Z0-9.-]+$` (FIXED — no leading dot, review fix #3 tightening).
- `$3` (port): `^[0-9]+$`, range 9100–9499.
- `$4` (system_user): must end in `_ln`.

### `laranode-scripts/bin/laranode-vhost-switch.sh` (new — FIXED: Apache vhost only, review fix #6)

```
Usage: laranode-vhost-switch.sh <domain> <runtime> <port> <system_user> <php_version> <document_root> <template_dir>
  runtime: php-fpm | frankenphp | swoole
  port:    loopback port (ignored when runtime=php-fpm)
```

Selects the correct vhost template and writes
`/etc/apache2/sites-available/{domain}.conf`, then runs `a2ensite {domain}` +
`apache2ctl graceful`. **Does not write any systemd unit file** (FIXED — review fix #6).

Argument validation:
- `domain`: must match `^[a-zA-Z0-9][a-zA-Z0-9.-]+$` — no leading dot or dash (FIXED — review fix #3).
- `runtime`: must match `^(php-fpm|frankenphp|swoole)$`.
- `port`: must match `^[0-9]+$`, **range check 9100–9499 is skipped when runtime=php-fpm** (FIXED — port 0 accepted for FPM revert path, review fix #4). For non-FPM runtimes, range is enforced.
- `system_user`: must end in `_ln`.

Script comment documents the FPM-port-skip branch explicitly:
```bash
if [ "$RUNTIME" != "php-fpm" ]; then
    [ "$PORT" -ge 9100 ] && [ "$PORT" -le 9499 ] || { echo "Port out of range"; exit 1; }
fi
```

### `etc/sudoers.d/laranode-runtimes` (new drop-in)

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

Note: `(ALL)` run-as for install (writes `/usr/local/bin`), vhost-switch (writes
`/etc/apache2`), runtime-unit (writes `/etc/systemd/system`), runtime-manage (calls
`systemctl`). These match the pattern already used in
`laranode-scripts/etc/sudoers.d/laranode-panel`.

**No raw `sudo rm` glob is added.** Unit file removal is entirely handled by
`laranode-runtime-manage.sh remove` (FIXED — review fix #3).

The drop-in is deployed by `laranode-installer.sh` (new `cp` + `chmod 0440` lines
alongside the existing sudoers deployment block).

---

## Apache Vhost Templates

### Existing template (unchanged): `laranode-scripts/templates/apache-vhost.template`

Used for `php-fpm` runtime (all existing sites). No changes.

### New template: `laranode-scripts/templates/apache-vhost-frankenphp.template`

```apache
<VirtualHost *:80>
    ServerName {domain}
    ServerAlias www.{domain}

    DocumentRoot /home/{user}/domains/{domain}{document_root}

    ErrorLog /home/{user}/logs/apache-error.log
    CustomLog /home/{user}/logs/apache-access.log combined

    # ACME challenge served from disk — must come before ProxyPass (FIXED — review fix #2)
    ProxyPass /.well-known/acme-challenge/ !
    <Directory /home/{user}/domains/{domain}{document_root}/.well-known/acme-challenge>
        Options None
        AllowOverride None
        Require all granted
    </Directory>

    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:{port}/
    ProxyPassReverse / http://127.0.0.1:{port}/

    <Directory /home/{user}/domains/{domain}{document_root}>
        Options FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

</VirtualHost>
```

Key differences from the FPM template:
- `ProxyPass /.well-known/acme-challenge/ !` exception placed **before** the
  catch-all `ProxyPass /` — Apache serves ACME challenge files from disk directly.
  This is required for certbot `--webroot` renewal to work on FrankenPHP sites
  (FIXED — SSL/ACME breakage, review fix #2). Without this exception, the 90-day
  renewal would fail silently as all `/.well-known/` requests would be forwarded
  to the app server which does not serve them from disk.
- `AllowOverride None` — `.htaccess` is irrelevant when proxying; the app server
  handles routing. Documented in the UI.
- No `<FilesMatch \.php$>` block — PHP files are served by the app server, not FPM.

Apache modules required: `proxy`, `proxy_http` (not `proxy_fcgi`).

### New template [v2]: `laranode-scripts/templates/apache-vhost-swoole.template`

Identical structure to the FrankenPHP template (including the ACME exception). Placeholder for v2.

### Config key

`config/laranode.php` gains a new entry:

```php
'apache_vhost_frankenphp_template' => base_path('laranode-scripts/templates/apache-vhost-frankenphp.template'),
```

---

## Systemd Unit Template

### New template: `laranode-scripts/templates/laranode-frankenphp.service.template`

```ini
[Unit]
Description=FrankenPHP app server for {domain} ({user})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={user}
Group={user}
WorkingDirectory=/home/{user}/domains/{domain}{document_root}
ExecStart=/usr/local/bin/frankenphp php-server --listen 127.0.0.1:{port} --root /home/{user}/domains/{domain}{document_root}
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=laranode-frankenphp-{domain}

[Install]
WantedBy=multi-user.target
```

Placeholders: `{user}` (system username, e.g. `alice_ln`), `{domain}`, `{port}`,
`{document_root}`.

Note: `{domain}` in `SyslogIdentifier` requires that domain validation in
`laranode-runtime-unit.sh` prevents leading dots (FIXED — tightened regex, review fix #3).
With `^[a-zA-Z0-9][a-zA-Z0-9.-]+$`, any rendered `SyslogIdentifier` is well-formed.

The unit runs **as the site user** (`{username}_ln`), not `www-data` or root.

The rendered unit file is written to
`/etc/systemd/system/laranode-frankenphp-{domain}.service` by
`laranode-runtime-unit.sh`. `systemctl daemon-reload` is run by that same script
**before** `laranode-runtime-manage.sh enable` is called (FIXED — daemon-reload
sequencing, review fix #7).

---

## PHP / Laravel Services

### `app/Services/Websites/SwitchRuntimeService.php` (new)

Not called directly from the controller. Lives inside the `OperationJob`.

**9-step handle() with explicit daemon-reload ordering (FIXED — review fix #7):**
1. Assert runtime is in `['php-fpm', 'frankenphp']`. Throw `SwitchRuntimeException` otherwise.
2. If old `$website->runtime !== 'php-fpm'`: call `laranode-runtime-manage.sh stop` for old unit.
3. If new `$runtime !== 'php-fpm'`:
   a. Call `PortAllocatorService::allocate($website)` → `$port`.
   b. Call `InstallRuntimeService::ensureInstalled($runtime, $emit)`.
   c. Call `laranode-runtime-unit.sh write-unit {domain} {port} ...` → writes unit + runs `daemon-reload`.
   d. Call `laranode-runtime-manage.sh enable laranode-frankenphp-{domain}.service`.
   e. Call `laranode-runtime-manage.sh start laranode-frankenphp-{domain}.service`.
      - **On success only**: record `$port` for DB update. (FIXED — port written to DB only after start succeeds, review fix #9.)
      - On failure: throw `SwitchRuntimeException` (port is not saved, no stale `runtime_port` row).
4. Call `laranode-vhost-switch.sh {domain} {runtime} {port_or_0} ...` → rewrites Apache vhost only.
5. `$website->update(['runtime' => $runtime, 'runtime_port' => $portOrNull])`.
6. Emit success line.

`$emit` is called before each step so live output flows to `OperationProgress`.

Exception class: `SwitchRuntimeException extends \Exception` declared in same file.

### `app/Services/Websites/PortAllocatorService.php` (new)

`allocate(Website $excludeWebsite): int`

```php
$used = Website::whereNotNull('runtime_port')
    ->where('id', '!=', $excludeWebsite->id)
    ->pluck('runtime_port')
    ->toArray();

for ($port = 9100; $port <= 9499; $port++) {
    if (!in_array($port, $used)) return $port;
}

throw new \RuntimeException('No available runtime ports in range 9100–9499.');
```

**Concurrency risk (FIXED — DB update ordering, review fix #9):** The race condition
where two concurrent jobs allocate the same port and both write `runtime_port` to the
DB is mitigated by the ordering fix: `runtime_port` is written to the DB only after
`systemctl start` succeeds. If the second job's start fails (port already bound), the
second site's `runtime_port` is never written — it remains `null`. The port is
therefore not permanently burned. This is not a full fix for the race (the first job's
port could still be allocated by a third concurrent job before the first job's start
completes), but it eliminates the worst-case data corruption. v2 should add a DB-level
unique constraint on `runtime_port` with `lockForUpdate`.

### `app/Jobs/SwitchRuntimeOperationJob.php` (new)

Extends `OperationJob`. The job uses `SerializesModels`. Call `$this->website->load('user')`
at the top of `run()` to ensure the `user` relation is fresh (not the restricted-select
version that may have been serialized — FIXED, review fix #10).

```php
class SwitchRuntimeOperationJob extends OperationJob
{
    public function __construct(
        Operation $operation,
        public Website $website,
        public string $runtime,
    ) {
        parent::__construct($operation);
    }

    protected function run(callable $emit): int
    {
        $this->website->load('user'); // ensure fresh user relation after deserialization
        (new SwitchRuntimeService($this->website, $this->runtime, $emit))->handle();
        return 0;
    }
}
```

Mirrors `GenerateSslOperationJob` exactly (modulo the `load('user')` guard).

### `app/Services/Websites/InstallRuntimeService.php` (new)

`ensureInstalled(string $runtime, callable $emit): void`

Calls `laranode-runtime-install.sh {runtime}` via `Process::run(['sudo', ...])`.
Throws `InstallRuntimeException` on non-zero exit.

### `app/Services/Websites/DeleteWebsiteService.php` (modify)

**`teardownRuntime()` called FIRST in `handle()`, before `deleteWebsiteFiles()`
(FIXED — review fix #5):**

```php
public function handle(): void
{
    $this->teardownRuntime();   // FIRST — give process clean shutdown before files vanish
    $this->deleteWebsiteFiles();
    $this->syncPhpFpmPools();
    // ... rest of handle
}

private function teardownRuntime(): void
{
    if ($this->website->runtime === 'php-fpm') return;

    $runtime = $this->website->runtime;
    $url     = $this->website->url;
    $unit    = "laranode-{$runtime}-{$url}.service";

    // stop+disable+remove via the validated wrapper (FIXED — no inline sudo rm, review fix #3)
    Process::run(['sudo', config('laranode.laranode_bin_path') . '/laranode-runtime-manage.sh', 'remove', $unit]);
    // Non-zero exit is logged but does not block deletion; files may already be gone.
}
```

`laranode-runtime-manage.sh remove` validates the unit name before calling
`systemctl disable --now` + `rm -f`. No raw `sudo rm` is used anywhere.

### `app/Services/Websites/UpdateWebsitePHPVersionService.php` (modify)

Guard at top of `handle()`:
```php
if ($this->website->runtime !== 'php-fpm') {
    throw new \InvalidArgumentException('PHP version switching is not supported for this runtime.');
}
```

**Controller handling (FIXED — review fix #8):** `WebsiteController::update()` must
catch `\InvalidArgumentException` and return `redirect()->back()->withErrors(['runtime' =>
'PHP version switching is not supported for this runtime.'])`, **not** a JSON 422.
Returning JSON from an Inertia redirect-follow endpoint breaks the Inertia client.

---

## Controller and Request

### `WebsiteController` changes (`app/Http/Controllers/WebsiteController.php`)

Add one new method:

```php
public function switchRuntime(SwitchRuntimeRequest $request, Website $website)
{
    Gate::authorize('update', $website);

    $runtime = $request->validated()['runtime'];

    $operation = Operation::create([
        'user_id'  => $request->user()->id,
        'type'     => 'runtime.switch',
        'target'   => $website->url,
        'status'   => 'queued',
    ]);

    SwitchRuntimeOperationJob::dispatch($operation, $website, $runtime);

    return response()->json(['operation_id' => $operation->id]);
}
```

Modify `update()` to catch the non-FPM guard exception (FIXED — review fix #8):

```php
// In update(), wrap the service call:
try {
    (new UpdateWebsitePHPVersionService($website, $validated))->handle();
} catch (\InvalidArgumentException $e) {
    return redirect()->back()->withErrors(['runtime' => $e->getMessage()]);
}
```

### `app/Http/Requests/SwitchRuntimeRequest.php` (new)

```php
public function rules(): array
{
    return [
        'runtime' => ['required', 'string', Rule::in(['php-fpm', 'frankenphp'])],
        // v2: Rule::in(['php-fpm', 'frankenphp', 'swoole'])
    ];
}

public function authorize(): bool
{
    return auth()->check();
    // Gate::authorize in controller handles ownership
}
```

### Routes (modify `routes/web.php`)

```php
Route::post('/websites/{website}/runtime', [WebsiteController::class, 'switchRuntime'])
    ->middleware(['auth'])
    ->name('websites.runtime.switch');
```

---

## Frontend (React JSX)

### `resources/js/Pages/Websites/Index.jsx` changes

Mirror the `sslOp` pattern with `runtimeOp` state. `OperationProgress` is the
existing component backed by `useOperation` hook — no new hooks or components needed.

**Vitest test 4 (onDone, FIXED — review fix #13):** The test must simulate the
WebSocket completion event flowing through `useOperation` → `OperationProgress` →
`onDone`, not call `onDone()` directly. This matches the `ff018e9` fire-once fix for
`onDone` already verified in the existing suite.

```jsx
const [runtimeOp, setRuntimeOp] = useState(null);

const switchRuntime = (website, runtime) => {
    axios.post(route('websites.runtime.switch', { website: website.id }), { runtime })
        .then((res) => setRuntimeOp({ id: res.data.operation_id, url: website.url, runtime }))
        .catch(() => toast.error('Failed to start runtime switch'));
};

// Render alongside sslOp block:
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

Runtime column in the table: badge + `<select>` + info banner + PHP version disabled
guard (unchanged from original spec).

---

## Installer Changes

`laranode-scripts/bin/laranode-installer.sh` additions (before first `systemctl restart apache2`):
1. `a2enmod proxy proxy_http`
2. Deploy: `cp -f "$PANEL/laranode-scripts/etc/sudoers.d/laranode-runtimes" /etc/sudoers.d/laranode-runtimes && chmod 0440 /etc/sudoers.d/laranode-runtimes`

`local-dev/entrypoint-setup.sh` additions:
1. `a2enmod proxy proxy_http`
2. Deploy: `cp -f "$PANEL/laranode-scripts/etc/sudoers.d/laranode-runtimes" /etc/sudoers.d/laranode-runtimes && chmod 440 /etc/sudoers.d/laranode-runtimes`

---

## Operation Type

New `Operation.type` values:
- `runtime.switch` — switching a site to any runtime (php-fpm, frankenphp, swoole)

These render automatically in `/admin/operations` without code changes.

---

## Security

### Attack surface

Switching a runtime: rewrites an Apache vhost, writes a systemd unit file, starts a
new process as the site user, and installs a binary. Each step is wrapped in a
privileged script that validates its arguments.

### Mitigations

1. **Runtime enum validation** — `SwitchRuntimeRequest` enforces
   `Rule::in(['php-fpm', 'frankenphp'])`. Scripts additionally validate with regex.

2. **Port range confinement** — `PortAllocatorService` only assigns ports 9100–9499.
   `laranode-vhost-switch.sh` validates the port argument when `runtime != php-fpm`.

3. **Domain validation (FIXED)** — `laranode-vhost-switch.sh` and `laranode-runtime-unit.sh`
   validate domain against `^[a-zA-Z0-9][a-zA-Z0-9.-]+$` — **no leading dot or dash**
   (review fix #3). Rejects `..evil.com`, `../../etc/passwd`, and any value that would
   produce a malformed `SyslogIdentifier` or confuse `a2ensite`.

4. **Unit name confinement** — `laranode-runtime-manage.sh` validates unit name against
   `^laranode-(frankenphp|swoole)-[a-zA-Z0-9._-]+\.service$`. Rejects `sshd.service`,
   path traversal attempts, etc.

5. **Unit file removal via validated wrapper (FIXED)** — Unit file deletion goes
   through `laranode-runtime-manage.sh remove` only, which validates the unit name
   before `rm -f`. No raw `sudo rm` glob in sudoers (review fix #3).

6. **Script responsibility boundary (FIXED)** — `laranode-vhost-switch.sh` covers
   only `/etc/apache2`. `laranode-runtime-unit.sh` covers only `/etc/systemd/system`.
   Each script's sudoers grant is scoped accordingly (review fix #6).

7. **FrankenPHP binary integrity (FIXED — was open question, now required)** —
   `laranode-runtime-install.sh` pins a SHA-256 checksum in the script. The binary is
   verified before it becomes executable. A compromised CDN serving a different binary
   will fail the checksum check and the install exits non-zero (review fix #1).

8. **FPM pool kept on runtime switch** — existing PHP-FPM pool left in place on
   FrankenPHP switch. Clean rollback path: stop unit + rewrite vhost. No blast radius.

9. **Ownership check** — `Gate::authorize('update', $website)` gates the controller.

10. **Port written to DB only after start succeeds (FIXED)** — prevents stale
    `runtime_port` rows that would permanently burn ports (review fix #9).

---

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **SSL/ACME renewal breaks on FrankenPHP sites (FIXED)** | High | `ProxyPass /.well-known/acme-challenge/ !` exception in template. Apache serves ACME challenge files from disk. 90-day renewal works without changes to `laranode-ssl-manager.sh`. |
| **teardownRuntime called after files deleted (FIXED)** | High | `teardownRuntime()` is called FIRST in `DeleteWebsiteService::handle()`, before `deleteWebsiteFiles()`. Process gets clean shutdown before WorkingDirectory vanishes. |
| **Port collision (partial fix)** | Medium | `runtime_port` written to DB only after `systemctl start` success. Port not burned on failed start. Full fix (DB unique constraint + `lockForUpdate`) deferred to v2. |
| **Runtime crash leaves proxy 502** | High | `Restart=on-failure` + `RestartSec=5s`. No per-site health monitoring in v1 (v2 concern). |
| **FPM socket + FrankenPHP both listening** | Low | FPM pool kept; Apache vhost determines active backend. No conflict. |
| **Graceful reload vs. in-flight requests** | Medium | `apache2ctl graceful`. FrankenPHP starts before vhost is switched. |
| **FrankenPHP binary compromise via CDN/MITM (FIXED)** | High | SHA-256 pinned in install script. Mismatch = exit 1. |
| **Domain leading-dot allows malformed SyslogIdentifier (FIXED)** | Low | Tightened regex to `^[a-zA-Z0-9][a-zA-Z0-9.-]+$` in both vhost-switch and runtime-unit. |
| **port 0 fails FPM revert validation (FIXED)** | High | Port range check skipped when `runtime=php-fpm` in `laranode-vhost-switch.sh`. |
| **daemon-reload not sequenced (FIXED)** | Medium | `laranode-runtime-unit.sh` runs `daemon-reload` before returning; `laranode-runtime-manage.sh enable` is called after. |
| **`update()` returns JSON for Inertia redirect (FIXED)** | Medium | `\InvalidArgumentException` caught in `update()`, returns `redirect()->back()->withErrors(...)`. |
| **Website model serialization in job** | Low | `run()` calls `$this->website->load('user')` to refresh relation after deserialization. |
| **`laranode-runtime-install.sh` downloads from internet** | Medium | v1: documented. v2: offline package path. |

---

## Testing Strategy

### Pest — unit tests (`tests/Unit/`)

**`tests/Unit/PortAllocatorServiceTest.php`** (new)
- No sites → allocates 9100.
- Port 9100 occupied (other site) → allocates 9101.
- All 9100–9499 occupied → throws `\RuntimeException`.
- Own `runtime_port` same id → excluded from used set, does not block self.
- **Concurrent race test (FIXED — review fix #11):** assert that two concurrent
  `PortAllocatorService::allocate()` calls for different sites do not write the same
  `runtime_port` to the DB (simulated via two separate transactions reading the same
  initial state). Test asserts that after the second job's `systemctl start` fails,
  the second site's `runtime_port` remains `null`.

**`tests/Unit/SwitchRuntimeRequestTest.php`** (new)
- `php-fpm`, `frankenphp` pass validation.
- `swoole` fails in v1.
- Empty, missing, path-traversal, injection strings all fail.

### Pest — feature tests (`tests/Feature/Websites/`)

**`tests/Feature/Websites/SwitchRuntimeTest.php`** (new, all using `Process::fake()`)

- Owner, `runtime=frankenphp` → 200 JSON `{operation_id}`.
- Non-owner → 403.
- Unauthenticated → redirect to login.
- `runtime=swoole` → 422.
- Empty / missing runtime → 422.
- Path-traversal runtime → 422.
- `laranode-runtime-install.sh` exit 1 → Operation `failed`; `websites.runtime` unchanged.
- `laranode-vhost-switch.sh` exit 1 → Operation `failed`; `websites.runtime` unchanged.
- All scripts exit 0 → `websites.runtime = 'frankenphp'`; `runtime_port` in 9100–9499; Operation `succeeded`.

**`tests/Feature/Websites/SwitchRuntimeBackToFpmTest.php`** (new)
- FrankenPHP → FPM: Operation `succeeded`; `runtime = 'php-fpm'`; `runtime_port = null`.
- Verifies `laranode-runtime-manage.sh stop` called for old unit.
- Verifies `laranode-vhost-switch.sh php-fpm 0 ...` called (port 0 for FPM revert).
- **Verifies port 0 is not rejected** (FIXED — review fix #15).

**`tests/Feature/Websites/SwitchRuntimeTeardownTest.php`** (new)
- FrankenPHP site deleted → `teardownRuntime()` called BEFORE `deleteWebsiteFiles()`
  (FIXED — review fix #12). Assert `Process::fake()` received `laranode-runtime-manage.sh
  remove` call before any file-deletion process call.
- php-fpm site deleted → `teardownRuntime()` is a no-op (no manage.sh call).

**UpdateWebsitePHPVersionService guard test:**
- `PATCH /websites/{id}` on `runtime='frankenphp'` site → redirect back with error
  (not 422 JSON — FIXED, review fix #8).

### Pest — system integration (`tests/Feature/Websites/RuntimeSystemTest.php`)

Gated: `LARANODE_SYSTEM_TESTS=1`.

Tests (10 total):
1. **Install FrankenPHP binary** — exit 0; `/usr/local/bin/frankenphp --version` exits 0.
2. **Binary SHA-256 integrity verified** — manually compute sha256sum and assert matches
   pinned value in script (FIXED — review fix #1 test coverage).
3. **Idempotent install** — run again → exit 0, no re-download.
4. **Corrupt binary triggers re-download (FIXED — review fix #16)** — corrupt the binary
   (`echo 'garbage' > /usr/local/bin/frankenphp`); run install again; assert binary
   is replaced and `--version` exits 0 afterwards.
5. **Switch site to FrankenPHP** — dispatch job; Operation `succeeded`;
   `systemctl is-active laranode-frankenphp-{domain}.service` → `active`.
6. **Apache proxy responds (non-502)** — `curl` returns HTTP status that is not 502.
7. **ACME challenge served from disk (FIXED — review fix #11)** — with site on FrankenPHP,
   create a dummy file at `{docroot}/.well-known/acme-challenge/testtoken`; assert
   `curl http://127.0.0.1/.well-known/acme-challenge/testtoken -H "Host: {domain}"`
   returns `200` with the file content, **not** a proxy response. This verifies that
   the `ProxyPass !` exception works for 90-day renewal.
8. **Switch back to FPM** — Operation `succeeded`; unit `inactive`; vhost lacks `ProxyPass`.
9. **Invalid runtime rejected** — `laranode-runtime-install.sh badvalue` → non-zero.
10. **Invalid unit name rejected** — `laranode-runtime-manage.sh start sshd.service` →
    non-zero.
11. **Path-traversal unit name rejected (FIXED — review fix #14)** — `laranode-runtime-manage.sh
    start 'laranode-frankenphp-foo/../../sshd.service'` → non-zero (regex forbids `/`).
12. **Port 0 accepted for FPM runtime (FIXED — review fix #15)** — `laranode-vhost-switch.sh
    {domain} php-fpm 0 ...` → exit 0; vhost written without ProxyPass.
13. **Domain leading-dot rejected (FIXED — review fix #3)** — `laranode-vhost-switch.sh
    ..evil.com ...` → non-zero.

### Vitest — component tests

**`resources/js/Pages/Websites/Websites.runtime.test.jsx`** (new, 7 tests)
- Test 1: `runtime='frankenphp'` → Runtime column shows `FrankenPHP` badge; info banner visible.
- Test 2: `runtime='php-fpm'` → badge shows `PHP-FPM`; info banner absent.
- Test 3: select `FrankenPHP` → `axios.post` called with correct route + body.
- Test 4: **`onDone` via useEffect chain (FIXED — review fix #12)** — simulate WebSocket
  `completed` event through the Echo mock → `useOperation` state updates → `OperationProgress`
  fires `onDone` → assert `router.reload()` called. Do not call `onDone()` directly on the
  component prop.
- Test 5: `runtime='frankenphp'` → PHP version `<select>` is `disabled`.
- Test 6: `runtime='php-fpm'` → PHP version `<select>` NOT `disabled`.
- Test 7: renders `runtimeOp` progress block after `axios.post` resolves.

---

## Integration with Existing Stack

### `OperationJob` base class

No changes to `OperationJob`, `OperationUpdated`, `useOperation`, or `OperationProgress`.

### `WebsitePolicy`

No changes to `app/Policies/WebsitePolicy.php`.

### Operations admin page

`/admin/operations` renders `type=runtime.switch` rows automatically. No code changes.

### SSL coexistence (FIXED)

The `ProxyPass /.well-known/acme-challenge/ !` exception in the FrankenPHP template
ensures certbot `--webroot` works for both initial issuance and 90-day renewal.
`laranode-ssl-manager.sh create_ssl_vhost()` copies inner content from the base vhost;
the ACME exception and `ProxyPass` directives survive the copy into the `:443` block.
System test 7 (ACME challenge test) verifies this path before merge.

### PHP Version selector

For FrankenPHP sites: PHP version `<select>` is disabled in UI. `PATCH` on non-FPM
site → `redirect()->back()->withErrors(...)` (FIXED — not JSON 422).

---

## Back-compat

- All existing rows: `runtime = 'php-fpm'`, `runtime_port = null`. No functional change.
- `CreateWebsiteService`, `AddVhostEntryService`, `CreatePhpFpmPoolService` unchanged.
- `DeleteWebsiteService::syncPhpFpmPools()` unchanged. `teardownRuntime()` is additive,
  runs first, and is a no-op for php-fpm sites.
- `Operation` model's `MassPrunable` handles `runtime.*` rows automatically.

---

## File Inventory

```
database/migrations/2026_06_27_000002_add_runtime_to_websites_table.php  (new)
app/Models/Website.php                                                     (modify: fillable, casts, getRuntimeLabelAttribute)
app/Http/Controllers/WebsiteController.php                                 (modify: add switchRuntime() + update() redirect guard)
app/Http/Requests/SwitchRuntimeRequest.php                                 (new)
app/Services/Websites/SwitchRuntimeService.php                             (new, includes SwitchRuntimeException)
app/Services/Websites/InstallRuntimeService.php                            (new, includes InstallRuntimeException)
app/Services/Websites/PortAllocatorService.php                             (new)
app/Services/Websites/UpdateWebsitePHPVersionService.php                   (modify: reject non-FPM sites)
app/Services/Websites/DeleteWebsiteService.php                             (modify: teardownRuntime() FIRST)
app/Jobs/SwitchRuntimeOperationJob.php                                     (new, load('user') in run())
config/laranode.php                                                        (modify: add apache_vhost_frankenphp_template)
routes/web.php                                                             (modify: add runtime.switch route)
laranode-scripts/bin/laranode-runtime-install.sh                           (new, SHA-256 pinned)
laranode-scripts/bin/laranode-runtime-manage.sh                            (new, includes 'remove' sub-command)
laranode-scripts/bin/laranode-runtime-unit.sh                              (new, writes unit file + daemon-reload)
laranode-scripts/bin/laranode-vhost-switch.sh                              (new, Apache vhost only, FPM port-skip)
laranode-scripts/templates/apache-vhost-frankenphp.template                (new, ProxyPass ! for ACME)
laranode-scripts/templates/laranode-frankenphp.service.template            (new)
laranode-scripts/etc/sudoers.d/laranode-runtimes                           (new, 4 scripts)
laranode-scripts/bin/laranode-installer.sh                                 (modify: a2enmod proxy proxy_http + deploy runtimes sudoers)
local-dev/entrypoint-setup.sh                                              (modify: a2enmod proxy proxy_http + deploy runtimes sudoers)
resources/js/Pages/Websites/Index.jsx                                      (modify: runtime column + runtimeOp state + OperationProgress)
tests/Feature/Websites/WebsiteRuntimeModelTest.php                         (new)
tests/Unit/PortAllocatorServiceTest.php                                    (new, includes race test)
tests/Unit/SwitchRuntimeRequestTest.php                                    (new)
tests/Feature/Websites/SwitchRuntimeTest.php                               (new)
tests/Feature/Websites/SwitchRuntimeBackToFpmTest.php                      (new, port-0 test)
tests/Feature/Websites/SwitchRuntimeTeardownTest.php                       (new, ordering test)
tests/Feature/Websites/RuntimeSystemTest.php                               (new, 13 tests, LARANODE_SYSTEM_TESTS=1)
resources/js/Pages/Websites/Websites.runtime.test.jsx                      (new, 7 Vitest tests)
```

Total: ~31 files (11 new backend, 4 new scripts + templates, 1 new sudoers, 2 modified services, 1 modified controller, 4 modified infrastructure files, 6 new Pest test files, 1 new Vitest).

---

## Review Fixes Applied

| # | Issue | Fix |
|---|---|---|
| 1 | No binary integrity check | SHA-256 pinned in `laranode-runtime-install.sh`; verified before `chmod +x`; corrupt-binary branch re-downloads |
| 2 | SSL/ACME challenge breaks for FrankenPHP sites | `ProxyPass /.well-known/acme-challenge/ !` added before catch-all in FrankenPHP vhost template |
| 3 | sudoers `rm` unscoped for unit file removal; domain allows leading dot | Unit removal via `laranode-runtime-manage.sh remove` (validated); domain regex tightened to `^[a-zA-Z0-9][a-zA-Z0-9.-]+$` |
| 4 | Port 0 fails validation on FPM revert | Port range check skipped when `runtime=php-fpm` in `laranode-vhost-switch.sh` |
| 5 | `teardownRuntime()` called after `deleteWebsiteFiles()` | `teardownRuntime()` moved to FIRST step in `DeleteWebsiteService::handle()` |
| 6 | `laranode-vhost-switch.sh` writes both vhost and unit (dual privilege) | Unit writing extracted to `laranode-runtime-unit.sh`; `laranode-vhost-switch.sh` writes Apache vhost only |
| 7 | `daemon-reload` not explicitly sequenced in service handle() | `laranode-runtime-unit.sh` runs `daemon-reload` internally before returning; service calls `enable` after |
| 8 | `update()` returns JSON 422 for Inertia redirect | `\InvalidArgumentException` caught → `redirect()->back()->withErrors(...)` |
| 9 | `runtime_port` written to DB before `systemctl start` succeeds | Port saved to DB only after `systemctl start` exits 0 |
| 10 | Job may use stale serialized user relation | `run()` calls `$this->website->load('user')` on deserialization |
| 11 | No ACME challenge path test on FrankenPHP vhost | System test 7: curl `/.well-known/acme-challenge/testtoken` through Apache → assert 200 from disk |
| 12 | No `teardownRuntime()` ordering test | `SwitchRuntimeTeardownTest.php`: assert manage.sh `remove` called before file-deletion process call |
| 13 | Vitest `onDone` tests `onDone` directly, not via useEffect chain | Test 4 simulates Echo WebSocket event → `useOperation` → `OperationProgress` → `onDone` |
| 14 | No path-traversal test for unit name | System test 11: `laranode-frankenphp-foo/../../sshd.service` → non-zero |
| 15 | No test that port 0 accepted for FPM revert | System test 12 + `SwitchRuntimeBackToFpmTest` assert port 0 not rejected |
| 16 | No test for corrupt binary re-download | System test 4: corrupt binary + re-run install → binary replaced, `--version` exits 0 |

---

## Open Questions (remaining)

1. **FrankenPHP built-in server vs. worker mode** — spec uses `frankenphp php-server`
   (no `laravel/octane` required). Confirm this is sufficient for v1 before Task 4
   writes the systemd unit template.

2. **Per-site runtime health monitoring** — when a FrankenPHP unit crashes, Apache
   returns 502. Dashboard per-site unit status deferred to v2.

3. **Port persistence across site rename** — URL changes not currently supported; out
   of scope for v1.

4. **FrankenPHP binary location** — `/usr/local/bin/frankenphp`. Consider `/opt/laranode/bin/`
   to avoid polluting system PATH. Decide before Task 4.

5. **Swoole/Octane v2 scope** — panel cannot assume `laravel/octane` is installed.
   v2 must check before dispatch. Design TBD.

6. **Port range unique constraint** — v2: add DB-level `unique` on `runtime_port` +
   `lockForUpdate` in `PortAllocatorService` to fully close the race condition.
