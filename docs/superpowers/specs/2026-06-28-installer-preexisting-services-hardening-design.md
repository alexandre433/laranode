# Installer Hardening for Pre-existing-Service Hosts — Design

**Date:** 2026-06-28
**Status:** Approved (design), pending implementation plan
**Scope target:** `laranode-scripts/bin/laranode-installer.sh` (+ a new Apache panel template, two systemd unit templates, and the clean-room install test under `local-dev/install-test/`).

## 1. Problem

`laranode-installer.sh` was made *clean-install-safe* (validated only against a bare `ubuntu:24.04`). On a **dedicated host that already runs some of the services it installs** (Apache/nginx on :80, an existing MySQL with a root password and live DBs, an existing Postgres cluster, an existing PHP/Node), it does **not** crash — `set -e` is commented out (line 4) — so every failure is silently swallowed and the script still prints "install complete." A 6-subsystem adversarial audit (2026-06-28) found it will:

- **Rotate the system MySQL root password** (line 76 `ALTER USER 'root'@'localhost'`) to a random value that is only `echo`'d, never persisted → root lockout, recovery needs `--skip-grant-tables`. (CRITICAL)
- **Overwrite `/etc/apache2/sites-available/000-default.conf`** (line 256) with the panel vhost, then `restart apache2` → takes the operator's existing site offline. (CRITICAL)
- **Grant `pg_read_all_stats` on the operator's existing Postgres cluster** because `sudo -u postgres psql` hits the :5432 socket (existing cluster), not the freshly-installed PG16 on :5433. (CRITICAL)
- **Desync `.env` ↔ MySQL** — a fresh random `DB_PASSWORD` is written to `.env` even when `CREATE USER laranode` failed (already exists) → panel can't reach its DB. (CRITICAL)
- Flip the system default `php` to 8.4 (breaks existing PHP apps/crons), **purge & replace** existing Node via nodesource, and on re-run regenerate `APP_KEY` (invalidates sessions) and overwrite a custom `APP_URL` with the raw public IP. (HIGH)

Confirmed safe: UFW (only `ufw allow`, never `enable`/`default deny` → no SSH lockout), apt installs, guarded clone, `useradd || true`.

## 2. Goals / Non-goals

**Goals**
- Fail **loud**, not silent: re-enable `set -euo pipefail`; the only acceptable silent failures are explicitly-wrapped idempotent ops.
- **Non-destructive** on hosts with pre-existing services: never rotate system root creds, never clobber existing web-server config, never grant on the wrong DB cluster.
- **Idempotent**: re-running the installer converges cleanly and preserves admin/data/custom `.env`.
- **Interactive with unattended override**: TTY prompts for the real choices, every choice also settable by env var so the `curl|bash` one-liner and `make install-test` stay unattended.
- Operator chooses the **database engine** (MySQL *or* Postgres) and the install adapts end-to-end.
- Handle a **busy :80** by falling back to :8080 instead of fighting the existing server.

**Non-goals (explicitly deferred)**
- **nginx as a web-server backend.** The panel runtime is Apache-only: website create/delete/runtime-switch shell out to `laranode-add-vhost.sh` / `laranode-vhost-switch.sh`, SSL uses `certbot --apache`. nginx is a separate platform-wide project (parallel vhost backend across `CreateWebsiteService`, `DeleteWebsiteService`, `SwitchRuntimeService`, SSL). Out of scope here.
- Least-privilege MySQL grant (panel keeps `GRANT ALL … WITH GRANT OPTION` so the Databases feature keeps working); revisit later.
- Migrating the panel's MySQL-isms (`enum`, `->after()`) — verified harmless on Postgres (Postgres maps `enum`→CHECK, ignores `after`); no rewrite needed.

## 3. Locked decisions

