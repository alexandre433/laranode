# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Laranode is a self-hosted server control panel (cPanel/Plesk alternative) built on Laravel 12 + Inertia 2 + React 18. It manages the **host machine itself** — Apache vhosts, per-site PHP-FPM pools, MySQL databases, Let's Encrypt SSL, UFW firewall, a web file manager, and live system stats. Target host is Ubuntu 24.04+; the panel is deployed at `/home/laranode_ln/panel`.

## Local dev/test (Docker)

`local-dev/` provides a single systemd-enabled Ubuntu 24.04 container ("VPS-in-a-box") with the full Laranode stack (Apache, PHP-FPM, MySQL, Reverb, queue worker). No real Linux VPS needed for integration testing.

Key targets (run from repo root):
- `make up` — build image + start container + run entrypoint provisioning
- `make verify` — check all services running + HTTP panel response
- `make test` — run Pest suite inside container
- `make test-system` — Pest with `LARANODE_SYSTEM_TESTS=1` (exercises sudo scripts)
- `make ssl-test` — bring up Pebble ACME sidecars (pebble + challtestsrv) + test SSL issuance
- `make nuke` — destroy container + all named volumes (full reset)

Admin login: `admin@laranode.test` / `password`

> **Windows:** Run `make` and `docker compose` from **PowerShell or cmd**, NOT Git Bash.
> Git Bash (MSYS) breaks docker two ways: it strips the Windows environment that
> `docker.exe` needs to locate its compose plugin, and it rewrites in-container paths
> (`/home/…`, `/opt/…`) passed to `docker exec` into `C:/msys64/…`, which breaks the
> provisioning recipes. The Makefile's `MSYS_*` exports fix the path rewriting, but the
> plugin-discovery failure remains — so use PowerShell/cmd. Plain `docker exec
> laranode-lab …` works from any shell.

## Commands

```bash
composer dev          # all-in-one dev: php artisan serve + queue:listen + pail (logs) + vite, concurrently
npm run dev           # vite only
npm run build         # production asset build
php artisan reverb:start   # websocket server — NOT started by `composer dev`; needed for live stats
./vendor/bin/pest                       # run tests (Pest 3)
./vendor/bin/pest --filter="text"       # single test by name
php artisan test --filter=AccountsTest  # alt runner, by file/test
./vendor/bin/pint     # format (Laravel Pint) — run before committing PHP
php artisan migrate
php artisan laranode:create-admin   # interactive admin creation (username is forced to "laranode")
```

Tests use Pest with `RefreshDatabase` (see `tests/Pest.php`); feature tests live in `tests/Feature/<Domain>/`.

## Verify every feature before calling it done

After implementing ANY feature or bug fix, run this gate before declaring it complete (and before committing):

1. **Backend tests** — `./vendor/bin/pest` (or `--filter` for the touched domain, then the full suite to catch regressions).
2. **Frontend tests** — `npx vitest run` for the touched component, then the full Vitest suite.
3. **Build assets** — `npm run build` (the lab serves `public/build/`, not Vite dev — stale assets are why a change "doesn't show"). Clear caches if a blade/route changed: `php artisan optimize:clear`.
4. **Playwright check** — drive the running panel (lab container, admin `admin@laranode.test` / `password`) to confirm the change actually works in the real app and toggle dark mode on the affected page(s). Verify against the live result, not just the diff.

Run all four in the lab container, e.g. `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && <cmd>'`.

**Pint scope:** only format files you changed (`./vendor/bin/pint <file> ...`). NEVER run `pint app/` or a whole-tree pint — it sweeps dozens of pre-existing unformatted files into your diff.

## Environment caveat

System-touching features (sudo scripts, `systemctl`, `/proc`, `certbot`, `ufw`) only run on a real Linux host. On Windows/macOS dev machines those `Process` calls fail — exercise that behavior on a Linux VPS, not locally. DB is MySQL in prod (`.env.example`).

## Installer

`laranode-scripts/bin/laranode-installer.sh` is a single-file, phased bash script
(`set -euo pipefail`; a source-guard at the bottom lets unit tests source it without
running `main`). It is **safe to run on hosts that already have services** — it never
rotates the system MySQL root password, never overwrites `000-default.conf`, and falls
back to `:8080` when `:80` is occupied.

### Env-var interface

