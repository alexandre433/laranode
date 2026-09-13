#!/bin/bash
#
# laranode-upgrade.sh — idempotent in-place upgrade for an existing Laranode install.
#
# Run as root on a host that already has Laranode installed:
#   sudo /home/laranode_ln/panel/laranode-scripts/bin/laranode-upgrade.sh
#
# It (re)applies the provisioning that a code-only `git pull` does NOT give you:
# new packages, new sudoers drop-ins, the PostgreSQL stats-reader role, new .env
# keys, the systemd units (including the scheduler timer that drives
# `artisan schedule:run`), migrations and an asset rebuild.
#
# Unlike laranode-installer.sh this script never performs one-time destructive
# steps: it does not rotate the MySQL root password, does not re-seed the
# database, and does not regenerate APP_KEY. Running it twice is a no-op.
#
# NOTE: laranode-installer.sh provisioned the original install. This script
# deliberately re-states the steps that must be re-applied, so the two must be
# kept in sync — every new drop-in, package or .env key belongs in both.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Overridable so the harness can run this against a throwaway copy of the panel.
PANEL_PATH="${LARANODE_PANEL_PATH:-/home/laranode_ln/panel}"
LARANODE_REPO="${LARANODE_REPO:-https://github.com/crivion/laranode.git}"

log() { echo -e "\033[34m[upgrade]\033[0m $*"; }
warn() { echo -e "\033[33m[upgrade]\033[0m $*" >&2; }

[ "$(id -u)" -eq 0 ] || { warn "must run as root"; exit 1; }
[ -d "${PANEL_PATH}/laranode-scripts" ] || { warn "no Laranode install at ${PANEL_PATH}"; exit 1; }

# Read a value out of the panel .env, stripping surrounding quotes.
env_value() {
    grep -E "^$1=" "${PANEL_PATH}/.env" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^"//; s/"$//'
}

# Append KEY="value" only when KEY is absent — never overwrite operator-set values.
ensure_env() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "${PANEL_PATH}/.env" 2>/dev/null; then
        return 0
    fi
    echo "${key}=\"${value}\"" >> "${PANEL_PATH}/.env"
    log "  .env: added ${key}"
}

# ==============================================================================
# 1. Fetch the new code
# ==============================================================================

log "updating ${PANEL_PATH} from ${LARANODE_REPO}"
if [ -d "${PANEL_PATH}/.git" ]; then
    git -C "${PANEL_PATH}" pull --ff-only || warn "git pull failed — continuing with the code already on disk"
else
    warn "${PANEL_PATH} is not a git checkout — skipping pull"
fi

# ==============================================================================
# 2. Packages introduced since the last install
# ==============================================================================

for pkg in postgresql postgresql-client cron; do
    if dpkg -s "${pkg}" >/dev/null 2>&1; then
        log "  package present: ${pkg}"
    else
        log "  installing package: ${pkg}"
        apt-get update -qq
        apt-get install -y -qq "${pkg}"
    fi
done

# ==============================================================================
# 3. Apache modules (a2enmod is idempotent)
# ==============================================================================

log "enabling apache modules (proxy for FrankenPHP/Swoole)"
a2enmod proxy proxy_http >/dev/null
a2enmod proxy_fcgi rewrite setenvif headers ssl >/dev/null
a2enconf php8.4-fpm >/dev/null

# ==============================================================================
# 4. sudoers drop-ins — install the same set as the installer, drop the legacy ones
# ==============================================================================

log "installing sudoers drop-ins for www-data"
for drop in laranode-panel laranode-cron laranode-runtimes laranode-ufw; do
    SRC="${PANEL_PATH}/laranode-scripts/etc/sudoers.d/${drop}"
    if ! visudo -c -f "${SRC}" >/dev/null; then
        warn "sudoers file ${drop} failed syntax check — aborting"
        exit 1
    fi
    install -m 440 "${SRC}" "/etc/sudoers.d/${drop}"
done
# Legacy drop-ins from older installs (the wildcard rule and the postgres one-off)
rm -f /etc/sudoers.d/laranode-postgres
if [ -f /etc/sudoers.d/laranode ]; then
    warn "removing the legacy /etc/sudoers.d/laranode wildcard rule"
    rm -f /etc/sudoers.d/laranode
fi

# ==============================================================================
# 5. PostgreSQL stats-reader role
# ==============================================================================

log "ensuring PostgreSQL is running"
systemctl enable --now postgresql@16-main 2>/dev/null || systemctl enable --now postgresql 2>/dev/null || \
    warn "could not start PostgreSQL — Postgres features stay unavailable"

PGSQL_READER_PASS="$(env_value PGSQL_PASSWORD)"
if [ -z "${PGSQL_READER_PASS}" ]; then
    PGSQL_READER_PASS="$(openssl rand -base64 18)"
