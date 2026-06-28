#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ---- Overridable config (env-var interface — set before sourcing or calling) ----
LARANODE_REPO="${LARANODE_REPO:-https://github.com/alexandre433/laranode.git}"

# ---- Resolved globals (set by preflight, read by subsequent phases) ----
DB_ENGINE=""    # mysql | pgsql
HTTP_PORT=""    # 80 | 8080 (or operator-chosen)
PANEL_PATH=/home/laranode_ln/panel

# ---- Cross-phase state (set by phase_database, read by phase_app + phase_summary) ----
LARANODE_RANDOM_PASS=""
ROOT_RANDOM_PASS=""

# ==============================================================================
# Helpers
# ==============================================================================

die()  { echo "FATAL: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
log()  { echo -e "\033[34m== $* ==\033[0m"; }

have_cmd()    { command -v "$1" >/dev/null 2>&1; }
port_in_use() { ss -tlnH "( sport = :$1 )" | grep -q .; }
svc_active()  { systemctl is-active --quiet "$1"; }

# version_ge HAVE WANT — returns 0 (true) when HAVE >= WANT (version sort)
version_ge() { printf '%s\n%s\n' "$2" "$1" | sort -V -C; }

# confirm MSG — returns 0 to proceed; auto-yes when LARANODE_UNATTENDED=1
confirm() {
  [ "${LARANODE_UNATTENDED:-0}" = "1" ] && return 0
  local _a=""
  read -rp "$1 [y/N] " _a
  [[ "$_a" =~ ^[Yy]$ ]]
}

# choose VAR_NAME DEFAULT PROMPT — echoes resolved value: env var > prompt > default
# When LARANODE_UNATTENDED=1 or stdin is not a TTY, skips the prompt and uses DEFAULT.
choose() {
  local _cur="${!1:-}"
  if [ -n "$_cur" ]; then echo "$_cur"; return; fi
  if [ "${LARANODE_UNATTENDED:-0}" = "1" ] || [ ! -t 0 ]; then echo "$2"; return; fi
  local _a=""
  read -rp "$3 [$2]: " _a
  echo "${_a:-$2}"
}

# env_set KEY VALUE FILE — add-or-replace a single .env assignment safely
env_set() {
  local k="$1" v="$2" f="$3"
  if grep -qE "^${k}=" "$f"; then
    sed -i "s#^${k}=.*#${k}=\"${v}\"#" "$f"
  else
    printf '%s="%s"\n' "$k" "$v" >> "$f"
  fi
}

# persist_secret LINE — append to /root/.laranode-credentials (0600)
persist_secret() {
  printf '%s\n' "$*" >> /root/.laranode-credentials
  chmod 600 /root/.laranode-credentials
}

# ------------------------------------------------------------------------------
# Phase 0 — Preflight: detect, resolve choices, print plan, confirm.
# NO mutations — apt/systemctl/file writes happen only in later phases.
# ------------------------------------------------------------------------------
preflight() {
  log "Preflight: surveying environment"

  # ---- Web server on :80 -------------------------------------------------------
  local port80_free=1
  local port80_holder="none"
  if port_in_use 80; then
    port80_free=0
    # Best-effort identification; cosmetic only — never fails the install.
    local _ss_out
    _ss_out=$(ss -tlnp '( sport = :80 )' 2>/dev/null || true)
    if   echo "$_ss_out" | grep -qi 'nginx';  then port80_holder="nginx"
    elif echo "$_ss_out" | grep -qi 'apache'; then port80_holder="apache2"
    else                                           port80_holder="unknown"
    fi
    warn ":80 is held by ${port80_holder} — panel will be placed on a different port"
  fi

  # ---- MySQL -------------------------------------------------------------------
  local mysql_note="absent"
  if have_cmd mysql; then
    if mysql -u root -e 'SELECT 1' >/dev/null 2>&1; then
      mysql_note="present (root via auth_socket)"
    else
      mysql_note="present (root password required)"
    fi
  fi

  # ---- Postgres clusters -------------------------------------------------------
  local pg_note="absent"
  if have_cmd pg_lsclusters; then
    local _pg_count
    _pg_count=$(pg_lsclusters --no-header 2>/dev/null | grep -c . || true)
    if [ "${_pg_count:-0}" -gt 0 ]; then
      pg_note="${_pg_count} cluster(s) found"
    fi
  fi

  # ---- PHP ---------------------------------------------------------------------
  local php_note="absent"
  if have_cmd php; then
    local _php_ver
    _php_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
    php_note="system php ${_php_ver} (unchanged)"
  fi

  # ---- Node --------------------------------------------------------------------
  local node_note="absent"
  if have_cmd node; then
    local _node_ver
    _node_ver=$(node --version 2>/dev/null | sed 's/^v//' || true)
    node_note="node v${_node_ver} (reused if major >= 20)"
  fi

  # ---- UFW ---------------------------------------------------------------------
  local ufw_note="inactive"
  if have_cmd ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw_note="active"
  fi

  # ---- Resolve DB_ENGINE -------------------------------------------------------
  DB_ENGINE=$(choose LARANODE_DB_ENGINE mysql "DB engine (mysql|pgsql)")
  case "$DB_ENGINE" in
    mysql|pgsql) ;;
    *) die "LARANODE_DB_ENGINE must be 'mysql' or 'pgsql', got: ${DB_ENGINE}" ;;
  esac

  # ---- Resolve HTTP_PORT -------------------------------------------------------
  if [ "$port80_free" = 1 ]; then
    HTTP_PORT=80
  else
    HTTP_PORT=$(choose LARANODE_HTTP_PORT 8080 "Panel port (:80 busy — suggest 8080)")
    HTTP_PORT="${HTTP_PORT:-8080}"
  fi

  # ---- Build and print the plan ------------------------------------------------
  local _port_desc
  if [ "$port80_free" = 1 ]; then
    _port_desc="port=80"
  else
    _port_desc="port=${HTTP_PORT} (:80 held by ${port80_holder}, left untouched)"
  fi

  local _plan
  _plan="panel DB=${DB_ENGINE} · ${_port_desc} · web=apache"
  _plan+=" · php8.4 added (${php_note})"
  _plan+=" · ${node_note}"
  _plan+=" · mysql: ${mysql_note}"
  _plan+=" · pg: ${pg_note}"
  _plan+=" · ufw: ${ufw_note}"

  log "PLAN: ${_plan}"

  # ---- Confirm -----------------------------------------------------------------
  confirm "Proceed with install?" || die "Aborted by operator."
}