| Variable | Default | Purpose |
|----------|---------|---------|
| `LARANODE_DB_ENGINE` | `mysql` (Ubuntu) / `pgsql` (Debian) | `mysql` or `pgsql` — only that engine's server package is installed. Debian has no `mysql-server`: `mysql` there needs an existing MySQL/Percona/MariaDB server |
| `LARANODE_HTTP_PORT` | auto (80 free → 80, else 8080) | Apache port the panel listens on |
| `LARANODE_MYSQL_ROOT_PASSWORD` | — | Required when existing MySQL root uses password auth (not `auth_socket`) |
| `LARANODE_PG_PORT` | auto (single cluster) | Disambiguate when multiple Postgres clusters exist on the same host |
| `LARANODE_APP_URL` | public IP via `icanhazip.com` | Sets `APP_URL`, `REVERB_HOST`, `VITE_REVERB_HOST` in `.env` |
| `LARANODE_REPO` | GitHub fork URL | Clone source; the install-test harness overrides this to the injected tree path |
| `LARANODE_OS` | auto-detect | `ubuntu` or `debian`: force the package path for a derivative distro (VERSION_ID must still be 24.04 / 13) |
| `LARANODE_BIND` | `local` on Proxmox/CloudPanel, else `all` | `all`, `local` (127.0.0.1) or an IPv4. Panel Apache vhost and Reverb listen only there; reach a local-bound panel over an SSH tunnel |
| `LARANODE_DATA_DIR` | — | Fresh PostgreSQL install only: put cluster data under `<dir>/postgresql/<ver>/<cluster>` (e.g. a bigger disk) |
| `LARANODE_START_STOPPED` | `0` | `1` = allow the installer to START a pre-existing apache2 / php8.4-fpm that is installed but stopped. Without it such a host is refused in preflight. The unit is started, never enabled at boot, and its configuration is left as it is |
| `LARANODE_PROBE_PROC` | `0` | `1` = test seam: force the `/proc/net/tcp{,6}` busy-port probe even where `ss` exists (the `nginx-dualstack` scenario) |
| `LARANODE_UNATTENDED` | `0` | `1` = take all defaults, suppress all prompts and `confirm` gates. Without a TTY and without `1` the install stops at the confirmation (no silent proceed) |

### Supported hosts

Ubuntu 24.04 and Debian 13 (trixie); anything else is refused with a clear message.
Debian uses its own `php8.4` and PostgreSQL 17 (no ondrej/sury repo). Ubuntu keeps the ondrej PPA.
Every `apt-get install` is simulated first (`apt_install`): the installer dies if apt would
**remove** any package, or **upgrade** a host-stack package (pve-*, percona-*, nginx, php8.x-*,
postgresql*, openssh-server, ...) — on every host, not just Proxmox/CloudPanel — and runs with
`--no-upgrade`. `needrestart` is held to list-only (`NEEDRESTART_MODE=l`) so apt cannot restart host services.
An unsupported OS is refused before the first apt call. `.env` (DB password) is created 0640 and
`/home/laranode_ln` 0750 from the start; MySQL passwords never appear in process arguments.
Pre-existing Apache / php-fpm (manifest `managed:false`) are never restarted: a running one gets a graceful
`reload`, a stopped one a `start`; only units this installer installed are restarted.


### Safe on hosts with existing services