fi

if systemctl is-active --quiet postgresql 2>/dev/null || systemctl is-active --quiet postgresql@16-main 2>/dev/null; then
    log "provisioning the laranode_pg_reader role"
    PGSQL_PG_TAG=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-z' | head -c 8)
    sudo -u postgres psql -v ON_ERROR_STOP=1 --dbname=postgres <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'laranode_pg_reader') THEN
        CREATE ROLE laranode_pg_reader LOGIN;
    END IF;
END\$\$;
ALTER ROLE laranode_pg_reader PASSWORD \$${PGSQL_PG_TAG}\$${PGSQL_READER_PASS}\$${PGSQL_PG_TAG}\$;
GRANT CONNECT ON DATABASE postgres TO laranode_pg_reader;
GRANT pg_read_all_stats TO laranode_pg_reader;
SQL
    # pgsql_admin must authenticate as that role — never as 'postgres' with the reader's password.
    ensure_env PGSQL_PASSWORD "${PGSQL_READER_PASS}"
    if grep -q '^PGSQL_USERNAME=' "${PANEL_PATH}/.env"; then
        sed -i 's#^PGSQL_USERNAME=.*#PGSQL_USERNAME="laranode_pg_reader"#' "${PANEL_PATH}/.env"
    else
        ensure_env PGSQL_USERNAME "laranode_pg_reader"
    fi
else
    warn "PostgreSQL is not running — skipping role provisioning"
fi

# ==============================================================================
# 6. .env keys added since the last install
# ==============================================================================

log "back-filling new .env keys"
ensure_env MYSQL_ADMIN_HOST 127.0.0.1
ensure_env MYSQL_ADMIN_PORT 3306
ensure_env MYSQL_ADMIN_DB mysql
# The existing panel MySQL user already holds ALL PRIVILEGES, so reuse its credentials.
ensure_env MYSQL_ADMIN_USERNAME "$(env_value DB_USERNAME)"
ensure_env MYSQL_ADMIN_PASSWORD "$(env_value DB_PASSWORD)"
ensure_env PGSQL_HOST 127.0.0.1
ensure_env PGSQL_PORT 5432
ensure_env PGSQL_DB postgres

# ==============================================================================
# 7. systemd units (queue worker, reverb, scheduler timer)
# ==============================================================================

log "installing systemd units"
cp "${PANEL_PATH}/laranode-scripts/templates/laranode-queue-worker.service" /etc/systemd/system/laranode-queue-worker.service
cp "${PANEL_PATH}/laranode-scripts/templates/laranode-reverb.service" /etc/systemd/system/laranode-reverb.service
# The timer drives `artisan schedule:run` — without it scheduled backups,
# retention, analytics rollups and SSL-expiry notifications never run.
cp "${PANEL_PATH}/laranode-scripts/templates/laranode-scheduler.service" /etc/systemd/system/laranode-scheduler.service
cp "${PANEL_PATH}/laranode-scripts/templates/laranode-scheduler.timer" /etc/systemd/system/laranode-scheduler.timer

# ==============================================================================
# 8. Application: dependencies, migrations, assets
# ==============================================================================

cd "${PANEL_PATH}"
log "installing composer dependencies"
composer install --no-interaction --no-progress

# A stale config cache masks the new .env keys written above.
php artisan config:clear
php artisan migrate --force
php artisan storage:link || true
php artisan reverb:install --no-interaction || true

log "rebuilding frontend assets"
npm install
npm run build

# ==============================================================================
# 9. Permissions, services
# ==============================================================================

mkdir -p /home/laranode_ln/logs
chown -R laranode_ln:laranode_ln /home/laranode_ln
find /home/laranode_ln -type d -exec chmod 770 {} \;
# Files are deliberately NOT blanket-chmodded the way the installer does: the
# installer runs once and then builds, but this script must stay re-runnable, and
# `find -type f -exec chmod 660` strips the exec bit from node_modules/.bin and
# vendor/bin — the next run's `npm run build` would fail with "vite: Permission
# denied". Only the pieces the panel actually needs are set explicitly.
chmod 0755 "${PANEL_PATH}/laranode-scripts/bin"/*.sh
find "${PANEL_PATH}/storage" "${PANEL_PATH}/bootstrap" -type d -exec chmod 775 {} \;

systemctl daemon-reload
systemctl enable laranode-queue-worker.service laranode-reverb.service >/dev/null
systemctl restart laranode-queue-worker.service laranode-reverb.service
systemctl enable --now laranode-scheduler.timer
systemctl restart apache2
systemctl restart php8.4-fpm

log "done — services restarted, scheduler timer armed"
log "not performed (one-time install steps): MySQL root rotation, database seeding, APP_KEY generation"