# ==============================================================================
# Phase 1 — Base system packages
# ==============================================================================

phase_packages() {
  log "Installing base tools"
  apt-get update -q
  apt-get install -y software-properties-common git curl ca-certificates sudo openssl

  log "Installing sysstat"
  apt-get install -y sysstat
  systemctl enable sysstat
}

# ==============================================================================
# Phase 2 — Fetch the panel (user + clone)
# ==============================================================================

phase_fetch_panel() {
  log "Creating laranode_ln system user"
  useradd -m -s /bin/bash laranode_ln 2>/dev/null || true
  usermod -aG laranode_ln www-data

  log "Cloning panel from ${LARANODE_REPO}"
  if [ ! -d "${PANEL_PATH}/laranode-scripts" ]; then
    git clone "${LARANODE_REPO}" "${PANEL_PATH}"
  else
    echo "Repo already present at ${PANEL_PATH}, skipping clone."
  fi
}

# ==============================================================================
# Phase 3 — Database
# ==============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# _mysql_branch — MySQL provisioning for phase_database
#
# Auth strategy (in order):
#   1. Try unix socket: mysql -u root -e 'SELECT 1'
#   2. If that fails, require LARANODE_MYSQL_ROOT_PASSWORD (env/prompt/die).
#
# NEVER alters root credentials.  Only the 'laranode' service account is
# touched.  All SQL ops are idempotent so re-runs converge cleanly.
# DB_* written to .env only after all SQL ops succeed.
# ─────────────────────────────────────────────────────────────────────────────
_mysql_branch() {
  log "Database — MySQL: installing mysql-server"
  apt-get install -y mysql-server
  # enable+start is idempotent whether mysql was just installed or pre-existed.
  systemctl enable --now mysql

  # ── Authenticate as root ────────────────────────────────────────────────
  local -a root_args=(-u root)

  if ! mysql -u root -e 'SELECT 1' >/dev/null 2>&1; then
    # Socket auth is unavailable (root has a password set).
    local root_pw
    root_pw=$(choose LARANODE_MYSQL_ROOT_PASSWORD "" \
      "Enter the existing MySQL root password")
    [ -n "${root_pw}" ] \
      || die "MySQL root socket auth failed and LARANODE_MYSQL_ROOT_PASSWORD is not set — cannot provision the panel database"
    root_args=(-u root -p"${root_pw}")
    mysql "${root_args[@]}" -e 'SELECT 1' >/dev/null 2>&1 \
      || die "MySQL root auth failed with provided password — check LARANODE_MYSQL_ROOT_PASSWORD"
    log "MySQL root auth: caching_sha2_password / native_password (socket unavailable)"
  else
    log "MySQL root auth: unix socket (auth_socket)"
  fi

  # ── Generate a fresh panel service-account password ─────────────────────
  # Always regenerate on each run so .env and the DB stay in sync.
  local db_pass
  db_pass=$(openssl rand -base64 18)

  # ── Idempotent user + database + grants ─────────────────────────────────
  # CREATE USER IF NOT EXISTS creates on first run only.
  # ALTER USER (no IF NOT EXISTS) always syncs the password → .env match.
  # CREATE DATABASE IF NOT EXISTS is a no-op on re-run.
  # GRANT is idempotent in MySQL 8+.
  # NEVER ALTER USER root here or anywhere else in the installer.
  mysql "${root_args[@]}" -e "
    CREATE USER IF NOT EXISTS 'laranode'@'localhost' IDENTIFIED BY '${db_pass}';
    ALTER  USER              'laranode'@'localhost' IDENTIFIED BY '${db_pass}';
    CREATE DATABASE IF NOT EXISTS laranode
           CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    GRANT ALL PRIVILEGES ON *.* TO 'laranode'@'localhost' WITH GRANT OPTION;
    FLUSH PRIVILEGES;
  " || die "MySQL: failed to provision laranode user/database — see output above"

  # ── Write .env (only after all DB ops succeeded) ─────────────────────────
  # phase_database runs before phase_app, so .env may not exist yet. Seed it
  # from .env.example first (full template) so env_set updates existing keys
  # instead of leaving a stub .env that phase_app would then preserve as-is.
  [ -f "${PANEL_PATH}/.env" ] || cp "${PANEL_PATH}/.env.example" "${PANEL_PATH}/.env"
  env_set DB_CONNECTION mysql        "${PANEL_PATH}/.env"
  env_set DB_HOST       127.0.0.1    "${PANEL_PATH}/.env"
  env_set DB_PORT       3306         "${PANEL_PATH}/.env"
  env_set DB_DATABASE   laranode     "${PANEL_PATH}/.env"
  env_set DB_USERNAME   laranode     "${PANEL_PATH}/.env"
  env_set DB_PASSWORD   "${db_pass}" "${PANEL_PATH}/.env"

  persist_secret "MySQL laranode user password: ${db_pass}"
  log "Database — MySQL: done"
}

