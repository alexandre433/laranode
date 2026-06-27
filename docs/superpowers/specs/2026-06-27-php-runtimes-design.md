# Sub-project #12 — Alternative PHP Runtimes (`php-runtimes`)

- **Date:** 2026-06-27
- **Status:** Draft
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
           a. write /etc/systemd/system/laranode-frankenphp-{site}.service
              from template: laranode-frankenphp.service.template
           b. laranode-runtime-manage.sh enable+start {new-unit}
      4. laranode-vhost-switch.sh {domain} {runtime} {port}
         → rewrites /etc/apache2/sites-available/{domain}.conf
         → a2ensite; apache2ctl graceful
      5. if new runtime == php-fpm:
           CreatePhpFpmPoolService + AddVhostEntryService (existing)
      6. websites SET runtime={runtime}, runtime_port={port}
```

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
non-null values and taking the first gap. The port is stored in `runtime_port`.
When switching back to `php-fpm`, `runtime_port` is set back to `null` (and the
corresponding systemd unit is stopped + disabled).

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
- `frankenphp` — downloads the official FrankenPHP static binary from GitHub releases
  to `/usr/local/bin/frankenphp`, sets mode `0755`, verifies `frankenphp --version`
  exits 0. Idempotent: skips if binary already exists and `--version` succeeds. For v1,
  a pinned release URL is hard-coded in the script (e.g. `v1.x.y`); updating requires
  editing the script and re-running install.
- `swoole` [v2] — `apt install php{version}-swoole` + `composer require laravel/octane`
  inside the site root.

Input validation: `$1` must match `^(frankenphp|swoole)$` exactly. Any other value
causes immediate non-zero exit without touching the system.

### `laranode-scripts/bin/laranode-runtime-manage.sh` (new)

```
Usage: laranode-runtime-manage.sh <action> <unit-name>
  action:    enable | disable | start | stop | restart | status
  unit-name: laranode-frankenphp-{site}.service  (or swoole variant)
```

Wraps `systemctl $action $unit`. The unit name must match
`^laranode-(frankenphp|swoole)-[a-zA-Z0-9._-]+\.service$` — everything else is
rejected with non-zero exit before touching systemd. This prevents a compromised
PHP layer from manipulating arbitrary system units.

### `laranode-scripts/bin/laranode-vhost-switch.sh` (new)

```
Usage: laranode-vhost-switch.sh <domain> <runtime> <port> <system_user> <php_version> <document_root> <template_dir>
  runtime: php-fpm | frankenphp | swoole
  port:    loopback port (ignored when runtime=php-fpm)
```

Selects the correct vhost template (see below) and writes
`/etc/apache2/sites-available/{domain}.conf`, then runs `a2ensite {domain}` +
`apache2ctl graceful`. All arguments are validated:
- `domain`: must match `^[a-zA-Z0-9.-]+$`, no leading dash
- `runtime`: must match `^(php-fpm|frankenphp|swoole)$`
- `port`: must match `^[0-9]+$`, numeric range 9100–9499
- `system_user`: must end in `_ln`

The existing `laranode-add-vhost.sh` is **not** modified; `laranode-vhost-switch.sh`
is its replacement for runtime-switching operations only. New website creation
continues to use `AddVhostEntryService` → `laranode-add-vhost.sh`.

### `etc/sudoers.d/laranode-runtimes` (new drop-in)

```sudoers
Defaults!/home/laranode_ln/panel/laranode-scripts/bin/laranode-runtime-install.sh !requiretty
Defaults!/home/laranode_ln/panel/laranode-scripts/bin/laranode-runtime-manage.sh !requiretty
Defaults!/home/laranode_ln/panel/laranode-scripts/bin/laranode-vhost-switch.sh !requiretty

