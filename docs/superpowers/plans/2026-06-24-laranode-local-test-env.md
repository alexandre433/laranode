# Laranode Local Test/Dev Environment — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Laranode a single, disposable, systemd-enabled "VPS-in-a-box" Docker container on the local Windows/WSL2 machine that runs the real provisioning stack, plus a SQLite-decoupled path to green the Pest suite.

**Architecture:** One Ubuntu 24.04 container (systemd as PID 1, based on the proven `jrei/systemd-ubuntu:24.04`) with the repo bind-mounted to the hardcoded path `/home/laranode_ln/panel`. Build-time layers install all software; a runtime `entrypoint-setup.sh` provisions services, DB, and the app. Executable privileged scripts are copied to a Linux-native path (`/opt/laranode/bin`) to dodge Windows bind-mount exec-bit problems. SSL is exercised against a local Pebble ACME server. All tooling lives in gitignored `local-dev/`.

**Tech Stack:** Docker Desktop (WSL2 backend), docker compose, Ubuntu 24.04 + systemd, Apache2, MySQL, PHP 8.4-FPM, Composer, Node 22, certbot + Pebble, Laravel 12 / Pest 3.

## Global Constraints

- **Bind-mount target is exact and immutable:** repo root → `/home/laranode_ln/panel`. The sudoers line and both systemd unit templates hardcode this path; do not relocate.
- **Container run flags (all required together):** `privileged: true`, `cgroupns_mode: host`, `/sys/fs/cgroup:/sys/fs/cgroup:rw` (rw — systemd 255 refuses ro), `tmpfs: /run, /run/lock, /tmp`, `stop_signal: SIGRTMIN+3`.
- **Bind services to `0.0.0.0`**, never `127.0.0.1` (WSL2 loopback is unreachable from Windows).
- **Executable scripts must NOT run off the bind mount.** They live on `/opt/laranode/bin` (Linux-native), selected via `LARANODE_BIN_PATH`.
- **In-repo changes are limited to exactly three files:** `phpunit.xml`, `config/laranode.php`, `tests/Feature/Filemanager/CreateFileTest.php`. Everything else goes in gitignored `local-dev/`. (The third file realizes spec §9's "skip with documented reason" — surfaced here because it edits a tracked test.)
- **Never report a falsely-green suite:** the two `CreateFileTest` happy-path tests are conditionally skipped with a printed reason; the run output must show them as skipped.
- **Branch:** all work on `local-dev-env` (already created; the spec is committed there).
- **Windows shell note:** verification commands are shown as raw `docker compose` / `docker exec` (always available with Docker Desktop). A `Makefile` wraps them for convenience; if `make` is absent on the host, run the raw command shown instead.

> **Deviation from spec §12 (surfaced, not silent):** the spec listed a standalone `local-dev/install/laranode-installer.docker.sh`. To stay DRY, its logic is split between the **Dockerfile** (build-time software installs) and **`entrypoint-setup.sh`** (runtime provisioning) rather than duplicated in a third script. The exact deltas from the upstream installer (spec §8) are realized across those two files and called out in Task 4.

---

### Task 1: Repo-side enablers (SQLite tests, env-overridable bin path, gitignore, conditional test skip)

Smallest standalone deliverable: the Pest suite runs green on the Windows host (PHP 8.4.20 already installed), fully decoupled from Docker. Satisfies spec goal #3 immediately.

**Files:**
- Modify: `phpunit.xml` (the two commented DB lines)
- Modify: `config/laranode.php:13`
- Modify: `tests/Feature/Filemanager/CreateFileTest.php` (guard the two system-dependent tests)
- Modify: `.gitignore` (add `/local-dev`)

**Interfaces:**
- Produces: env var contract `LARANODE_BIN_PATH` (default = `base_path('laranode-scripts/bin')`) consumed by every Service/Action that shells out, and by `.env.docker` (Task 3) which sets it to `/opt/laranode/bin`.

- [ ] **Step 1: Run the suite first to see the current state**

Run (from repo root, Git Bash or PowerShell):
```bash
php artisan test
```
Expected: failures/errors — the DB lines in `phpunit.xml` are commented, so it tries MySQL `127.0.0.1:3306` and dies (connection refused), or errors before running. Record that it does NOT cleanly pass. This is the baseline we fix.

- [ ] **Step 2: Enable SQLite in `phpunit.xml`**

Find these two commented lines:
```xml
        <!-- <env name="DB_CONNECTION" value="sqlite"/> -->
        <!-- <env name="DB_DATABASE" value=":memory:"/> -->
```
Replace with (uncommented):
```xml
        <env name="DB_CONNECTION" value="sqlite"/>
        <env name="DB_DATABASE" value=":memory:"/>
```

- [ ] **Step 3: Make the script bin path env-overridable in `config/laranode.php`**

Change line 13 from:
```php
    'laranode_bin_path' => base_path('laranode-scripts/bin'),
```
to:
```php
    'laranode_bin_path' => env('LARANODE_BIN_PATH', base_path('laranode-scripts/bin')),
```
(Production default is unchanged; only an explicit env var overrides it.)

- [ ] **Step 4: Guard the two system-dependent filemanager tests**

Open `tests/Feature/Filemanager/CreateFileTest.php`. The two happy-path tests call the real `sudo laranode-file-permissions.sh` and require a real auth user. Add a skip guard at the top of the file's test closures that depend on the system. Insert this helper skip at the very start of each of the two affected `test(...)`/`it(...)` blocks (the file-create and directory-create happy paths):

```php
test('it can create a new file', function () {
    if (! getenv('LARANODE_SYSTEM_TESTS')) {
        $this->markTestSkipped('Requires a Linux host with sudo + laranode scripts; run inside the dev container with LARANODE_SYSTEM_TESTS=1.');
    }
    // ...existing test body unchanged...
});
```
Apply the identical 3-line guard to the directory-create happy-path test. Leave every other test in the file untouched. (Read the file first to copy the exact existing test names/bodies — do not rename them.)

- [ ] **Step 5: Ignore the tooling directory in `.gitignore`**

Append to `.gitignore`:
```
/local-dev
```

- [ ] **Step 6: Run the suite and confirm green with the two skips**

Run:
```bash
php artisan test
```
Expected: PASS overall. Output shows the two `CreateFileTest` tests as **skipped** with the printed reason, all other tests passing. If any non-skipped test fails, stop and investigate before committing.

- [ ] **Step 7: Commit**

```bash
git add phpunit.xml config/laranode.php tests/Feature/Filemanager/CreateFileTest.php .gitignore
git commit -m "test: run Pest on SQLite + env-overridable script path for local dev

- phpunit.xml: enable sqlite :memory: so the suite runs with no external DB
- config/laranode.php: LARANODE_BIN_PATH env override (prod default unchanged)
- CreateFileTest: skip two host-dependent tests unless LARANODE_SYSTEM_TESTS=1
- gitignore local-dev/ tooling

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01E4JwS6k6MyYJVv27KRyW2d"
```

---

### Task 2: Dockerfile — systemd base + baked software stack

Deliverable: an image that boots systemd as PID 1 and has every binary the panel needs already installed.

**Files:**
- Create: `local-dev/Dockerfile`

**Interfaces:**
- Produces: image with `/opt/laranode/bin-src/` (snapshot of `laranode-scripts/bin`), user `laranode_ln`, `www-data` in group `laranode_ln`, and `policy-rc.d` blocking service auto-start during build. Consumed by the compose `build` in Task 5 and the entrypoint in Task 4.

- [ ] **Step 1: Write the Dockerfile**

Create `local-dev/Dockerfile`:
```dockerfile
# Proven on this machine: jrei/systemd-ubuntu:24.04 boots systemd as PID 1 under
# Docker Desktop / WSL2 (cgroup2fs). It sets STOPSIGNAL + CMD [/lib/systemd/systemd]
# and masks the noisy units for us.
FROM jrei/systemd-ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Block package post-install scripts from trying to start services during BUILD
# (no systemd running in a build layer). Runtime systemctl is unaffected.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

# Base tooling + Apache + MySQL + sysstat + ufw + certbot + the ondrej PPA.
RUN apt-get update && apt-get install -y \
        software-properties-common git curl unzip openssl ca-certificates \
        iproute2 dbus sudo \
        apache2 \
        mysql-server \
        sysstat \
        ufw \
        certbot python3-certbot-apache \
    && add-apt-repository -y ppa:ondrej/php \
    && apt-get update

# PHP 8.4 + the exact extension set from laranode-scripts/bin/laranode-installer.sh
RUN apt-get install -y \
        php8.4 php8.4-fpm php8.4-cli php8.4-common php8.4-curl php8.4-mbstring \
        php8.4-xml php8.4-bcmath php8.4-zip php8.4-mysql php8.4-sqlite3 php8.4-pgsql \
        php8.4-gd php8.4-imagick php8.4-intl php8.4-readline php8.4-tokenizer php8.4-fileinfo \
        php8.4-soap php8.4-opcache

# Composer (php is present now) + Node 22
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs

# Apache modules + php-fpm conf, enabled at build (no service start needed for a2enmod)
RUN a2enmod proxy_fcgi rewrite setenvif headers ssl && a2enconf php8.4-fpm

# Panel system user; www-data shares its group so Apache can read panel files
RUN useradd -m -s /bin/bash laranode_ln && usermod -aG laranode_ln www-data \
    && mkdir -p /home/laranode_ln/logs

# Snapshot the privileged scripts to a Linux-native path (entrypoint copies these
# to /opt/laranode/bin with +x; the bind-mounted copies can't be relied on for exec).
COPY laranode-scripts/bin/ /opt/laranode/bin-src/
RUN chmod -R 0755 /opt/laranode/bin-src

# systemd remains PID 1 from the base image (CMD + STOPSIGNAL inherited).
```

- [ ] **Step 2: Build the image**

Run (from repo root — context must be the repo root so `COPY laranode-scripts/...` resolves):
```bash
docker build -f local-dev/Dockerfile -t laranode-lab:dev .
```
Expected: build completes successfully (the `policy-rc.d` shim prevents the mysql/apache postinst from failing the build).

- [ ] **Step 3: Boot it and verify systemd + every binary is present**

Run:
```bash
cid=$(MSYS_NO_PATHCONV=1 docker run -d --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock laranode-lab:dev)
sleep 5
MSYS_NO_PATHCONV=1 docker exec "$cid" bash -lc '
  systemctl is-system-running || true
  ps -p 1 -o comm=
  php -v | head -1; composer --version; node -v; mysql --version; apache2 -v | head -1; certbot --version; ufw --version | head -1
  ls /opt/laranode/bin-src | head'
MSYS_NO_PATHCONV=1 docker rm -f "$cid"
```
Expected: `running` (or `degraded`), PID 1 = `systemd`, and a version line for php 8.4 / composer / node v22 / mysql / apache / certbot / ufw, plus a listing of the snapshotted scripts (e.g. `laranode-add-vhost.sh`).

- [ ] **Step 4: Commit**

```bash
git add local-dev/Dockerfile
git commit -m "build: systemd-enabled Ubuntu 24.04 image with full Laranode stack

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01E4JwS6k6MyYJVv27KRyW2d"
```

---

### Task 3: `.env.docker` + patched SSL manager

Deliverable: the runtime config and the one patched script, validated for syntax/content. No services yet.

**Files:**
- Create: `local-dev/.env.docker`
- Create: `local-dev/bin/laranode-ssl-manager.sh` (patched copy)

**Interfaces:**
- Produces: `.env.docker` keys consumed by `entrypoint-setup.sh` (Task 4): `DB_PASSWORD`, `ADMIN_EMAIL`, `ADMIN_PASSWORD`, `LARANODE_BIN_PATH`, `LARANODE_ACME_SERVER`. And the patched `laranode-ssl-manager.sh` consumed by the entrypoint (overwrites `/opt/laranode/bin/laranode-ssl-manager.sh`).

- [ ] **Step 1: Create `local-dev/.env.docker`**

```dotenv
APP_NAME=Laranode
APP_ENV=local
APP_KEY=
APP_DEBUG=true
APP_URL=http://localhost

LOG_CHANNEL=stack
LOG_LEVEL=debug

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=laranode
DB_USERNAME=laranode
DB_PASSWORD=laranode_local_dev_pw

SESSION_DRIVER=database
QUEUE_CONNECTION=database
CACHE_STORE=database
BROADCAST_CONNECTION=reverb
FILESYSTEM_DISK=local

REVERB_APP_ID=laranode
REVERB_APP_KEY=laranode-key
REVERB_APP_SECRET=laranode-secret
REVERB_HOST=localhost
REVERB_PORT=8080
REVERB_SCHEME=http

VITE_REVERB_APP_KEY="${REVERB_APP_KEY}"
VITE_REVERB_HOST=localhost
VITE_REVERB_PORT=8080
VITE_REVERB_SCHEME=http

# Local-dev only — consumed by entrypoint-setup.sh, NOT by upstream code paths
LARANODE_BIN_PATH=/opt/laranode/bin
LARANODE_ACME_SERVER=https://pebble:14000/dir
ADMIN_EMAIL=admin@laranode.test
ADMIN_PASSWORD=password
```

- [ ] **Step 2: Create the patched SSL manager**

Copy the repo's `laranode-scripts/bin/laranode-ssl-manager.sh` into `local-dev/bin/laranode-ssl-manager.sh`, then apply exactly two changes so it works locally against Pebble:

1. In `check_domain_accessibility()`, make the curl gate non-fatal when running locally. Replace the body's failing branch so it warns instead of `exit 1`:
```bash
check_domain_accessibility() {
    local domain=$1
    print_status "Checking if domain $domain is accessible..."
    if ! curl -s --connect-timeout 10 "http://$domain" > /dev/null; then
        print_warning "Domain $domain not reachable over HTTP — continuing anyway (local dev)."
    else
        print_status "Domain $domain is accessible"
    fi
}
```

2. In `generate_ssl_certificate()`, pass the Pebble server flags to certbot when `LARANODE_ACME_SERVER` is set. Replace the `certbot certonly ...` invocation with:
```bash
    local acme_args=()
    if [ -n "$LARANODE_ACME_SERVER" ]; then
        acme_args=(--server "$LARANODE_ACME_SERVER" --no-verify-ssl)
    fi

    if certbot certonly \
        --webroot \
        --webroot-path="$webroot_path" \
        --email "$email" \
        --agree-tos \
        --no-eff-email \
        --domains "$domain" \
        --non-interactive \
        "${acme_args[@]}"; then
```
Leave the rest of the file (vhost creation, status, remove, renew) identical to upstream.

- [ ] **Step 3: Syntax-check both artifacts and assert the deltas**

Run:
```bash
bash -n local-dev/bin/laranode-ssl-manager.sh && echo "ssl-manager syntax OK"
grep -q 'LARANODE_ACME_SERVER' local-dev/bin/laranode-ssl-manager.sh && echo "ACME server wired"
grep -q 'continuing anyway' local-dev/bin/laranode-ssl-manager.sh && echo "accessibility gate softened"
grep -q 'LARANODE_BIN_PATH=/opt/laranode/bin' local-dev/.env.docker && echo "bin path set"
grep -q 'icanhazip' local-dev/.env.docker && echo "BAD: icanhazip present" || echo "no icanhazip OK"
```
Expected: `ssl-manager syntax OK`, `ACME server wired`, `accessibility gate softened`, `bin path set`, `no icanhazip OK`.

- [ ] **Step 4: Commit**

```bash
git add local-dev/.env.docker local-dev/bin/laranode-ssl-manager.sh
git commit -m "feat(local-dev): env config + Pebble-aware SSL manager

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01E4JwS6k6MyYJVv27KRyW2d"
```

---

### Task 4: `entrypoint-setup.sh` — idempotent runtime provisioning

Deliverable: the script that turns a freshly-booted container into a working panel. Validated for syntax here; exercised end-to-end in Task 6.

**Files:**
- Create: `local-dev/entrypoint-setup.sh`

**Interfaces:**
- Consumes: `.env.docker` (Task 3), `/opt/laranode/bin-src` + `laranode_ln` user (Task 2), `local-dev/bin/laranode-ssl-manager.sh` (Task 3), the unchanged repo templates under `laranode-scripts/templates/`.
- Produces: a provisioned, running panel; a sentinel file `/home/laranode_ln/.laranode-setup-done` marking completion (re-runs skip already-done sections).

This script realizes spec §8's installer deltas at runtime: **no git clone** (repo is mounted), **no icanhazip** (localhost baked via `.env.docker`), **non-interactive admin seed** (replaces the manual `create-admin`).

- [ ] **Step 1: Write `local-dev/entrypoint-setup.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

PANEL=/home/laranode_ln/panel
BIN=/opt/laranode/bin
SENTINEL=/home/laranode_ln/.laranode-setup-done

log() { echo -e "\033[34m[setup]\033[0m $*"; }

# --- wait for systemd ---
log "waiting for systemd..."
for i in $(seq 1 30); do
  state=$(systemctl is-system-running 2>/dev/null || true)
  [ "$state" = running ] || [ "$state" = degraded ] && break
  sleep 1
done

# --- core services ---
log "enabling + starting core services"
sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat || true
systemctl enable --now apache2 mysql php8.4-fpm sysstat

# --- wait for mysql socket ---
log "waiting for mysql..."
for i in $(seq 1 30); do
  mysqladmin ping >/dev/null 2>&1 && break
  sleep 1
done

# --- load env (for DB_PASSWORD, ADMIN_*, etc.) ---
set -a; . "$PANEL/local-dev/.env.docker"; set +a

# --- linux-native bin dir with executable scripts + patched ssl-manager ---
log "populating $BIN"
mkdir -p "$BIN"
cp -f /opt/laranode/bin-src/*.sh "$BIN"/
cp -f "$PANEL/local-dev/bin/laranode-ssl-manager.sh" "$BIN/laranode-ssl-manager.sh"
chmod -R 0755 "$BIN"

# --- container sudoers (www-data runs the scripts; mirrors installer line 172 + new path) ---
log "writing sudoers"
cat > /etc/sudoers.d/laranode <<EOF
www-data ALL=(ALL) NOPASSWD: $BIN/*.sh, /usr/sbin/a2dissite, /bin/rm /etc/apache2/sites-available/*.conf
EOF
chmod 440 /etc/sudoers.d/laranode

# --- MySQL user + db (idempotent; grant for localhost and 127.0.0.1) ---
log "creating mysql user + db"
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_DATABASE};
CREATE USER IF NOT EXISTS '${DB_USERNAME}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
CREATE USER IF NOT EXISTS '${DB_USERNAME}'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO '${DB_USERNAME}'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '${DB_USERNAME}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

# --- app: .env, deps, key, migrate, seed ---
cd "$PANEL"
[ -f .env ] || cp local-dev/.env.docker .env
mkdir -p storage/logs
[ -d vendor ] && [ -n "$(ls -A vendor 2>/dev/null)" ] || composer install --no-interaction
grep -q '^APP_KEY=base64' .env || php artisan key:generate --force
php artisan migrate --force
php artisan db:seed --force || true
php artisan storage:link || true
php artisan reverb:install --no-interaction || true

# --- node deps + build (only if missing) ---
[ -d node_modules ] && [ -n "$(ls -A node_modules 2>/dev/null)" ] || npm install
[ -d public/build ] || npm run build

# --- seed admin non-interactively (username 'laranode' to match systemUsername laranode_ln) ---
log "seeding admin"
php artisan tinker --execute "
\App\Models\User::firstOrCreate(
  ['username' => 'laranode'],
  ['name' => 'Admin', 'email' => env('ADMIN_EMAIL'), 'password' => bcrypt(env('ADMIN_PASSWORD')), 'role' => 'admin', 'ssh_access' => true]
);"

# --- apache default vhost (serves the panel from /public) ---
cp -f laranode-scripts/templates/apache2-default.template /etc/apache2/sites-available/000-default.conf
systemctl reload apache2

# --- seed one sysstat sample so dashboard history isn't empty ---
mkdir -p /var/log/sysstat
sadc 1 1 "/var/log/sysstat/sa$(date +%d)" 2>/dev/null || true

# --- firewall (container netns only) ---
ufw --force enable || true
for p in 22 80 443 8080; do ufw allow "$p" || true; done

# --- panel services: reverb + queue worker ---
cp -f laranode-scripts/templates/laranode-queue-worker.service /etc/systemd/system/laranode-queue-worker.service
cp -f laranode-scripts/templates/laranode-reverb.service /etc/systemd/system/laranode-reverb.service
systemctl daemon-reload
systemctl enable --now laranode-queue-worker.service laranode-reverb.service
systemctl restart apache2 php8.4-fpm

# --- ownership (best-effort over bind mount) ---
chown -R laranode_ln:laranode_ln /home/laranode_ln/logs || true

touch "$SENTINEL"
log "DONE. Panel at http://localhost  (admin: ${ADMIN_EMAIL} / ${ADMIN_PASSWORD})"
```

- [ ] **Step 2: Syntax check**

Run:
```bash
bash -n local-dev/entrypoint-setup.sh && echo "entrypoint syntax OK"
```
Expected: `entrypoint syntax OK`.

- [ ] **Step 3: Commit**

```bash
git add local-dev/entrypoint-setup.sh
git commit -m "feat(local-dev): idempotent runtime provisioning entrypoint

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01E4JwS6k6MyYJVv27KRyW2d"
```

---

### Task 5: `docker-compose.yml`

Deliverable: a validated compose file wiring the systemd container (and opt-in Pebble sidecars).

**Files:**
- Create: `local-dev/docker-compose.yml`

**Interfaces:**
- Consumes: the image built from `local-dev/Dockerfile` (context = repo root).
- Produces: service `laranode` (the dev box) and `pebble` + `challtestsrv` under profile `ssl`; named volumes `laranode-vendor`, `laranode-node-modules`, `laranode-mysql`.

- [ ] **Step 1: Write `local-dev/docker-compose.yml`**

```yaml
services:
  laranode:
    build:
      context: ..
      dockerfile: local-dev/Dockerfile
    image: laranode-lab:dev
    container_name: laranode-lab
    privileged: true
    cgroup: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
    stop_signal: SIGRTMIN+3
    volumes:
      - ../:/home/laranode_ln/panel
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
      - laranode-vendor:/home/laranode_ln/panel/vendor
      - laranode-node-modules:/home/laranode_ln/panel/node_modules
      - laranode-mysql:/var/lib/mysql
    tmpfs:
      - /run
      - /run/lock
      - /tmp
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"
      - "5173:5173"
      - "3306:3306"

  pebble:
    image: ghcr.io/letsencrypt/pebble:latest
    profiles: ["ssl"]
    command: -config /test/config/pebble-config.json -dnsserver 10.30.50.3:8053
    environment:
      PEBBLE_VA_ALWAYS_VALID: "1"
    ports:
      - "14000:14000"
      - "15000:15000"
    networks:
      default:
        ipv4_address: 10.30.50.2
    depends_on:
      - challtestsrv

  challtestsrv:
    image: ghcr.io/letsencrypt/pebble-challtestsrv:latest
    profiles: ["ssl"]
    command: -defaultIPv4 ""
    ports:
      - "8055:8055"
    networks:
      default:
        ipv4_address: 10.30.50.3

networks:
  default:
    ipam:
      config:
        - subnet: 10.30.50.0/24

volumes:
  laranode-vendor:
  laranode-node-modules:
  laranode-mysql:
```

Note: compose's `cgroup: host` is the Compose-file spelling of `--cgroupns=host`. `PEBBLE_VA_ALWAYS_VALID=1` makes Pebble skip HTTP-01 validation so a cert issues without full DNS wiring — enough to smoke-test the panel's SSL flow.

- [ ] **Step 2: Validate the compose file**

Run:
```bash
docker compose -f local-dev/docker-compose.yml config >/dev/null && echo "compose valid"
docker compose -f local-dev/docker-compose.yml config | grep -q 'cgroup: host' && echo "cgroupns host set"
```
Expected: `compose valid` and `cgroupns host set`. (If your compose version rejects `cgroup: host`, fall back to running via the Makefile's raw `docker run` flags in Task 6 — note it and continue.)

- [ ] **Step 3: Commit**

```bash
git add local-dev/docker-compose.yml
git commit -m "feat(local-dev): compose for systemd box + opt-in Pebble sidecars

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01E4JwS6k6MyYJVv27KRyW2d"
```

---

### Task 6: Makefile + first full boot (integration)

Deliverable: `make up` builds, boots, and provisions a working panel reachable at `http://localhost`; `make verify` confirms services; `make test` runs Pest in-container.

**Files:**
- Create: `local-dev/Makefile`

**Interfaces:**
- Consumes: everything from Tasks 2–5.
- Produces: the task-runner commands `up`, `provision`, `sh`, `verify`, `test`, `test-system`, `build-assets`, `sync-scripts`, `logs`, `nuke`.

- [ ] **Step 1: Write `local-dev/Makefile`**

```makefile
COMPOSE = docker compose -f local-dev/docker-compose.yml
EXEC = $(COMPOSE) exec laranode bash -lc

.PHONY: up provision sh verify test test-system build-assets sync-scripts logs nuke ssl-test

up:
	$(COMPOSE) up -d --build
	$(MAKE) -f local-dev/Makefile provision

provision:
	$(EXEC) '/home/laranode_ln/panel/local-dev/entrypoint-setup.sh'

sh:
	$(COMPOSE) exec laranode bash

verify:
	$(EXEC) 'ps -p 1 -o comm=; systemctl is-system-running || true; \
	  for s in apache2 mysql php8.4-fpm laranode-reverb laranode-queue-worker; do \
	    printf "%s: " "$$s"; systemctl is-active $$s; done'
	@echo "--- HTTP check ---"
	@curl -s -o /dev/null -w "panel http status: %{http_code}\n" http://localhost || true

test:
	$(EXEC) 'cd /home/laranode_ln/panel && php artisan test'

test-system:
	$(EXEC) 'cd /home/laranode_ln/panel && LARANODE_SYSTEM_TESTS=1 php artisan test'

build-assets:
	$(EXEC) 'cd /home/laranode_ln/panel && npm run build'

sync-scripts:
	$(EXEC) 'cp -f /opt/laranode/bin-src/*.sh /opt/laranode/bin/ && \
	  cp -f /home/laranode_ln/panel/local-dev/bin/laranode-ssl-manager.sh /opt/laranode/bin/ && \
	  chmod -R 0755 /opt/laranode/bin'

ssl-test:
	$(COMPOSE) --profile ssl up -d
	$(EXEC) 'sudo LARANODE_ACME_SERVER=$${LARANODE_ACME_SERVER:-https://pebble:14000/dir} \
	  /opt/laranode/bin/laranode-ssl-manager.sh status localhost || true'

logs:
	$(COMPOSE) logs -f

nuke:
	$(COMPOSE) --profile ssl down -v
```

- [ ] **Step 2: Bring the box up and provision it**

Run (from repo root):
```bash
make -f local-dev/Makefile up
```
(Or, if `make` is unavailable: `docker compose -f local-dev/docker-compose.yml up -d --build` then `docker compose -f local-dev/docker-compose.yml exec laranode bash -lc '/home/laranode_ln/panel/local-dev/entrypoint-setup.sh'`.)
Expected: build completes; the entrypoint prints `[setup] DONE. Panel at http://localhost`.

- [ ] **Step 3: Verify services + panel**

Run:
```bash
make -f local-dev/Makefile verify
```
Expected: PID 1 = `systemd`; `apache2`, `mysql`, `php8.4-fpm`, `laranode-reverb`, `laranode-queue-worker` each report `active`; `panel http status: 200` or `302` (redirect to `/dashboard` → `/login`).

- [ ] **Step 4: Run the Pest suite in-container**

Run:
```bash
make -f local-dev/Makefile test
```
Expected: PASS with the two `CreateFileTest` tests skipped (same as host). Optionally `make -f local-dev/Makefile test-system` runs them for real (they may still need the auth fix — if they fail, that's the documented known gap, not a regression).

- [ ] **Step 5: Manual login smoke (browser)**

Open `http://localhost`, log in with `admin@laranode.test` / `password`. Expected: the admin dashboard renders and live stats populate over Reverb (ws on :8080).

- [ ] **Step 6: Commit**

```bash
git add local-dev/Makefile
git commit -m "feat(local-dev): Makefile task runner + verified full boot

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01E4JwS6k6MyYJVv27KRyW2d"
```

---

### Task 7: Provisioning + SSL smoke tests

Deliverable: prove the panel really provisions the host — create a website and confirm a real Apache vhost + PHP-FPM pool + served site; then issue a cert via Pebble.

**Files:** none (verification only; uses the running box from Task 6).

- [ ] **Step 1: Create a website through the panel and capture artifacts**

In the browser (logged in as admin), create a website with URL `demo.test`. Then run:
```bash
docker compose -f local-dev/docker-compose.yml exec laranode bash -lc '
  echo "--- vhost ---"; ls -l /etc/apache2/sites-available/demo.test.conf && a2query -s demo.test;
  echo "--- fpm pool ---"; ls -l /etc/php/8.4/fpm/pool.d/ | grep -i laranode || ls /etc/php/8.4/fpm/pool.d/;
  echo "--- docroot ---"; ls -ld /home/laranode_ln/domains/demo.test;
  echo "--- serve check ---"; curl -s -o /dev/null -w "%{http_code}\n" -H "Host: demo.test" http://localhost'
```
Expected: the vhost `.conf` exists and is enabled, a PHP-FPM pool file for the user exists, the document root directory exists, and the `Host: demo.test` request returns an HTTP status (200/403/404 — a response from Apache, proving the vhost is live).

- [ ] **Step 2: Issue an SSL cert via Pebble**

Bring up the SSL sidecars and drive issuance for `demo.test`:
```bash
docker compose -f local-dev/docker-compose.yml --profile ssl up -d
docker compose -f local-dev/docker-compose.yml exec laranode bash -lc '
  sudo LARANODE_ACME_SERVER=https://pebble:14000/dir \
    /opt/laranode/bin/laranode-ssl-manager.sh generate demo.test admin@laranode.test /home/laranode_ln/domains/demo.test/public_html;
  sudo /opt/laranode/bin/laranode-ssl-manager.sh status demo.test'
```
Expected: certbot completes against Pebble (with `PEBBLE_VA_ALWAYS_VALID=1` it skips HTTP-01), `status demo.test` prints `active`. (Triggering this through the panel UI SSL toggle is the same path — try that too.)

- [ ] **Step 3: Final disposability check**

Run:
```bash
make -f local-dev/Makefile nuke
docker volume ls | grep laranode || echo "all laranode volumes gone"
```
Expected: container + named volumes removed; re-running `make -f local-dev/Makefile up` rebuilds a clean box.

- [ ] **Step 4: Update the project CLAUDE.md with the local-dev workflow**

Add a short "Local dev/test (Docker)" section to the root `CLAUDE.md` pointing at `local-dev/` and the key `make` targets (`up`, `verify`, `test`, `ssl-test`, `nuke`), and note the gitignored location. Keep it to ~6 lines. Commit:
```bash
git add CLAUDE.md
git commit -m "docs: document local-dev Docker workflow in CLAUDE.md

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01E4JwS6k6MyYJVv27KRyW2d"
```

---

## Self-Review

**1. Spec coverage:**
- §2 one-container/bind-mount → Tasks 2, 5 ✓
- §3 decisions (Pebble / multi-version PHP / gitignored / always-on reverb) → Tasks 3 (Pebble env), 2 (ondrej PPA enables runtime multi-version), 1 (.gitignore), 4 (reverb+queue enabled) ✓
- §4 architecture (flags, mounts, volumes, ports, sidecars) → Task 5 ✓
- §5 fidelity limits → encoded as behavior (ufw best-effort in Task 4; Pebble untrusted noted) ✓
- §6 Linux-native bin path → Task 1 (env), Task 2 (bin-src), Task 4 (populate + sudoers) ✓
- §7 patched SSL → Task 3 ✓
- §8 installer deltas → Dockerfile (Task 2) + entrypoint (Task 4), deviation noted ✓
- §9 Pest path + 2 skips → Task 1, Task 6 ✓
- §10 dev loop/disposability → bind mount + named volumes (Task 5), `nuke` (Tasks 6/7) ✓
- §11 exactly-three in-repo changes → Task 1 (note: three, not two — the test-skip is surfaced as the realization of §9) ✓
- §13 verification → Tasks 6, 7 ✓

**2. Placeholder scan:** No TBD/TODO; every file has full content; commands have expected output. The only intentionally-deferred item is the optional real HTTP-01 validation (PEBBLE_VA_ALWAYS_VALID short-circuits it), explicitly flagged — not a placeholder.

**3. Type/contract consistency:** `LARANODE_BIN_PATH` (Task 1 default ↔ Task 3 value ↔ Task 4 consumer) consistent; `/opt/laranode/bin` and `/opt/laranode/bin-src` used consistently (Task 2 creates bin-src, Task 4 populates bin); `LARANODE_ACME_SERVER` consistent (Task 3 sets ↔ Task 3 ssl-manager consumes ↔ Task 7 uses); service names (`laranode-reverb`, `laranode-queue-worker`, `php8.4-fpm`) consistent across Tasks 4, 6; admin creds (`admin@laranode.test`/`password`) consistent (Task 3 ↔ Tasks 4, 6).

**Known gap surfaced (fail-loud):** in-repo changes are **three**, not the two I quoted earlier — the third is the conditional skip in `CreateFileTest.php`, which is the natural realization of spec §9 ("skip with documented reason"). Flagged in Global Constraints and Task 1.