# ─────────────────────────────────────────────────────────────────────────────
# phase_database — dispatch to the engine-specific branch
# DB_ENGINE is resolved (and validated to mysql|pgsql) by preflight.
# ─────────────────────────────────────────────────────────────────────────────
phase_database() {
  case "${DB_ENGINE}" in
    mysql) _mysql_branch ;;
    pgsql) _pgsql_branch ;;   # Task 6
    *)     die "Unknown DB_ENGINE '${DB_ENGINE}' — expected mysql or pgsql" ;;
  esac
}

# ==============================================================================
# Phase 4 — Web server (Apache + modules + certbot)
# ==============================================================================

phase_webserver() {
  log "Installing Apache Web Server"
  apt-get install -y apache2
  systemctl enable apache2
  systemctl start apache2

  log "Enabling required Apache modules"
  a2enmod proxy_fcgi
  a2enmod rewrite
  a2enmod setenvif
  a2enmod headers
  a2enmod ssl
  a2enmod proxy proxy_http

  log "Installing Certbot"
  apt-get install -y certbot python3-certbot-apache
}

# ==============================================================================
# Phase 5 — PHP 8.4, Node.js, Composer, PostgreSQL client
# ==============================================================================

phase_php_node() {
  log "Adding ppa:ondrej/php"
  add-apt-repository -y ppa:ondrej/php
  apt-get update -q

  log "Installing PHP 8.4 and required extensions"
  apt-get install -y php8.4 php8.4-fpm php8.4-cli php8.4-common php8.4-curl php8.4-mbstring \
    php8.4-xml php8.4-bcmath php8.4-zip php8.4-mysql php8.4-sqlite3 php8.4-pgsql \
    php8.4-gd php8.4-imagick php8.4-intl php8.4-readline php8.4-tokenizer php8.4-fileinfo \
    php8.4-soap php8.4-opcache unzip curl

  log "Enabling PHP-FPM"
  systemctl enable php8.4-fpm
  systemctl start php8.4-fpm

  # php8.4-fpm package provides /etc/apache2/conf-available/php8.4-fpm.conf;
  # a2enconf must run after the package is installed.
  a2enconf php8.4-fpm

  log "Installing PostgreSQL server and client"
  apt-get install -y postgresql postgresql-client

  log "Installing Composer"
  curl -sS https://getcomposer.org/installer \
    | php -- --install-dir=/usr/local/bin --filename=composer

  log "Installing Node.js 22"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
}