www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-runtime-install.sh
www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-runtime-manage.sh
www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-vhost-switch.sh
```

Note: `(ALL)` run-as for install and vhost-switch because they write system paths
(`/usr/local/bin`, `/etc/apache2`, `/etc/systemd/system`). `runtime-manage.sh`
similarly needs `(ALL)` to call `systemctl`. These match the pattern already used in
`laranode-scripts/etc/sudoers.d/laranode-panel`.

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
- Uses `ProxyPass` / `ProxyPassReverse` to the loopback port.
- `AllowOverride None` — `.htaccess` is irrelevant when proxying; the app server
  handles routing. This is intentional: FrankenPHP/Octane apps must route via the
  framework, not Apache rewrites. Document this in the UI (see UI section).
- No `<FilesMatch \.php$>` block — PHP files are served by the app server, not FPM.

Apache modules required (must be enabled by the install script):
`proxy`, `proxy_http` (not `proxy_fcgi`). The installer enables both via `a2enmod`.

### New template [v2]: `laranode-scripts/templates/apache-vhost-swoole.template`

Identical structure to the FrankenPHP template. Placeholder for v2.

### Config key

`config/laranode.php` gains a new entry:

```php
'apache_vhost_frankenphp_template' => base_path('laranode-scripts/templates/apache-vhost-frankenphp.template'),
```

`AddVhostEntryService` still reads `config('laranode.apache_vhost_template')` (php-fpm
template). `laranode-vhost-switch.sh` receives the template directory path as an
argument and selects `apache-vhost.template` or `apache-vhost-frankenphp.template`
based on the runtime argument.

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

The unit runs **as the site user** (`{username}_ln`), not `www-data` or root. This
matches the FPM pool pattern (`user = {user}` in `php-fpm-pool.template`).

`ExecStart` arguments for v1: `php-server --listen 127.0.0.1:{port} --root ...`. This
is the FrankenPHP built-in server mode. For Laravel Octane-mode with FrankenPHP
(`--worker-num` etc.), that is a v2 concern — v1 uses the simpler built-in server
which is sufficient for most PHP sites and does not require `laravel/octane` to be
installed in the site.

The rendered unit file is written to
`/etc/systemd/system/laranode-frankenphp-{domain}.service` by
`laranode-runtime-manage.sh` (or by the service layer calling `laranode-vhost-switch.sh`
which also drops the unit file). A `systemctl daemon-reload` is issued after writing
before `enable`/`start`.

---

## PHP / Laravel Services

### `app/Services/Websites/SwitchRuntimeService.php` (new)

Not called directly from the controller. This logic lives inside the `OperationJob`
(see below) where it can emit output lines. The service layer is used by the Job's
`run()` method, broken into discrete steps that each call `$emit()`.

Responsible for:
1. Asserting the website exists and the runtime value is valid.
2. Calculating the target port (if non-FPM).
3. Allocating the port via `PortAllocatorService` (see below).
4. Calling `InstallRuntimeService` for the binary.
5. Stopping the old per-site runtime unit if one exists.
6. Writing the systemd unit from template.
7. Calling `laranode-runtime-manage.sh` to enable + start.
8. Calling `laranode-vhost-switch.sh` to rewrite the Apache vhost.
9. Updating `websites.runtime` and `websites.runtime_port` on success.

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

This is a read-only DB query; no lock needed for v1 (single-server, low concurrency).

### `app/Jobs/SwitchRuntimeOperationJob.php` (new)

Extends `OperationJob` (abstract base in `app/Jobs/OperationJob.php`).

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
        (new SwitchRuntimeService($this->website, $this->runtime, $emit))->handle();
        return 0; // SwitchRuntimeService throws on failure → base marks failed
    }
}
```

This mirrors the pattern of `GenerateSslOperationJob` (`app/Jobs/GenerateSslOperationJob.php`).

### `app/Services/Websites/InstallRuntimeService.php` (new)

`ensureInstalled(string $runtime, callable $emit): void`

Calls `laranode-runtime-install.sh {runtime}` via `Process::run(['sudo', ...])`.
Throws `InstallRuntimeException` on non-zero exit. Called once per `SwitchRuntimeService::handle()`; the script itself is idempotent so calling it repeatedly is safe.

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

The controller follows the same async JSON-response pattern as `toggleSsl()` (which
also dispatches a `GenerateSslOperationJob` and returns `operation_id`).

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

The Websites index table already handles the `sslOp` async pattern:

```jsx
const [sslOp, setSslOp] = useState(null);
// ...
{sslOp && (
    <div className="mb-4 p-3 border rounded">
        <OperationProgress operationId={sslOp.id} onDone={() => { setSslOp(null); router.reload(); }} />
    </div>
)}
```

Mirror this with `runtimeOp` state:

```jsx
const [runtimeOp, setRuntimeOp] = useState(null);
```