| # | Decision |
|---|----------|
| D1 | **Approach A** — in-place hardened single-file rewrite. Forced by bootstrap: the installer runs *before* the repo clone, so it can't `source` repo helpers. Structure comes from functions + phases. |
| D2 | **Defer nginx**; Apache-only this pass. |
| D3 | **Single chosen DB engine end-to-end.** `LARANODE_DB_ENGINE=mysql|pgsql` selects the engine for the panel's own backing store **and** user databases. **Only that engine's server package is installed.** |
| D4 | **Prompts + env-var overrides.** `choose()` = env var > TTY prompt > default. `LARANODE_UNATTENDED=1` forces all defaults. |
| D5 | **Web config never touches `000-default.conf`.** Panel gets its own `laranode.conf`. Busy :80 → panel on :8080. |
| D6 | PHP: always install php8.4 (panel hard-dependency) but **never flip the system `php` alternative**; pin panel units/calls to `/usr/bin/php8.4`. Node: warn+skip if present (require major ≥ 20), install 22 only if absent. |

## 4. Design

### 4.1 Structure (single file, phased)

```
#!/bin/bash
set -euo pipefail

# ---- helpers (top of file, before any phase) ----
die()  { echo "FATAL: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
log()  { echo -e "\033[34m== $* ==\033[0m"; }
have_cmd()   { command -v "$1" >/dev/null 2>&1; }
port_in_use(){ ss -tlnH "( sport = :$1 )" | grep -q . ; }     # true if something listens on $1
svc_active() { systemctl is-active --quiet "$1"; }
confirm()    { [ "${LARANODE_UNATTENDED:-0}" = 1 ] && return 0; read -rp "$1 [y/N] " a; [[ $a =~ ^[Yy]$ ]]; }
choose()     { # choose VAR_NAME DEFAULT PROMPT  → echoes resolved value (env > prompt > default)
  local cur="${!1:-}"; if [ -n "$cur" ]; then echo "$cur"; return; fi
  if [ "${LARANODE_UNATTENDED:-0}" = 1 ] || [ ! -t 0 ]; then echo "$2"; return; fi
  read -rp "$3 [$2]: " a; echo "${a:-$2}"; }
env_set()    { # env_set KEY VALUE FILE — add-or-replace a single .env key safely
  local k=$1 v=$2 f=$3; if grep -qE "^${k}=" "$f"; then
    sed -i "s#^${k}=.*#${k}=\"${v}\"#" "$f"; else printf '%s="%s"\n' "$k" "$v" >> "$f"; fi; }
persist_secret(){ printf '%s\n' "$*" >> /root/.laranode-credentials; chmod 600 /root/.laranode-credentials; }
```

### 4.2 Phase 0 — Preflight (read-only, no mutations)

Detect, resolve, plan, confirm — **before any change**:

1. **Detect**: web server on :80 (`port_in_use 80` + identify apache/nginx via `ss -tlnp`), MySQL present + root auth mode (can `mysql -u root` connect via socket?), Postgres clusters + ports (`pg_lsclusters`), `php`/`node` presence + versions, `ufw` active.
2. **Resolve choices** via `choose()`:
   - `LARANODE_DB_ENGINE` = `mysql` (default) | `pgsql`.
   - `LARANODE_HTTP_PORT` = auto: `80` if free, else prompt → default `8080`.
   - plus passthroughs: `LARANODE_MYSQL_ROOT_PASSWORD`, `LARANODE_PG_PORT`, `LARANODE_APP_URL`, `LARANODE_REPO`, `LARANODE_UNATTENDED`.
3. **Print the plan** — e.g. `panel DB=pgsql · panel/site port=8080 (:80 held by nginx, left untouched) · web=apache · php8.4 added, system php left at 8.2`.
4. `confirm "Proceed?"` unless unattended → `die` early on decline. No mutations have happened yet.

### 4.3 Phase 3 — Database (engine-specific, idempotent)

**Common:** generate `LARANODE_DB_PASS=$(openssl rand -base64 18)`; write to `.env` and `persist_secret` **only after** the DB op succeeds.