# ==============================================================================
# Phase 6 — Application provisioning
# ==============================================================================

phase_app() {
  log "Installing PHP dependencies"
  cd "${PANEL_PATH}"
  composer install --no-interaction

  [ -f .env ] || cp .env.example .env
  # DB_* (incl. DB_PASSWORD) are owned by phase_database/_mysql_branch via env_set;
  # do not rewrite DB_PASSWORD here (the old LARANODE_RANDOM_PASS global is gone).
  sed -i "s#APP_URL=.*#APP_URL=\"http://$(curl -s icanhazip.com)\"#" .env
  php artisan key:generate --force

  log "Installing sudoers drop-ins for www-data"
  for drop in laranode-panel laranode-cron laranode-runtimes laranode-ufw; do
    SRC="${PANEL_PATH}/laranode-scripts/etc/sudoers.d/${drop}"
    if ! visudo -c -f "${SRC}"; then
      echo "ERROR: sudoers file ${drop} failed syntax check — aborting" >&2
      exit 1
    fi
    install -m 440 "${SRC}" "/etc/sudoers.d/${drop}"
  done
  rm -f /etc/sudoers.d/laranode-postgres

  log "Provisioning PostgreSQL stats-reader role (laranode_pg_reader)"
  # Enable the versioned PG unit for Ubuntu 24.04; fall back to the generic unit.
  systemctl enable --now postgresql@16-main 2>/dev/null \
    || systemctl enable --now postgresql \
    || true

  PGSQL_READER_PASS=$(openssl rand -base64 18)
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

  sed -i "s#^PGSQL_PASSWORD=.*#PGSQL_PASSWORD=\"${PGSQL_READER_PASS}\"#" "${PANEL_PATH}/.env" \
    || echo "PGSQL_PASSWORD=\"${PGSQL_READER_PASS}\"" >> "${PANEL_PATH}/.env"

  log "Migrating database, seeding, and building assets"
  php artisan migrate --force
  php artisan db:seed --force
  php artisan storage:link
  php artisan reverb:install --no-interaction
  php artisan laranode:detect-gpu

  sed -i "s#VITE_REVERB_HOST=.*#VITE_REVERB_HOST=$(curl -s icanhazip.com)#" "${PANEL_PATH}/.env"
  sed -i "s#REVERB_HOST=.*#REVERB_HOST=$(curl -s icanhazip.com)#" "${PANEL_PATH}/.env"

  # NOTE: writes to 000-default.conf — known bug (CRITICAL, ticket #hardening).
  # Preserved verbatim in this task; Task 7 replaces with laranode.conf.
  cp "${PANEL_PATH}/laranode-scripts/templates/apache2-default.template" \
    /etc/apache2/sites-available/000-default.conf

  log "Building frontend assets"
  npm install
  npm run build
}