New table column: **Runtime** — displayed after "PHP Version". Shows a badge
(`PHP-FPM` / `FrankenPHP`) using the `website.runtime` field. Next to the badge,
a `<select>` with options `PHP-FPM` and `FrankenPHP` (v1). On change, call
`switchRuntime(website, newRuntime)`:

```jsx
const switchRuntime = (website, runtime) => {
    axios.post(route('websites.runtime.switch', { website: website.id }), { runtime })
        .then((res) => setRuntimeOp({ id: res.data.operation_id, url: website.url, runtime }))
        .catch(() => toast.error('Failed to start runtime switch'));
};
```

`OperationProgress` is shown when `runtimeOp !== null`, same as SSL:

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

`OperationProgress` is the existing component (`resources/js/Components/OperationProgress.jsx`)
backed by `useOperation` (`resources/js/hooks/useOperation.js`) which subscribes to
`OperationUpdated` on `operations.{userId}` via `window.Echo.private(...)`. No new
hooks or components are needed.

### Informational note in the UI

When a non-FPM runtime is selected, display a small info banner near the runtime
selector:

> FrankenPHP mode: .htaccess rewrites are disabled. Apache proxies all requests to the
> app server. Your application must handle routing internally (Laravel Router, index.php).

This is a static JSX element shown conditionally when `website.runtime !== 'php-fpm'`.

### `resources/js/Pages/Websites/Partials/CreateWebsiteForm.jsx` changes

The create form does not need a runtime selector in v1. New websites always start as
`php-fpm`. The runtime can be changed after creation from the index table. No changes
to `CreateWebsiteForm.jsx`.

### `resources/js/Layouts/Partials/SidebarNavi.jsx` — no changes

Runtime management is part of the Websites section, not a standalone nav item.

---

## Installer Changes

`laranode-scripts/bin/laranode-installer.sh` additions (in order):

1. `a2enmod proxy proxy_http` — enable Apache proxy modules for non-FPM runtimes.
   Must be added early, before the first `systemctl restart apache2`.
2. Copy and deploy `etc/sudoers.d/laranode-runtimes`:
   ```bash
   cp -f "$PANEL/laranode-scripts/etc/sudoers.d/laranode-runtimes" /etc/sudoers.d/laranode-runtimes
   chmod 0440 /etc/sudoers.d/laranode-runtimes
   ```
3. No FrankenPHP binary installation at install-time — the binary is fetched on first
   use by `laranode-runtime-install.sh`. This avoids downloading a large binary when
   no site uses it. The installer just ensures the proxy modules and sudoers are in place.

### `local-dev/entrypoint-setup.sh` additions

1. `a2enmod proxy proxy_http` — needed in container for integration tests.
2. Copy `laranode-runtimes` sudoers drop-in:
   ```bash
   cp -f "$PANEL/laranode-scripts/etc/sudoers.d/laranode-runtimes" /etc/sudoers.d/laranode-runtimes
   chmod 440 /etc/sudoers.d/laranode-runtimes
   ```

---

## Operation Type

New `Operation.type` values:
- `runtime.switch` — switching a site to any runtime (php-fpm, frankenphp, swoole)

These render automatically in `/admin/operations` (`Operations/Index.jsx`) without
code changes because the table is generic.

---

## Security

### Attack surface

Switching a runtime: rewrites an Apache vhost, writes a systemd unit file, starts a
new process as the site user, and installs a binary. Each step is wrapped in a
privileged script that validates its arguments.

### Mitigations

1. **Runtime enum validation** — `SwitchRuntimeRequest` enforces
   `Rule::in(['php-fpm', 'frankenphp'])`. The script additionally validates with
   regex before touching anything.

2. **Port range confinement** — `PortAllocatorService` only assigns ports 9100–9499.
   The `laranode-vhost-switch.sh` script validates that the port argument is numeric
   and in range before writing the template.

3. **Domain validation in scripts** — `laranode-vhost-switch.sh` validates that the
   domain matches `^[a-zA-Z0-9.-]+$` and contains no path separators. A domain
   like `../../etc/passwd` is rejected before any file is written.

4. **Unit name confinement** — `laranode-runtime-manage.sh` validates the unit name
   against `^laranode-(frankenphp|swoole)-[a-zA-Z0-9._-]+\.service$`. A malicious
   unit name like `sshd.service` or `../../etc/systemd/system/malicious.service`
   is rejected immediately.