| Pre-existing condition | Installer behaviour |
|------------------------|---------------------|
| nginx on :80 | Panel vhost written to `laranode.conf` on :8080; existing server fully untouched |
| Apache on :80 (live sites) | Its `Listen`/`000-default`/sites/mod_ssl are never changed; panel gets its own vhost + `Listen 8080` (PHP-FPM handler inline in that vhost, no global `a2enconf`); Apache is **gracefully reloaded** (same PID, no dropped connections), never restarted or `a2dissite`d. `LARANODE_BIND` + :80 is refused (cannot narrow its wildcard `Listen 80`) |
| Apache/php-fpm installed but STOPPED | Not ours: ownership means *the package was absent before this run* (or a previous run recorded it `managed:true`), not *it is running*. Refused in preflight (nothing changed) unless `LARANODE_START_STOPPED=1`; with it the unit is only started, never enabled, `ports.conf`/`000-default`/modules of the owner are untouched. Refused regardless of the opt-in when its own `Listen` port is held by another service (it could not start) |
| Any pre-existing service (guard scope) | A package's postinst (the named one or a library it pulls in) can try-restart a running service, e.g. the php8.4 extensions bounce a live php8.4-fpm pool. On a host with pre-existing units EVERY `apt_install` runs under a marked `policy-rc.d` guard that holds back service starts (`phase_services` then **reloads** the pool); `APT_ALLOW_SERVICE_START=1 apt_install ...` opts out for the services the installer adds itself (cron, sysstat, mysql-server, a fresh PostgreSQL) which have to start. The guard is only created when no `policy-rc.d` exists (noclobber), carries a marker + the installer pid, nests, is removed on every exit/signal, and **expires with its installer**: the file answers `exit 101` only while that pid is alive (`kill -0`), so a guard left by a SIGKILL/OOM/power loss is inert at once and removed at the next start (a `policy-rc.d` without the marker is never touched) |
| Pre-existing Apache, a later step fails | From the moment the owner's files are snapshotted, ANY later `die` (configtest, reload, "not active", "not listening", firewall, ...) restores `ports.conf`, removes/restores the panel vhost and disables the modules this run enabled (recorded one by one in `/etc/laranode/apache-modules-enabled` so the record survives a die). The owner's Apache is **reloaded back only if our config may have been loaded** (the reload was reached) and is **never stopped** when it was running before (a failed configtest/a2ensite/a2enmod leaves its unit completely alone); only an Apache THIS run started (opt-in) is stopped again. An Apache this installer installed is never rolled back |
| Installer killed (SIGKILL / OOM / power loss) mid-change | The snapshot is a journal on disk (`/etc/laranode/apache-rollback`: pid, original `ports.conf`, previous panel vhost, was-active, reloaded) written BEFORE the first change and removed on success. The next installer start (`_apache_journal_recover`, before preflight) finds the journal of a dead installer and undoes the changes first (same rules as above); a journal of a live pid is refused (two installers); a restore that fails refuses and names the journal. Caveat: the restored `ports.conf` is the snapshot, so an owner edit made between the kill and the next run is overwritten (the original is in the journal) |
| No `ss` on the host | Port probing falls back to `/proc/net/tcp{,6}` (holder via `/proc/<pid>/fd`); the installer never runs `apt-get update` or installs iproute2 before the confirm prompt. If neither probe works, preflight refuses |
| Panel port already in use | `HTTP_PORT` (default 80, fallback 8080/8090, or `LARANODE_HTTP_PORT`) must be free before Apache config is touched; a graceful reload that cannot bind a new `Listen` can take a running Apache down and `apachectl configtest` does not bind. Refused with the holder named. Only the panel's own Apache vhost from a previous run is accepted |
| MySQL with a root password | Authenticates with `LARANODE_MYSQL_ROOT_PASSWORD`; root password **never changed** |
| Multiple Postgres clusters | `LARANODE_PG_PORT` required; only that cluster's socket is touched |
| System `php` not 8.4 | `php8.4` packages installed additively; system default left unchanged; panel calls/units use `/usr/bin/php8.4` |
| Node ≥ 20 already present | Warns and skips nodesource; existing Node binary used as-is |
| Proxmox VE host (`pveversion` or `/etc/pve`) | Never installs/enables ufw (pve-firewall owns the host), refuses panel ports 22/85/111/443/3128/8006, binds `127.0.0.1` |
| CloudPanel host (`/home/clp`, `clpctl`, package `cloudpanel`) | No PPA, never installs over its php/nginx/Percona, panel on `:8090` (8080 is Varnish's backend), Reverb `:8081`, no ufw rules, binds `127.0.0.1` |
| Percona / MySQL / MariaDB server present | Reused as-is; `mysql-server` is never installed over it |
| PostgreSQL cluster present | Server package untouched (client only); `LARANODE_PG_PORT` must name the cluster the panel may use |

Re-running the installer on an already-provisioned panel is **idempotent**: `APP_KEY` is
not regenerated if already set to a `base64:` value, `APP_URL` is not overwritten if
already a non-placeholder value, and `db:seed` is skipped when the `users` table is
non-empty. (Note: a re-run that does not pass `LARANODE_HTTP_PORT` sees the panel's own Apache
holding `:80` and falls back to `:8080`, where its own Reverb already listens: it is now
refused with the holder named. Pass the original port to keep it in place.)

### Service manifest (what the installer owns)

The installer writes `/etc/laranode/service-manifest.json` (override: `LARANODE_MANIFEST_FILE`),
world-readable, one service per line so shell and PHP can both parse it:

```json
{"version":1,"generated":"2026-11-21T01:00:00Z","host":{"os":"debian 13","proxmox":true,"cloudpanel":false},"db":{"engine":"pgsql","unit":"postgresql@17-main.service"},"apache_modules_enabled":["proxy","rewrite"],
"services":[
{"unit":"laranode-reverb.service","managed":true,"role":"reverb","reason":"installed-by-laranode"},
{"unit":"postgresql@16-main.service","managed":false,"role":"preexisting","reason":"present-before-install"}
]}
```

- `"managed":true` = created/installed by the installer (kept across re-runs). Safe to stop/start (sleep/wake).
- `"managed":false` = present before the installer ran (e.g. a CloudPanel host's PostgreSQL, Redis, Percona, nginx/php-fpm, any
  pre-existing Apache/PHP-FPM/MySQL). **Never stop, start, restart or reconfigure these.**
  The one exception: with `LARANODE_START_STOPPED=1` the installer starts (never enables) a stopped pre-existing apache2 / php8.4-fpm that the panel needs; it stays `managed:false`.
- Roles: `reverb`, `queue`, `web` (apache2), `php` (php8.4-fpm), `database` (the panel's DB unit), `preexisting`.
- `apache_modules_enabled` (additive, still `version:1`): Apache modules this installer switched on (kept across re-runs). On a pre-existing Apache only `proxy proxy_fcgi rewrite` are ever enabled, and only if not already on; no `ssl`, `headers`, `setenvif` or `proxy_http`.
- Always managed: `laranode-reverb.service`, `laranode-queue-worker.service`. A consumer must treat a unit that is
  missing from the file as not managed.

### Install-test matrix

CI (`.github/workflows/installer-tests.yml`) runs the unit tests, `local-dev/install-test/mutation-smoke.sh` (reverts each reviewed guard in a copy of the installer; every mutation must turn the unit tests red) and ALL 14 container scenarios (the 15th, `rerun-sleep`, runs in `sleep-tests.yml`) (one parallel matrix job each, wall time = slowest scenario) on every PR and on pushes to `development`. Extra test seams: `LARANODE_APACHE_MODS_STATE`, `LARANODE_PROC_NET_DIR`, `LARANODE_PROC_DIR`, `LARANODE_POLICY_RC_D`, `LARANODE_ROLLBACK_DIR`, `LARANODE_INSTALLER_PID` (the pid the guard and journal record; unit tests run phases in subshells).

Clean-room integration tests in `local-dev/install-test/` boot one vanilla
`jrei/systemd-ubuntu:24.04` container per scenario, inject the repo, run the real
installer, and assert services active + HTTP 200 + admin login. Run from the repo root:

    make -f local-dev/Makefile install-test-unit       # host helper + host-detection unit tests (no container, ~2 s)
    make -f local-dev/Makefile install-test-templates  # host template-content tests (no container)
    make -f local-dev/Makefile install-test            # baseline scenario only
    make -f local-dev/Makefile install-test-matrix     # all scenarios (~1-2 hr)

Scenarios: `baseline` | `nginx80` | `mysql-rootpw` | `pgsql` | `rerun` | `debian13` | `pve` | `cloudpanel` | `apache80` | `port-busy` | `apache-stopped` | `phpfpm-live` | `nginx-dualstack` | `apache-badconf` | `rerun-sleep`.
Run or debug a single scenario:

    bash local-dev/install-test/run.sh pgsql
    KEEP=1 bash local-dev/install-test/run.sh pgsql   # keep container after run

## Architecture

### Request layering
Controllers are thin. The pattern is: **Controller → FormRequest (validation) → Service or Action (work)**.

- `app/Services/<Domain>/` — orchestration, usually wrapping system calls (`Websites`, `MySQL`, `Accounts`, `Dashboard`, and `Laranode` infra helpers). Convention: a single `handle()` method, and a sibling custom `*Exception` class declared in the same file (e.g. `CreateWebsiteException`).
- `app/Actions/<Domain>/` — single-purpose units (`Filemanager`, `Firewall`, `SSL`, `MySQL`). Filemanager actions receive a Flysystem `Filesystem` injected by `AppServiceProvider`, sandboxed to the authenticated user's homedir (`DISALLOW_LINKS`).

### How the panel touches the system (the core idea)
Two distinct mechanisms, both via the `Process` facade:

1. **Privileged mutations** shell out to whitelisted bash scripts:
   ```php
   Process::run(['sudo', config('laranode.laranode_bin_path') . '/laranode-add-vhost.sh', ...$args]);
   ```
   Scripts live in `laranode-scripts/bin/`, config templates (Apache vhost, PHP-FPM pool, systemd units) in `laranode-scripts/templates/`. The installer grants `www-data` NOPASSWD sudo for `laranode-scripts/bin/*.sh`. When adding a privileged op: add a `*.sh` script there and call it through a Service — do not run privileged commands inline.
2. **Read-only stats** call system tools directly (`top`, `free`, `df`, `systemctl`, `ps`, `certbot`, `/proc/net/dev`) via `Process::run('…')` / `Process::pipe([...])`. See `app/Services/Dashboard/SystemStatsService.php`.

### Identity & path conventions (computed, never stored)
Used throughout the codebase — accessors on the models, not DB columns (comments note casts were unreliable here):
- System user = `{username}_ln` (`User::systemUsername`)
- Home dir = `/home/{username}_ln` (`User::homedir`)
- Website root = `{homedir}/domains/{url}`; `fullDocumentRoot` = website root + `document_root` (`Website`)

### Auth & multi-tenancy
- `users.role` is `admin` | `user`. `AdminMiddleware` gates admin-only routes (accounts, firewall, PHP manager, admin dashboard, stats history).
- Non-admins are scoped to their own rows via the `scopeMine()` query scope on `Website`/`Database`.
- Admins impersonate users via `lab404/laravel-impersonate`. Shared Inertia props (`HandleInertiaRequests`): `auth.user`, `auth.isImpersonating`, `flash.{success,error}`.

### Live stats over websockets (no polling)
Reverb-based push, not polling:
1. React page subscribes to a private channel and whispers a `client-typing` event (`resources/js/Pages/Dashboard/...`).
2. Server's `MessageReceivedListener` (auto-discovered, hooks `Laravel\Reverb\Events\MessageReceived`) matches the channel and dispatches `SystemStatsEvent` / `TopStatsEvent`.
3. Those events gather fresh stats in their constructor and broadcast back on private channels `systemstats` / `topstats` — both authorized to admins only (`routes/channels.php`).

Historical stats use sysstat/`sar`: `app/Services/Dashboard/{SarHistory,CPUHistoryService,MemoryHistoryService,NetworkHistoryService}.php`, all implementing `HistoricStatsContract`.

### Frontend
Inertia + React (JSX, **not** TypeScript). Pages in `resources/js/Pages/<Domain>/`, layouts in `resources/js/Layouts/`. `route()` in JS comes from Ziggy; websockets from Echo/Reverb (`resources/js/echo.js`). Tables use `react-data-table-component`, charts use `chart.js`/`react-chartjs-2`.

### Production runtime
Apache2 (vhost per site) + per-site PHP-FPM pools + MySQL + certbot (Let's Encrypt, 90-day certs) + UFW. Two systemd services from `laranode-scripts/templates/`: `laranode-reverb.service` (websockets) and `laranode-queue-worker.service` (queue, `QUEUE_CONNECTION=database`). Full provisioning is in `laranode-scripts/bin/laranode-installer.sh`.

### Service sleep/wake (optional, OFF by default)
Admin **Power** page (`/admin/power`). Frees RAM by stopping idle Reverb / queue worker / PHP-FPM pools / hosting DB and waking them on first use (systemd socket activation, `systemd-socket-proxyd`). Full design, safety model and trade-offs: `docs/sleep-wake.md`.
- ONE privileged script: `laranode-scripts/bin/laranode-sleep.sh <reverb|queue|hostdb|fpm> <enable|disable|wake|sleep> [idle]` (sudoers drop-in `laranode-scripts/etc/sudoers.d/laranode-sleep`). Never add unit names or free-form args to it.
- Only services in the root-owned registry `/etc/laranode/managed.d/` (written by `laranode-managed-register.sh` from the installer manifest, `managed:true` only) can be touched. Pre-existing services are external and refused (exit 3). The panel's own DB never sleeps. The manifest is REQUIRED (fail closed: none = nothing registered, every action refused).
- Reverb's sleep socket binds the registered `bind_host` (from `REVERB_SERVER_HOST`, e.g. 127.0.0.1 on Proxmox/CloudPanel), never all interfaces. hostdb sleep is refused when an enforced AppArmor mysqld/mariadbd profile exists (it would deny the moved socket); the script never rewrites AppArmor policy.
- Installer re-run with sleep ON: `_reassert_sleep_wake` re-applies `enable` for every key with `enabled=1` (fresh drop-in ExecStart, back asleep). Scenario `local-dev/install-test/scenarios/rerun-sleep.sh`.
- Stale entry: when the installer no longer registers a service that is still asleep, `laranode-managed-register.sh` keeps its entry marked `stale=1` so `disable` can restore it. A stale entry allows `disable` only (script exit 3 otherwise; the panel answers 409 reason `stale`, the Power page shows the reason but keeps the toggle usable), and a successful `disable` DROPS the entry.
- Tests: `tests/Feature/Sleep/*` (Pest, stub systemctl), `tests/system/sleep/matrix.sh [ubuntu|debian|all]` (real systemd, Docker; also run by `.github/workflows/sleep-tests.yml`), `tests/e2e/power.spec.js`.