**MySQL** (`LARANODE_DB_ENGINE=mysql`):
- Install `mysql-server` only.
- **No `ALTER USER root` — ever.**
- Connect: if `mysql -u root -e 'SELECT 1'` works (auth_socket), use it. Else require `LARANODE_MYSQL_ROOT_PASSWORD` (env/prompt) and use `mysql -u root -p"$pass"`; `die` if it can't authenticate.
- `CREATE USER IF NOT EXISTS 'laranode'@'localhost' IDENTIFIED BY '$pass';`
  `ALTER USER 'laranode'@'localhost' IDENTIFIED BY '$pass';`  (password always matches `.env`)
  `CREATE DATABASE IF NOT EXISTS laranode;`
  `GRANT ALL PRIVILEGES ON *.* TO 'laranode'@'localhost' WITH GRANT OPTION; FLUSH PRIVILEGES;`
- `.env`: `DB_CONNECTION=mysql`, host `127.0.0.1`, port `3306`, db/user `laranode`, password `$pass`.

**Postgres** (`LARANODE_DB_ENGINE=pgsql`):
- Install `postgresql postgresql-client` only.
- Resolve target cluster port: `pg_lsclusters --no-header`; if exactly one cluster use it; if multiple, require `LARANODE_PG_PORT` or `die` (ambiguous). `enable --now postgresql@<ver>-<name>`.
- Idempotent role + DB on the resolved port (`sudo -u postgres psql -p <port>`):
  - role `laranode` LOGIN (`DO … IF NOT EXISTS … CREATE ROLE`), then `ALTER ROLE laranode PASSWORD …`.
  - DB `laranode` OWNER `laranode` (create only if absent: guard on `SELECT 1 FROM pg_database`).
  - ensure a `scram-sha-256`/`md5` `pg_hba.conf` line for `laranode` on `127.0.0.1/32` + `reload`.
- Keep the existing `laranode_pg_reader` (`pg_read_all_stats`) provisioning for stats, **bound to the resolved cluster port**.
- `.env`: `DB_CONNECTION=pgsql`, host `127.0.0.1`, port `<resolved>`, db/user `laranode`, password `$pass`.
- **Hard gate:** lab `migrate + seed + boot + login` on Postgres must pass (test scenario 4).

### 4.4 Phase 4 — Web server (Apache, no-clobber + port)