5. **User confinement** — the systemd unit runs as `{username}_ln`, not `root` or
   `www-data`. The site process can read/write only the site user's homedir. This
   mirrors the PHP-FPM pool (`user = {user}`) and the existing `open_basedir`
   restriction.

6. **FrankenPHP binary integrity** — `laranode-runtime-install.sh` downloads from the
   official GitHub release URL and verifies the binary runs (`frankenphp --version`).
   For production hardening, a SHA-256 checksum pinned in the script should be added
   before the binary is trusted (flagged as open question below).

7. **FPM pool not removed on runtime switch** — when switching to FrankenPHP, the
   existing PHP-FPM pool for the site is left in place (not removed). This ensures
   a clean rollback path: switching back to PHP-FPM just stops the FrankenPHP unit
   and rewrites the vhost. Removing and recreating FPM pools on every switch would
   increase blast radius.

8. **Ownership check** — `Gate::authorize('update', $website)` in `WebsiteController`
   uses `WebsitePolicy::update()`, which allows only admin or the site owner. A
   non-admin cannot switch another user's site runtime.

9. **Admin-only runtime install** — `laranode-runtime-install.sh` is a privileged
   operation but is called from within the queue worker (which runs as the panel's
   service user, not a web user). The sudo rule grants `www-data` access to the
   install script; the web tier itself just dispatches the job, never calling the
   script directly.

---

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **Port collision** — two sites race to allocate the same port | Medium | `PortAllocatorService` queries all live `runtime_port` values; in practice single-server panels have low concurrency. If two jobs run simultaneously they could allocate the same port; the second will fail to start the unit. Solution: v1 documents this; v2 can add a DB-level unique constraint on `runtime_port` and a retry. |
| **Runtime crash leaves proxy 502** | High | `Restart=on-failure` + `RestartSec=5s` in the unit file provides auto-recovery. The panel does not currently monitor per-site unit health; this is an open question (see below). |
| **FPM socket + FrankenPHP both listening** | Low | FPM pool is kept; the Apache vhost determines which backend is active. No conflict. |
| **Graceful reload vs. in-flight requests** | Medium | `laranode-vhost-switch.sh` uses `apache2ctl graceful` (not `systemctl reload`), which waits for in-flight requests before applying the new config. FrankenPHP start is done before the vhost is switched, so the new backend is ready when Apache starts forwarding. |
| **FrankenPHP binary version drift** | Medium | Pinned URL in `laranode-runtime-install.sh`. Updating requires editing the script. A panel-level "FrankenPHP version" setting is out of scope for v1. |
| **FrankenPHP not compatible with all .htaccess-dependent apps** | High | Documented in the UI (the info banner). `AllowOverride None` is set in the FrankenPHP vhost template; admins and users are warned. No technical mitigation — it is a runtime limitation. |
| **Swoole requires `laravel/octane` in the app** | High | Scoped to v2. The user must install Octane in the site before switching; the panel will check for this (v2 design). |
| **`laranode-runtime-install.sh` downloads from the internet at switch-time** | Medium | First switch triggers a download. On air-gapped servers this will fail. v1 documents this; v2 could support an offline package path. |
| **40 active non-FPM sites exhaust port range** | Low | 400-port range is generous for a single-server panel. Panel enforces the range and surfaces an error if exhausted. |

---

## Testing Strategy

### Pest — unit tests (`tests/Unit/`)

**`tests/Unit/PortAllocatorServiceTest.php`** (new)
- Table-driven: no sites → allocates 9100; existing port 9100 → allocates 9101; all
  ports 9100–9499 occupied → throws `\RuntimeException`.
- Uses an in-memory DB with seeded `websites` rows.

**`tests/Unit/SwitchRuntimeRequestTest.php`** (new)
- `php-fpm`, `frankenphp` pass validation.
- `swoole` fails in v1 (not in allowlist yet).
- Anything else fails.

### Pest — feature tests (`tests/Feature/Websites/`)

**`tests/Feature/Websites/SwitchRuntimeTest.php`** (new)

All use `Process::fake()`.

- `POST /websites/{id}/runtime` as owner with `runtime=frankenphp` → 200 JSON with
  `operation_id`; `Operation` row created with `type=runtime.switch`, `status=queued`.