# ==============================================================================
# Phase 7 — Services, firewall, permissions
# ==============================================================================

phase_services() {
  log "Installing systemd service units"
  cp "${PANEL_PATH}/laranode-scripts/templates/laranode-queue-worker.service" \
    /etc/systemd/system/laranode-queue-worker.service
  cp "${PANEL_PATH}/laranode-scripts/templates/laranode-reverb.service" \
    /etc/systemd/system/laranode-reverb.service

  log "Adding UFW rules for SSH / HTTP / HTTPS / Reverb"
  # Gate on ufw presence so set -e does not abort on hosts without it, WITHOUT
  # fail-open suppression: when ufw exists real failures still surface (set -e);
  # when absent, warn loudly rather than silently leaving the host unfirewalled.
  # Task 7 relocates these into phase_webserver and makes the panel rule
  # HTTP_PORT-aware.
  if have_cmd ufw; then
    ufw allow 22
    ufw allow 80
    ufw allow 443
    ufw allow 8080
  else
    warn "ufw not installed — firewall rules NOT configured. Configure the host firewall manually before exposing the panel."
  fi

  log "Setting file permissions"
  mkdir -p /home/laranode_ln/logs
  chown -R laranode_ln:laranode_ln /home/laranode_ln
  find /home/laranode_ln -type d -exec chmod 770 {} \;
  find /home/laranode_ln -type f -exec chmod 660 {} \;
  find /home/laranode_ln/panel/laranode-scripts/bin -type f -exec chmod 100 {} \;
  find /home/laranode_ln/panel/storage \
       /home/laranode_ln/panel/bootstrap \
       -type d -exec chmod 775 {} \;

  log "Enabling and starting services"
  systemctl daemon-reload
  systemctl enable laranode-queue-worker.service
  systemctl enable laranode-reverb.service
  systemctl start laranode-queue-worker.service
  systemctl start laranode-reverb.service
  systemctl restart apache2
  systemctl restart php8.4-fpm
}

# ==============================================================================
# Phase 8 — Summary
# ==============================================================================

phase_summary() {
  echo "========================================================================"
  echo "========================================================================"
  echo -e "\033[32m --- NOTES ---\033[0m"
  echo "MySQL Root Password:      ${ROOT_RANDOM_PASS}"
  echo "Laranode MySQL Username:  laranode"
  echo "Laranode MySQL Password:  ${LARANODE_RANDOM_PASS}"
  echo -e "\033[32m --- IMPORTANT ---\033[0m"
  echo "Final Step: create an admin account by running:"
  echo -e "\033[33m cd /home/laranode_ln/panel && php artisan laranode:create-admin \033[0m"
  echo "========================================================================"
  echo "========================================================================"
}

# ==============================================================================
# Entrypoint
# ==============================================================================

main() {
  preflight
  phase_packages
  phase_fetch_panel
  phase_database
  phase_webserver
  phase_php_node
  phase_app
  phase_services
  phase_summary
}

# Source-guard: only run main when executed directly, not when sourced by unit tests.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