- New template `laranode-scripts/templates/apache-panel.template` with `__PORT__` + `__DOCROOT__` placeholders (`<VirtualHost *:__PORT__>` → `/home/laranode_ln/panel/public`).
- Render to `/etc/apache2/sites-available/laranode.conf` (sed the placeholders). **`000-default.conf` is never written.**
- Port logic:
  - `:80` free → panel on **80**; `a2dissite 000-default` (Apache's own placeholder only) so the panel answers the default host.
  - `:80` busy → panel on **8080**; add `Listen 8080` to `ports.conf` if absent; the existing server on :80 is left fully untouched.
- `a2ensite laranode` → `apachectl configtest` (`die` on failure) → `systemctl reload apache2` → **assert** `svc_active apache2` and `curl -fsS -o /dev/null http://localhost:<port>/` returns 200/302, else `die`.
- UFW: `ufw allow <panel_port>`, `ufw allow 8080` (reverb), `ufw allow 22/443`. (Still no `enable`/`default deny`.)

### 4.5 Phase 1/5 — PHP / Node / app

- **PHP:** install `php8.4*` (additive). Detect current `php` alternative; if it is **not** 8.4, do **not** change it — `warn` that the system default is left as-is and the panel uses `/usr/bin/php8.4` explicitly. Update `laranode-reverb.service` / `laranode-queue-worker.service` templates `ExecStart=/usr/bin/php` → `/usr/bin/php8.4`; installer artisan calls use `php8.4`.
- **Node:** if `node` present → `warn`, skip nodesource; require `node` major ≥ 20 else `die "panel build needs Node ≥ 20; found vX — install/switch and re-run"`. If absent → nodesource 22 + `apt install nodejs`; assert `node -v` major = 22.
- **App provisioning (guarded):**
  - `composer install` after asserting `composer.json` exists (else `die`).
  - `.env`: copy from `.env.example` only if absent. `APP_KEY` via `key:generate` **only if empty** (`grep -q '^APP_KEY=base64:'`).
  - `APP_URL` / `REVERB_HOST` / `VITE_REVERB_HOST`: set from `LARANODE_APP_URL` if given; else from validated non-empty `curl -fsS icanhazip.com`; **skip** the write if the key is already a non-placeholder value. Never write a bare `http://`.
  - `migrate --force` then **assert** exit 0 (`die` on failure). `db:seed --force` **only if the users table is empty** (first-run sentinel) — never re-seed a populated panel.

### 4.6 Phase 6 — services, perms, summary

- daemon-reload, enable+start `laranode-queue-worker` / `laranode-reverb`, reload apache + fpm, with active-state assertions.
- Permissions block unchanged (already scoped to `/home/laranode_ln`).
- **Summary**: print + `persist_secret` all generated credentials to `/root/.laranode-credentials` (0600). Final admin-creation instructions unchanged.

## 5. Env-var interface (the unattended contract)

| Var | Default | Meaning |
|-----|---------|---------|
| `LARANODE_DB_ENGINE` | `mysql` | `mysql` or `pgsql` — the single engine installed + used |
| `LARANODE_HTTP_PORT` | auto (80, else 8080) | panel/site Apache port |
| `LARANODE_MYSQL_ROOT_PASSWORD` | — | existing MySQL root password (when not auth_socket) |
| `LARANODE_PG_PORT` | auto | disambiguate multiple Postgres clusters |
| `LARANODE_APP_URL` | auto (public IP) | override APP_URL/REVERB host |
| `LARANODE_REPO` | GitHub fork URL | clone source (used by the test harness) |
| `LARANODE_UNATTENDED` | `0` | `1` = take all defaults, no prompts/confirm |

## 6. Testing (hard gate — clean-room matrix)

Extend `local-dev/install-test/` with a scenario matrix; each boots a container, runs the **real** installer, and asserts services active + HTTP + admin login:

1. **baseline** — bare `ubuntu:24.04`, defaults → panel :80, mysql. (existing test)
2. **nginx on :80** — pre-start nginx → assert panel auto-lands on :8080 **and** nginx still answers :80.
3. **mysql with root password** — pre-install mysql + set a root password → run with `LARANODE_MYSQL_ROOT_PASSWORD` → assert root password **unchanged**, `laranode` DB created, panel boots.
4. **postgres engine** — `LARANODE_DB_ENGINE=pgsql` → assert panel migrates/seeds/boots on Postgres + login works.
5. **idempotent re-run** — run the installer twice → assert no error under `set -e`, admin + data + custom `.env` preserved.

Pest/Vitest suites are unaffected (installer is bash; covered by the clean-room harness). Per repo policy, the four-part verify gate still applies to any panel-side change.

## 7. Consequences / follow-ups (out of scope here)

- **Single-engine UI guard:** with only one engine installed, the panel's Databases feature should offer only that engine. Record the installed engine (e.g. `.env` `LARANODE_DB_ENGINE` or `options` row) and filter the Databases UI/service accordingly — small panel-side follow-up, tracked separately.
- **nginx backend** — separate future project (D2).
- **Least-privilege MySQL grant** — future.

## 8. Risks

- **Postgres-backed panel** is the newest path; the migrate/seed/boot/login gate (scenario 4) is mandatory before merge.
- **`pg_hba.conf` editing** varies by distro layout; resolve via the cluster's own `pg_hba.conf` path from `pg_lsclusters`, reload, and assert a test connection as `laranode`.
- **`set -euo pipefail`** may surface latent failures the old script hid; every intentionally-tolerated command must be wrapped (`… || true`) deliberately, with a comment.