- Same as non-owner → 403, no Operation row.
- Same as unauthenticated → redirect to login.
- `runtime=swoole` → 422 (v1 not in allowlist).
- `runtime=` empty / missing → 422.
- `runtime=../etc/passwd` → 422.
- `Process::fake()` with failing `laranode-runtime-install.sh` → Operation marked
  `failed`; `websites.runtime` unchanged.
- `Process::fake()` with failing `laranode-vhost-switch.sh` → Operation marked
  `failed`; `websites.runtime` unchanged.
- Successful job → `websites.runtime = 'frankenphp'`, `websites.runtime_port` set to
  a value in 9100–9499, Operation marked `succeeded`.

**`tests/Feature/Websites/SwitchRuntimeBackToFpmTest.php`** (new)

- Site with `runtime=frankenphp`, `runtime_port=9100` switches back to `php-fpm` →
  Operation `succeeded`; `websites.runtime = 'php-fpm'`; `websites.runtime_port = null`.
- Verifies `laranode-runtime-manage.sh stop` is called for the old unit.
- Verifies `laranode-vhost-switch.sh php-fpm` is called (not the proxy variant).

### Pest — system integration (`tests/Feature/Websites/RuntimeSystemTest.php`)

Gated: `if (!env('LARANODE_SYSTEM_TESTS')) $this->markTestSkipped(...)`.

Requires `local-dev` container with:
- FrankenPHP binary installed (`laranode-runtime-install.sh frankenphp` pre-run).
- `testuser_ln` system account (already provisioned by `entrypoint-setup.sh` for CronJob tests).
- A test website row pointing to a valid directory under `testuser_ln`'s homedir.
- Apache proxy modules enabled (`a2enmod proxy proxy_http`).

Tests:
1. **Install FrankenPHP binary** — run `laranode-runtime-install.sh frankenphp` directly;
   assert exit 0; assert `/usr/local/bin/frankenphp --version` exits 0.
2. **Start FrankenPHP unit** — dispatch `SwitchRuntimeOperationJob` for a test website
   to `frankenphp`; poll until Operation `succeeded`; assert `systemctl is-active
   laranode-frankenphp-{domain}.service` → `active`.
3. **Apache proxy is live** — `curl -s http://127.0.0.1/{host header: domain}` returns
   HTTP 200 (or at minimum a non-502).
4. **Switch back to FPM** — dispatch job with `php-fpm`; poll; assert unit is `inactive`;
   assert Apache vhost uses FPM socket handler (`grep proxy /etc/apache2/sites-available/{domain}.conf` is absent).
5. **Invalid runtime rejected by script** — run `laranode-runtime-install.sh badvalue`
   directly; assert non-zero exit.
6. **Invalid unit name rejected** — run `laranode-runtime-manage.sh start sshd.service`
   directly; assert non-zero exit.

### Vitest — component tests

**`resources/js/Pages/Websites/Websites.runtime.test.jsx`** (new)

- Renders the `Index` page with a website prop where `runtime = 'frankenphp'` — assert
  the Runtime column shows `FrankenPHP` badge.
- Renders with `runtime = 'php-fpm'` — assert badge shows `PHP-FPM`.
- Simulates selecting `FrankenPHP` from the runtime `<select>` — assert `axios.post` is
  called with `route('websites.runtime.switch', ...)` and `{ runtime: 'frankenphp' }`.
- Simulates operation completion via `onDone` — assert `router.reload()` is called.
- Renders the info banner for non-FPM runtime; asserts it is absent for php-fpm.

Mock setup: `axios` and `router` mocked (same pattern as `CreateDatabaseForm.test.jsx`
in `resources/js/Pages/Databases/Partials/`).

---

## Integration with Existing Stack

### `OperationJob` base class

`SwitchRuntimeOperationJob` extends the abstract `app/Jobs/OperationJob.php`. The base
class's `handle()` method calls `markRunning()`, invokes `run($emit)`, and calls
`markFinished($exitCode)`. Each `$emit($line)` call invokes `Operation::appendOutput()`
which dispatches `OperationUpdated` → broadcast to `operations.{userId}` → received by
`useOperation` hook → displayed in `OperationProgress` on the Websites page.

No changes to `OperationJob`, `OperationUpdated`, `useOperation`, or `OperationProgress`.

### `WebsitePolicy`

No changes to `app/Policies/WebsitePolicy.php`. The existing `update(User, Website)`
method already gates `Gate::authorize('update', $website)` used in `switchRuntime()`.

### Operations admin page

`/admin/operations` (`OperationsController::index()`, `Operations/Index.jsx`) renders
rows generically. `type=runtime.switch` operations appear automatically with no
code changes.

### SSL coexistence

SSL is applied to the Apache vhost *after* the FPM config. For FrankenPHP sites:
- The proxy vhost template also needs the SSL variant (`apache-vhost-frankenphp-ssl.template`).
- When SSL is toggled on a FrankenPHP site, `laranode-ssl-manager.sh generate` creates
  the SSL vhost file. The existing `create_ssl_vhost()` function copies the inner content
  of the base vhost and wraps it in `<VirtualHost *:443>`. This works for the proxy
  template too (the `ProxyPass` directives survive the copy).
- However, the redirect vhost that `laranode-ssl-manager.sh` generates (`<VirtualHost *:80>
  Redirect permanent / https://...`) will override the proxy. This is correct behaviour
  for SSL-enabled sites.
- **Risk:** the SSL script reads the existing `.conf` file and copies its inner content.
  If the vhost was written by the FrankenPHP template (no `<FilesMatch>` block, has
  `ProxyPass`), the copy will include the proxy directives in the `:443` block, which
  is correct. This should work without changes to `laranode-ssl-manager.sh` for v1;
  verify in system tests.

### PHP Version selector

The PHP version `<select>` in `Websites/Index.jsx` currently calls
`PATCH /websites/{id}` → `WebsiteController::update()` → `UpdateWebsitePHPVersionService`.
That service creates/reloads a PHP-FPM pool for the new version. For FrankenPHP sites:
- FrankenPHP is a standalone binary; it does not use a PHP-FPM pool for request
  handling. The `php_version_id` column still records the user's PHP preference, and
  FrankenPHP uses the system PHP (`/usr/bin/php`) regardless.
- **v1 behaviour:** the PHP version selector for FrankenPHP sites is disabled in the
  UI (grayed out with a tooltip: "PHP version is managed by FrankenPHP"). The
  `WebsiteController::update()` endpoint will reject `PATCH` for non-FPM sites with
  a 422 ("PHP version switching is not supported for this runtime").
- This avoids a misleading UI where the PHP version changes in the DB but has no
  effect on the running server.

---

## Back-compat

- All existing sites have `runtime = 'php-fpm'` and `runtime_port = null` after the
  migration. No functional change to existing sites.
- No changes to `CreateWebsiteService`, `DeleteWebsiteService`, `AddVhostEntryService`,
  or `CreatePhpFpmPoolService`. New-site creation continues to use the FPM path.
- `DeleteWebsiteService::syncPhpFpmPools()` is unchanged. When deleting a FrankenPHP
  site, the controller should additionally call `laranode-runtime-manage.sh stop+disable`
  and delete the unit file. This is a **gap**: `DeleteWebsiteService` does not currently
  handle this. The implementation must add a `teardownRuntime()` step to
  `DeleteWebsiteService` that checks `$this->website->runtime` and, for non-FPM runtimes,
  calls the manage script. This is a required addition in v1 (not deferred).
- `UpdateWebsitePHPVersionService` should check `$this->website->runtime` and throw if
  runtime is not `php-fpm` (see PHP Version selector note above).
- The `Operation` model's `MassPrunable` (30-day prune) works for `runtime.*` rows
  automatically. No change.

---

## File Inventory

```
database/migrations/2026_06_27_000002_add_runtime_to_websites_table.php  (new)
app/Models/Website.php                                                     (modify: fillable, casts, getRuntimeLabelAttribute)
app/Http/Controllers/WebsiteController.php                                 (modify: add switchRuntime())
app/Http/Requests/SwitchRuntimeRequest.php                                 (new)
app/Services/Websites/SwitchRuntimeService.php                             (new, includes SwitchRuntimeException)
app/Services/Websites/InstallRuntimeService.php                            (new, includes InstallRuntimeException)
app/Services/Websites/PortAllocatorService.php                             (new)
app/Services/Websites/UpdateWebsitePHPVersionService.php                   (modify: reject non-FPM sites)
app/Services/Websites/DeleteWebsiteService.php                             (modify: add teardownRuntime())
app/Jobs/SwitchRuntimeOperationJob.php                                     (new)
config/laranode.php                                                        (modify: add apache_vhost_frankenphp_template)
routes/web.php                                                             (modify: add runtime.switch route)
laranode-scripts/bin/laranode-runtime-install.sh                           (new)
laranode-scripts/bin/laranode-runtime-manage.sh                            (new)
laranode-scripts/bin/laranode-vhost-switch.sh                              (new)
laranode-scripts/templates/apache-vhost-frankenphp.template                (new)
laranode-scripts/templates/laranode-frankenphp.service.template            (new)
laranode-scripts/etc/sudoers.d/laranode-runtimes                           (new)
laranode-scripts/bin/laranode-installer.sh                                 (modify: a2enmod proxy proxy_http + deploy runtimes sudoers)
local-dev/entrypoint-setup.sh                                              (modify: a2enmod proxy proxy_http + deploy runtimes sudoers)
resources/js/Pages/Websites/Index.jsx                                      (modify: runtime column + runtimeOp state + OperationProgress)
tests/Unit/PortAllocatorServiceTest.php                                    (new)
tests/Unit/SwitchRuntimeRequestTest.php                                    (new)
tests/Feature/Websites/SwitchRuntimeTest.php                               (new)
tests/Feature/Websites/SwitchRuntimeBackToFpmTest.php                      (new)
tests/Feature/Websites/RuntimeSystemTest.php                               (new, LARANODE_SYSTEM_TESTS=1)
resources/js/Pages/Websites/Websites.runtime.test.jsx                      (new, Vitest)
```

Total: ~30 files (11 new backend, 3 new scripts + templates, 2 modified services,
1 modified controller, 4 modified infrastructure files, 4 new test files, 1 new Vitest).

---

## Open Questions

1. **FrankenPHP binary checksum** — should `laranode-runtime-install.sh` pin a
   SHA-256 checksum alongside the download URL to verify binary integrity? Currently
   only `frankenphp --version` is checked. A compromised CDN could serve a malicious
   binary. Recommendation: pin checksum in v1, with a documented upgrade path.

2. **Per-site runtime health monitoring** — when a FrankenPHP unit crashes and
   systemd is restarting it, the Apache proxy returns 502 until the unit recovers.
   Should the dashboard show per-site runtime unit status (e.g. a new
   `RuntimeStatusService` polling `systemctl is-active`)? Deferred to v2 or a
   separate sub-project.

3. **SSL + FrankenPHP template variant** — `laranode-ssl-manager.sh create_ssl_vhost`
   copies inner content from the base vhost. Manual testing is needed to confirm
   this works correctly for the FrankenPHP proxy template (the `ProxyPass` directives
   should survive the copy). If not, a `frankenphp` branch in the SSL script is needed.
   This must be confirmed in system tests before merging.

4. **Port persistence across site rename** — if a site's URL changes (not currently
   supported), the systemd unit name and the `runtime_port` would need updating. Out
   of scope for v1 (URL changes are not supported), but worth flagging.

5. **FrankenPHP Octane mode vs. built-in server mode** — this spec uses
   `frankenphp php-server` (built-in HTTP server, no `laravel/octane` required).
   For full Octane-style worker pooling with FrankenPHP, the command would be
   `frankenphp php-server --worker /home/{user}/domains/{domain}/public/index.php`.
   v1 uses the simpler mode; Octane worker mode is v2. Decide before implementation:
   does v1 need worker mode or is the built-in server sufficient?

6. **Multiple sites per user switching simultaneously** — if a user has five sites
   and triggers runtime switches on all simultaneously, five `SwitchRuntimeOperationJob`
   instances run in parallel, each calling `PortAllocatorService`. Under the current
   non-locking design, two jobs could read the same free port list and allocate the
   same port. The second job's `laranode-runtime-manage.sh start` will fail because
   the port is already bound. For v1, document this as a known limitation. For v2,
   add a `DB::transaction` with a pessimistic lock (`lockForUpdate`) on the
   `runtime_port` allocation.

7. **FrankenPHP binary location** — this spec uses `/usr/local/bin/frankenphp`.
   Should it be under the panel's own path (e.g. `/opt/laranode/bin/frankenphp`)
   to avoid polluting the system PATH? The sudoers rule would need updating.

8. **Swoole/Octane v2 scope** — Swoole requires `laravel/octane` inside each site's
   Composer dependencies. The panel cannot assume this is installed. v2 should either
   auto-install it (risky: modifies site code) or check for it and surface a clear
   error before dispatching the job. Design TBD.
