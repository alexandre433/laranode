#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ---- Overridable config (env-var interface — set before sourcing or calling) ----
LARANODE_REPO="${LARANODE_REPO:-https://github.com/alexandre433/laranode.git}"

# ---- Resolved globals (set by preflight, read by subsequent phases) ----
DB_ENGINE=""    # mysql | pgsql
HTTP_PORT=""    # 80 | fallback port (or operator-chosen)
REVERB_PORT=""  # 8080 normally; 8081 when 8080 is taken/reserved
BIND_ADDR=""    # "" = all interfaces; otherwise the address Apache/Reverb listen on
OS_ID=""        # ubuntu | debian
OS_VERSION=""   # 24.04 | 13
IS_PROXMOX=0    # 1 on a Proxmox VE host (pve-firewall owns the firewall)
IS_CLOUDPANEL=0 # 1 when CloudPanel is installed (its nginx/php/varnish stay untouched)
PG_PREEXISTING=0 # PostgreSQL clusters present BEFORE this installer ran
PANEL_PATH=/home/laranode_ln/panel

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
# Host detection helpers (pure reads; every marker is overridable for tests)
# ------------------------------------------------------------------------------

# pkg_installed PKG — true when dpkg reports PKG fully installed
pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

# detect_os — sets OS_ID / OS_VERSION from os-release; refuses anything but
# Ubuntu 24.04 and Debian 13. LARANODE_OS_RELEASE_FILE overrides the path (tests).
detect_os() {
  local f="${LARANODE_OS_RELEASE_FILE:-/etc/os-release}"
  [ -r "$f" ] || die "Cannot read ${f} — unsupported OS (supported: Ubuntu 24.04, Debian 13)"
  OS_ID=$(. "$f" && echo "${ID:-unknown}")
  OS_VERSION=$(. "$f" && echo "${VERSION_ID:-unknown}")
  case "${OS_ID}:${OS_VERSION}" in
    ubuntu:24.04|debian:13) ;;
    *) die "Unsupported OS: ${OS_ID} ${OS_VERSION}. Supported: Ubuntu 24.04, Debian 13 (trixie)." ;;
  esac
}

# detect_proxmox — Proxmox VE host: pve-firewall owns the firewall, ports 8006/3128
# etc. belong to Proxmox. LARANODE_PVE_DIR overrides /etc/pve (tests).
detect_proxmox() {
  if have_cmd pveversion || [ -d "${LARANODE_PVE_DIR:-/etc/pve}" ]; then
    IS_PROXMOX=1
  else
    IS_PROXMOX=0
  fi
}

# detect_cloudpanel — CloudPanel owns nginx, its own php-fpm builds, varnish and
# (usually) Percona. LARANODE_CLP_DIR overrides /home/clp (tests).
detect_cloudpanel() {
  if pkg_installed cloudpanel || have_cmd clpctl || [ -d "${LARANODE_CLP_DIR:-/home/clp}" ]; then
    IS_CLOUDPANEL=1
  else
    IS_CLOUDPANEL=0
  fi
}

# mysql_server_pkg — echo the name of an installed MySQL-family server package
# (Percona, MySQL, MariaDB); empty when none. Never install mysql-server over these.
mysql_server_pkg() {
  local p
  for p in percona-server-server percona-xtradb-cluster-server mysql-server \
           mysql-community-server mysql-server-core-8.0 mariadb-server; do
    if pkg_installed "$p"; then echo "$p"; return 0; fi
  done
  return 0
}

# pg_cluster_count — number of PostgreSQL clusters currently defined on the host
pg_cluster_count() {
  have_cmd pg_lsclusters || { echo 0; return 0; }
  pg_lsclusters --no-header 2>/dev/null | grep -c . || true
}

# apt_install PKG... — guarded apt-get install. Simulates first and refuses when the
# transaction would REMOVE any package, or (on Proxmox/CloudPanel hosts) upgrade a
# package that belongs to the host's own stack. Stops apt -y from silently
# replacing Percona, CloudPanel's nginx/php, Proxmox packages, etc.
_PROTECTED_PKG_RE='^(proxmox-|pve-|libpve-|qemu-server|lxc-pve|percona-|mysql-|mariadb-|postgresql|libpq|cloudpanel|nginx|libnginx|php[0-9.]*-|varnish|redis|docker|containerd|tailscale|ufw)'
apt_install() {
  local sim
  sim=$(apt-get install -s -y "$@" 2>&1) \
    || die "apt-get simulation failed for: $* — ${sim}"
  local removals
  removals=$(printf '%s\n' "$sim" | grep '^Remv ' || true)
  [ -z "$removals" ] \
    || die "Refusing to install: $* — apt would REMOVE packages:"$'\n'"${removals}"
  if [ "$IS_PROXMOX" = 1 ] || [ "$IS_CLOUDPANEL" = 1 ]; then
    local upgrades
    upgrades=$(printf '%s\n' "$sim" | grep -E '^Inst [^ ]+ \[' \
      | awk '{print $2}' | grep -E "$_PROTECTED_PKG_RE" || true)
    [ -z "$upgrades" ] \
      || die "Refusing to install: $* — apt would UPGRADE host-managed packages:"$'\n'"${upgrades}"
  fi
  apt-get install -y "$@"
}

# ------------------------------------------------------------------------------
# Phase 0 — Preflight: detect, resolve choices, print plan, confirm.
# NO mutations — apt/systemctl/file writes happen only in later phases.
# ------------------------------------------------------------------------------
preflight() {
  log "Preflight: surveying environment"

  # ---- Host identity -----------------------------------------------------------
  detect_os
  detect_proxmox
  detect_cloudpanel
  PG_PREEXISTING=$(pg_cluster_count)
  capture_preexisting

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
  local mysql_pkg
  mysql_pkg=$(mysql_server_pkg)
  [ -z "$mysql_pkg" ] || mysql_note="${mysql_pkg} installed (reused, never replaced)"
  if have_cmd mysql; then
    if mysql -u root -e 'SELECT 1' >/dev/null 2>&1; then
      mysql_note="present (root via auth_socket)${mysql_pkg:+ [$mysql_pkg]}"
    else
      mysql_note="present (root password required)${mysql_pkg:+ [$mysql_pkg]}"
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
  if [ "$IS_PROXMOX" = 1 ]; then
    ufw_note="skipped (Proxmox host: pve-firewall untouched)"
  fi

  # ---- Resolve DB_ENGINE -------------------------------------------------------
  # Debian 13 has no mysql-server package (MariaDB only): default pgsql there.
  local _default_engine=mysql
  [ "$OS_ID" = debian ] && _default_engine=pgsql
  DB_ENGINE=$(choose LARANODE_DB_ENGINE "$_default_engine" "DB engine (mysql|pgsql)")
  case "$DB_ENGINE" in
    mysql|pgsql) ;;
    *) die "LARANODE_DB_ENGINE must be 'mysql' or 'pgsql', got: ${DB_ENGINE}" ;;
  esac
  if [ "$DB_ENGINE" = mysql ] && [ "$OS_ID" = debian ] && [ -z "$mysql_pkg" ]; then
    die "LARANODE_DB_ENGINE=mysql is not supported on Debian 13 (no mysql-server package; MariaDB is not validated). Use LARANODE_DB_ENGINE=pgsql."
  fi

  # ---- Resolve BIND_ADDR -------------------------------------------------------
  # all (every interface) | local (127.0.0.1, reach the panel through an SSH
  # tunnel) | an IPv4 address. Proxmox and CloudPanel hosts default to local.
  local _default_bind=all
  { [ "$IS_PROXMOX" = 1 ] || [ "$IS_CLOUDPANEL" = 1 ]; } && _default_bind=local
  local _bind
  _bind=$(choose LARANODE_BIND "$_default_bind" "Bind panel to (all|local|<ipv4>)")
  case "$_bind" in
    all)   BIND_ADDR="" ;;
    local) BIND_ADDR="127.0.0.1" ;;
    *)     [[ "$_bind" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
             || die "LARANODE_BIND must be all, local or an IPv4 address, got: ${_bind}"
           BIND_ADDR="$_bind" ;;
  esac

  # ---- Resolve HTTP_PORT -------------------------------------------------------
  # Fallback port when :80 is busy. CloudPanel's Varnish backend is 127.0.0.1:8080,
  # so a CloudPanel host never gets the panel on 8080.
  local _fallback_port=8080
  [ "$IS_CLOUDPANEL" = 1 ] && _fallback_port=8090
  if [ "$port80_free" = 1 ]; then
    HTTP_PORT=$(choose LARANODE_HTTP_PORT 80 "Panel port")
  else
    HTTP_PORT=$(choose LARANODE_HTTP_PORT "$_fallback_port" "Panel port (:80 busy — suggest ${_fallback_port})")
    HTTP_PORT="${HTTP_PORT:-$_fallback_port}"
  fi
  { [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] && [ "$HTTP_PORT" -ge 1 ] && [ "$HTTP_PORT" -le 65535 ]; } \
    || die "LARANODE_HTTP_PORT must be a port number, got: ${HTTP_PORT}"
  if [ "$IS_PROXMOX" = 1 ]; then
    case "$HTTP_PORT" in
      22|85|111|443|3128|8006)
        die "Port ${HTTP_PORT} belongs to Proxmox/SSH/Tailscale on this host — choose another LARANODE_HTTP_PORT." ;;
    esac
  fi
  if [ "$port80_free" = 0 ] && [ "$HTTP_PORT" = 80 ]; then
    die ":80 is held by ${port80_holder} — pick another LARANODE_HTTP_PORT."
  fi

  # ---- Resolve REVERB_PORT -----------------------------------------------------
  # 8080 unless something owns it (the panel itself, CloudPanel's Varnish backend,
  # or any other listener); then 8081.
  REVERB_PORT=8080
  if [ "$HTTP_PORT" = 8080 ] || [ "$IS_CLOUDPANEL" = 1 ] || port_in_use 8080; then
    REVERB_PORT=8081
  fi
  [ "$HTTP_PORT" != "$REVERB_PORT" ] || REVERB_PORT=8082

  # ---- Build and print the plan ------------------------------------------------
  local _port_desc
  if [ "$port80_free" = 1 ]; then
    _port_desc="port=${HTTP_PORT}"
  else
    _port_desc="port=${HTTP_PORT} (:80 held by ${port80_holder}, left untouched)"
  fi

  local _host_desc="${OS_ID} ${OS_VERSION}"
  [ "$IS_PROXMOX" = 1 ]    && _host_desc+=" · PROXMOX host (pve-firewall/8006/3128 untouched)"
  [ "$IS_CLOUDPANEL" = 1 ] && _host_desc+=" · CLOUDPANEL host (nginx/php-fpm/varnish untouched)"

  local _plan
  _plan="${_host_desc} · panel DB=${DB_ENGINE} · ${_port_desc} · bind=${BIND_ADDR:-all} · reverb=${REVERB_PORT} · web=apache"
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
  apt_install git curl ca-certificates sudo openssl iproute2 gnupg cron
  # add-apt-repository (ppa:ondrej/php) exists only on Ubuntu, and only the PPA
  # path needs it. Debian 13 ships php8.4 itself.
  if [ "$OS_ID" = ubuntu ] && [ "$IS_CLOUDPANEL" = 0 ]; then
    apt_install software-properties-common
  fi

  log "Installing sysstat"
  apt_install sysstat
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
  # Never install mysql-server over an existing MySQL-family server (Percona,
  # MariaDB, MySQL): apt would remove it. Reuse what is there.
  local existing_pkg
  existing_pkg=$(mysql_server_pkg)
  if [ -n "$existing_pkg" ]; then
    log "Database — MySQL: reusing installed ${existing_pkg} (no package install)"
    warn "Panel will create the 'laranode' account with ALL PRIVILEGES on this existing server."
  else
    log "Database — MySQL: installing mysql-server"
    apt_install mysql-server
    PANEL_DB_MANAGED=1
  fi
  # enable+start is idempotent whether mysql was just installed or pre-existed.
  if systemctl cat mysql >/dev/null 2>&1; then
    systemctl enable --now mysql
    PANEL_DB_UNIT=mysql.service
  elif systemctl cat mariadb >/dev/null 2>&1; then
    systemctl enable --now mariadb
    PANEL_DB_UNIT=mariadb.service
  else
    die "No mysql/mariadb systemd unit found after install"
  fi

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
# _pgsql_branch — PostgreSQL provisioning for phase_database
#
# Cluster discovery: uses pg_lsclusters (single auto; multiple require
# LARANODE_PG_PORT). Enables the versioned postgresql@<ver>-<name> unit.
# Idempotent laranode role+DB; scoped pg_hba.conf scram-sha-256 entry.
# Stats-reader laranode_pg_reader bound to resolved port.
# Writes DB_* + PGSQL_* to .env via env_set.
# ─────────────────────────────────────────────────────────────────────────────
_pgsql_branch() {
  log "Database — PostgreSQL"

  # ── packages ─────────────────────────────────────────────────────────────
  # Install only postgresql + postgresql-client; postgresql-common (which
  # provides pg_lsclusters/pg_ctlcluster) is pulled in as a dependency.
  if [ "${PG_PREEXISTING:-0}" -gt 0 ]; then
    # Clusters already exist (production data may live there). Never install the
    # `postgresql` meta package — it can pull in a NEWER major and a second
    # cluster. Use the existing cluster, client tools only.
    log "PostgreSQL: ${PG_PREEXISTING} pre-existing cluster(s) — server package not touched"
    apt_install postgresql-client
  else
    # Fresh host: optionally place the data directory on another disk, set
    # BEFORE the first cluster is created (%v = major, %c = cluster name).
    if [ -n "${LARANODE_PG_DATADIR:-}" ]; then
      apt_install postgresql-common
      local pgcc_conf="${LARANODE_PG_CREATECLUSTER_CONF:-/etc/postgresql-common/createcluster.conf}"
      mkdir -p "${LARANODE_PG_DATADIR}"
      sed -i -E "/^[#[:space:]]*data_directory[[:space:]]*=/d" "$pgcc_conf"
      printf "data_directory = '%s/%%v/%%c'\n" "${LARANODE_PG_DATADIR%/}" \
        >> "$pgcc_conf"
      log "PostgreSQL data directory base: ${LARANODE_PG_DATADIR%/}/<ver>/<cluster>"
    fi
    apt_install postgresql postgresql-client
    PANEL_DB_MANAGED=1
  fi

  # ── cluster discovery ─────────────────────────────────────────────────────
  # We enumerate via pg_lsclusters so the logic works whatever the version
  # (16/main on Ubuntu 24.04, 17/main on Debian 13) or cluster name.
  local clusters cluster_count
  clusters=$(pg_lsclusters --no-header 2>/dev/null | grep -v '^[[:space:]]*$' || true)
  # grep -c exits 1 on zero matches; || true keeps set -e happy
  cluster_count=$(echo "$clusters" | grep -c . || true)

  # Port the panel already uses from a previous run of this installer (idempotent
  # re-run): lets a second run keep working with its own cluster.
  local prev_port=""
  if [ -f "${PANEL_PATH}/.env" ] && grep -q '^DB_CONNECTION="\?pgsql' "${PANEL_PATH}/.env"; then
    prev_port=$(grep -E '^DB_PORT=' "${PANEL_PATH}/.env" | cut -d= -f2- | tr -d "\"' " || true)
  fi

  local PG_VER PG_CLUSTER_NAME PG_PORT
  if [ "$cluster_count" -eq 0 ]; then
    die "PostgreSQL installed but no cluster found — run pg_createcluster and re-run"
  elif [ "${PG_PREEXISTING:-0}" -gt 0 ] && [ -z "${LARANODE_PG_PORT:-}" ] && [ -z "$prev_port" ]; then
    # Existing (possibly production) cluster: never pick one implicitly.
    die "PostgreSQL cluster(s) already exist on this host. Set LARANODE_PG_PORT to the cluster the panel may use:"$'\n'"$(pg_lsclusters --no-header)"
  elif [ -z "${LARANODE_PG_PORT:-}" ] && [ -n "$prev_port" ]; then
    PG_PORT="$prev_port"
    local matched_prev
    matched_prev=$(echo "$clusters" | awk -v p="$PG_PORT" '$3 == p {print; exit}')
    [ -n "$matched_prev" ] \
      || die "Panel .env points at PostgreSQL port ${PG_PORT} but no cluster listens there — set LARANODE_PG_PORT"
    PG_VER=$(echo "$matched_prev"          | awk '{print $1}')
    PG_CLUSTER_NAME=$(echo "$matched_prev" | awk '{print $2}')
  elif [ "$cluster_count" -eq 1 ] && [ -z "${LARANODE_PG_PORT:-}" ]; then
    PG_VER=$(echo "$clusters"          | awk '{print $1}')
    PG_CLUSTER_NAME=$(echo "$clusters" | awk '{print $2}')
    PG_PORT=$(echo "$clusters"         | awk '{print $3}')
  else
    # Multiple clusters: require LARANODE_PG_PORT to disambiguate
    [ -n "${LARANODE_PG_PORT:-}" ] \
      || die "Multiple PostgreSQL clusters found. Set LARANODE_PG_PORT to disambiguate:"$'\n'"$(pg_lsclusters --no-header)"
    PG_PORT="$LARANODE_PG_PORT"
    local matched
    matched=$(echo "$clusters" | awk -v p="$PG_PORT" '$3 == p {print; exit}')
    [ -n "$matched" ] \
      || die "No PostgreSQL cluster found on port $PG_PORT — verify with pg_lsclusters"
    PG_VER=$(echo "$matched"          | awk '{print $1}')
    PG_CLUSTER_NAME=$(echo "$matched" | awk '{print $2}')
  fi

  log "PostgreSQL: ver=$PG_VER cluster=$PG_CLUSTER_NAME port=$PG_PORT"

  # ── enable + start the versioned unit ────────────────────────────────────
  systemctl enable --now "postgresql@${PG_VER}-${PG_CLUSTER_NAME}"
  PANEL_DB_UNIT="postgresql@${PG_VER}-${PG_CLUSTER_NAME}.service"

  # ── generate panel DB password ─────────────────────────────────────────
  local DB_PASS DB_PASS_TAG
  DB_PASS=$(openssl rand -base64 18)
  # Dollar-quote tag: random lowercase alphanum so it never collides with the
  # base64 password (which cannot contain lowercase alpha runs of 8 chars
  # identically — but we tag anyway for correctness).
  DB_PASS_TAG="q$(head -c 16 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 8)"  # must start with a letter: $4abc$ is not a valid dollar-quote tag

  # ── idempotent role (laranode LOGIN) ─────────────────────────────────────
  # Dollar-quote the password to survive special chars from openssl rand.
  # \$\$ in an unquoted heredoc produces $$ in the SQL (dollar-quote delimiter).
  sudo -u postgres psql -p "$PG_PORT" -v ON_ERROR_STOP=1 --dbname=postgres <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'laranode') THEN
        CREATE ROLE laranode LOGIN;
    END IF;
END\$\$;
ALTER ROLE laranode PASSWORD \$${DB_PASS_TAG}\$${DB_PASS}\$${DB_PASS_TAG}\$;
SQL

  # ── idempotent database (laranode OWNER laranode) ─────────────────────────
  # CREATE DATABASE cannot run inside a transaction block (DO$$), so we run it
  # as a standalone statement guarded by || true, then assert existence.
  sudo -u postgres psql -p "$PG_PORT" \
    -c "CREATE DATABASE laranode OWNER laranode;" 2>/dev/null || true
  sudo -u postgres psql -p "$PG_PORT" -At \
    -c "SELECT 1 FROM pg_database WHERE datname='laranode';" \
    | grep -q 1 \
    || die "PostgreSQL database 'laranode' was not created — check cluster logs"
  sudo -u postgres psql -p "$PG_PORT" \
    -c "GRANT ALL PRIVILEGES ON DATABASE laranode TO laranode;" >/dev/null

  # ── pg_hba.conf — scram-sha-256 entry for laranode on 127.0.0.1/32 ───────
  # Resolve the cluster's actual hba_file path (varies by ver/cluster name).
  local HBA_CONF
  HBA_CONF=$(sudo -u postgres psql -p "$PG_PORT" -At \
    -c "SHOW hba_file;" 2>/dev/null) \
    || die "Cannot query hba_file from PostgreSQL on port $PG_PORT"

  # Add entry only if no specific host line for laranode@127.0.0.1/32 exists.
  # We do NOT remove the default 'host all all 127.0.0.1/32 scram-sha-256'
  # catchall. The appended line lands after that catchall (first-match-wins), so
  # the catchall actually matches first — harmless because both require
  # scram-sha-256, and the smoke-test below confirms laranode can authenticate.
  if ! grep -qE '^host[[:space:]]+laranode[[:space:]]+laranode[[:space:]]+127\.0\.0\.1/32' \
      "$HBA_CONF"; then
    echo "host    laranode        laranode        127.0.0.1/32            scram-sha-256" \
      >> "$HBA_CONF"
    sudo -u postgres psql -p "$PG_PORT" \
      -c "SELECT pg_reload_conf();" >/dev/null
  fi

  # ── smoke-test: panel user connects via 127.0.0.1 with password ──────────
  PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -p "$PG_PORT" \
    -U laranode -d laranode -c "SELECT 1;" >/dev/null \
    || die "Panel DB user 'laranode' cannot connect via 127.0.0.1:${PG_PORT} — check pg_hba.conf"

  # ── stats-reader role (laranode_pg_reader) — bound to the RESOLVED port ───
  # The pgsql_admin connection in config/database.php reads PGSQL_* keys.
  # We must target the same cluster port that the panel uses, not :5432 blindly.
  local PGSQL_READER_PASS PGSQL_PG_TAG
  PGSQL_READER_PASS=$(openssl rand -base64 18)
  PGSQL_PG_TAG="q$(head -c 16 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 8)"

  sudo -u postgres psql -p "$PG_PORT" -v ON_ERROR_STOP=1 --dbname=postgres <<SQL
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

  # ── write .env keys via env_set ───────────────────────────────────────────
  # phase_database runs before phase_app, so .env may not exist yet. Seed it
  # from .env.example first (full template) so env_set updates existing keys
  # instead of leaving a stub .env that phase_app would then preserve as-is.
  [ -f "${PANEL_PATH}/.env" ] || cp "${PANEL_PATH}/.env.example" "${PANEL_PATH}/.env"

  # Panel's own DB connection (config/database.php 'pgsql' block reads DB_*).
  env_set DB_CONNECTION pgsql           "${PANEL_PATH}/.env"
  env_set DB_HOST       127.0.0.1       "${PANEL_PATH}/.env"
  env_set DB_PORT       "$PG_PORT"      "${PANEL_PATH}/.env"
  env_set DB_DATABASE   laranode        "${PANEL_PATH}/.env"
  env_set DB_USERNAME   laranode        "${PANEL_PATH}/.env"
  env_set DB_PASSWORD   "$DB_PASS"      "${PANEL_PATH}/.env"

  # Stats-reader admin connection (config/database.php 'pgsql_admin' reads PGSQL_*).
  # PGSQL_USERNAME is required: pgsql_admin defaults to 'postgres', so without it
  # the stats connection would try the postgres user with the reader's password
  # and fail scram-sha-256 auth.
  env_set PGSQL_HOST     127.0.0.1            "${PANEL_PATH}/.env"
  env_set PGSQL_PORT     "$PG_PORT"           "${PANEL_PATH}/.env"
  env_set PGSQL_USERNAME laranode_pg_reader   "${PANEL_PATH}/.env"
  env_set PGSQL_PASSWORD "$PGSQL_READER_PASS" "${PANEL_PATH}/.env"

  # ── persist secrets ───────────────────────────────────────────────────────
  persist_secret "PostgreSQL panel password  (laranode):           $DB_PASS"
  persist_secret "PostgreSQL reader password (laranode_pg_reader): $PGSQL_READER_PASS"

  log "PostgreSQL setup complete — port=$PG_PORT db/user=laranode"
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

# _apache_ports_conf FILE — rewrite Apache's ports.conf for the panel.
#  * HTTP_PORT != 80 or a bind address: drop the stock wildcard 'Listen 80' and any
#    earlier panel Listen, declare exactly one (address:port when bound). Apache
#    then never competes for :80 and never listens wider than asked.
#  * :443 held by another process: comment out mod_ssl's 'Listen 443' (it would stop
#    Apache from starting). HTTPS for the panel is then not served by this Apache.
_apache_ports_conf() {
  local ports_conf="$1"
  local _listen="${HTTP_PORT}"
  [ -z "$BIND_ADDR" ] || _listen="${BIND_ADDR}:${HTTP_PORT}"
  if [ "$HTTP_PORT" -ne 80 ] || [ -n "$BIND_ADDR" ]; then
    sed -i -E "/^[[:space:]]*Listen[[:space:]]+(80|(([0-9]{1,3}\.){3}[0-9]{1,3}:)?${HTTP_PORT})[[:space:]]*\$/d" "$ports_conf"
    printf 'Listen %s\n' "${_listen}" >> "$ports_conf"
  fi

  if port_in_use 443 && ! ss -tlnp '( sport = :443 )' 2>/dev/null | grep -q apache2; then
    sed -i -E 's/^([[:space:]]*)Listen[[:space:]]+443([[:space:]]+https)?[[:space:]]*$/\1# laranode: :443 busy, disabled: Listen 443\2/' "$ports_conf"
    warn ":443 is in use on this host — Apache's 'Listen 443' disabled; panel stays HTTP-only (use the SSH tunnel)."
  fi
}

# _configure_firewall — allow-only (never 'ufw enable'); have_cmd-gated (no
# fail-open). ufw is NEVER touched when the host is Proxmox (pve-firewall owns the
# firewall), CloudPanel (the production firewall is the operator's), or when the
# panel is bound to one address (no public port to open). REVERB_PORT comes from
# preflight.
_configure_firewall() {
  if [ "$IS_PROXMOX" = 1 ]; then
    log "Proxmox host: ufw not used, pve-firewall untouched (open the panel port in pve-firewall if needed)"
  elif [ "$IS_CLOUDPANEL" = 1 ]; then
    log "CloudPanel host: firewall untouched"
  elif [ -n "$BIND_ADDR" ]; then
    log "Panel bound to ${BIND_ADDR}: no firewall rules added"
  elif have_cmd ufw; then
    ufw allow "${HTTP_PORT}"    # panel HTTP
    ufw allow "${REVERB_PORT}"  # Reverb websockets
    ufw allow 443               # HTTPS / certbot
    ufw allow 22                # SSH
  else
    warn "ufw not installed — firewall rules NOT configured. Configure the host firewall manually before exposing the panel."
  fi
}

phase_webserver() {
  log "Installing Apache Web Server"
  # Suppress service auto-start during apt: on a host where :80 is already held
  # (e.g. nginx) Apache's default 'Listen 80' would fail to bind and abort the
  # install under set -e. We configure ports first, then start Apache ourselves.
  local _added_policy=0
  if [ ! -e /usr/sbin/policy-rc.d ]; then
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d
    _added_policy=1
    # Safety net: if an apt-get below aborts under set -e, still remove the guard
    # we created (the explicit rm after the installs handles the success path).
    trap 'rm -f /usr/sbin/policy-rc.d' EXIT
  fi
  apt_install apache2
  apt_install certbot python3-certbot-apache
  [ "$_added_policy" -eq 1 ] && rm -f /usr/sbin/policy-rc.d

  log "Enabling required Apache modules"
  a2enmod proxy_fcgi rewrite setenvif headers ssl proxy proxy_http >/dev/null

  [ -n "${HTTP_PORT:-}" ]  || die "HTTP_PORT not set — preflight must run first"
  [ -n "${PANEL_PATH:-}" ] || die "PANEL_PATH not set — preflight must run first"

  # Render the panel vhost from the template. NEVER writes 000-default.conf.
  local tmpl="${PANEL_PATH}/laranode-scripts/templates/apache-panel.template"
  local dest="/etc/apache2/sites-available/laranode.conf"
  [ -f "$tmpl" ] || die "apache-panel.template missing at ${tmpl}"
  sed -e "s|__PORT__|${HTTP_PORT}|g" \
      -e "s|__DOCROOT__|${PANEL_PATH}/public|g" \
      "$tmpl" > "$dest"

  # Panel never uses the stock default site.
  a2dissite 000-default >/dev/null 2>&1 || true

  _apache_ports_conf /etc/apache2/ports.conf

  a2ensite laranode || die "a2ensite laranode failed"
  apachectl configtest || die "Apache config test failed — review ${dest}"

  systemctl enable apache2 >/dev/null 2>&1 || true
  systemctl restart apache2 || die "apache2 start/restart failed after enabling laranode.conf"
  svc_active apache2 || die "apache2 is not active after restart"

  # Confirm the socket is open (full HTTP 200 check is phase_services, after the
  # app is bootstrapped). This surfaces port-fork bugs early.
  ss -tlnH "( sport = :${HTTP_PORT} )" | grep -q . \
    || die "Apache is not listening on :${HTTP_PORT} after restart"

  _configure_firewall

  log "Apache panel vhost active on :${HTTP_PORT}"
}

# ==============================================================================
# Phase 5 — PHP 8.4, Node.js, Composer, PostgreSQL client
# ==============================================================================

phase_php_node() {
  log "PHP 8.4 + Node"

  # ---- PHP ----------------------------------------------------------------
  # Where php8.4 comes from depends on the host:
  #   Ubuntu 24.04 -> ppa:ondrej/php (Ubuntu itself ships 8.3)
  #   Debian 13    -> Debian's own php8.4 packages (no third-party repository)
  #   CloudPanel   -> CloudPanel's own php8.4 builds (+clp-noble); the PPA would
  #                   replace them, so no repository is added
  if [ "$IS_CLOUDPANEL" = 1 ]; then
    log "CloudPanel host: using the already-configured php8.4 packages (no PPA)"
  elif [ "$OS_ID" = debian ]; then
    log "Debian ${OS_VERSION}: using Debian's php8.4 packages (no extra repository)"
  else
    log "Adding ppa:ondrej/php"
    add-apt-repository -y ppa:ondrej/php \
      || die "add-apt-repository ppa:ondrej/php failed — check network/GPG"
  fi
  apt-get update -qq

  # Capture the system php alternative BEFORE installing php8.4. ppa:ondrej/php
  # registers php8.4 at a higher priority, so apt auto-mode would silently flip
  # the system default. Record it now; restore it after if apt changed it.
  local sys_php=""
  sys_php=$(update-alternatives --query php 2>/dev/null | awk '/^Value:/{print $2}') || true

  log "Installing php8.4 and extensions (additive)"
  local -a php_pkgs=(php8.4 php8.4-fpm php8.4-cli php8.4-common php8.4-curl php8.4-mbstring
    php8.4-xml php8.4-bcmath php8.4-zip php8.4-mysql php8.4-sqlite3 php8.4-pgsql
    php8.4-gd php8.4-imagick php8.4-intl php8.4-readline php8.4-soap php8.4-opcache
    unzip curl)
  # tokenizer/fileinfo are separate packages on the PPA but virtual packages
  # provided by php8.4-common on Debian.
  [ "$OS_ID" = debian ] || php_pkgs+=(php8.4-tokenizer php8.4-fileinfo)
  if [ "$IS_CLOUDPANEL" = 1 ]; then
    # CloudPanel's repository carries its own subset of extensions: install what
    # exists, warn about the rest, but php8.4-fpm and -cli are mandatory.
    local -a avail=()
    local p cand
    for p in "${php_pkgs[@]}"; do
      cand=$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{print $2}')
      if [ -n "$cand" ] && [ "$cand" != "(none)" ]; then avail+=("$p")
      else warn "package ${p} not available on this CloudPanel host — skipped"; fi
    done
    php_pkgs=("${avail[@]}")
    [[ " ${php_pkgs[*]} " == *" php8.4-fpm "* && " ${php_pkgs[*]} " == *" php8.4-cli "* ]] \
      || die "php8.4-fpm / php8.4-cli not available from the configured apt sources — install them first and re-run"
  fi
  apt_install "${php_pkgs[@]}" || die "apt-get install php8.4 extensions failed"

  # Restore the operator's prior alternative if apt auto-flipped it to 8.4. The
  # panel always calls /usr/bin/php8.4 directly, so the system default must stay
  # whatever the operator had.
  if [ -n "$sys_php" ] && [ "$sys_php" != "/usr/bin/php8.4" ]; then
    local after_php=""
    after_php=$(update-alternatives --query php 2>/dev/null | awk '/^Value:/{print $2}') || true
    if [ "$after_php" = "/usr/bin/php8.4" ]; then
      update-alternatives --set php "$sys_php" \
        || warn "could not restore php alternative to ${sys_php} — check manually"
    fi
    warn "System 'php' alternative left as ${sys_php}. Panel uses /usr/bin/php8.4 directly."
  fi

  log "Enabling PHP-FPM"
  systemctl enable php8.4-fpm || die "systemctl enable php8.4-fpm failed"
  systemctl start php8.4-fpm  || die "systemctl start php8.4-fpm failed"

  # php8.4-fpm package provides /etc/apache2/conf-available/php8.4-fpm.conf;
  # a2enconf must run after the package is installed.
  if [ -f /etc/apache2/conf-available/php8.4-fpm.conf ]; then
    a2enconf php8.4-fpm
  else
    # CloudPanel's php8.4-fpm build does not ship the Apache conf snippet.
    warn "php8.4-fpm.conf not provided by the package — writing laranode-php-fpm.conf (socket /run/php/php8.4-fpm.sock, verify on this host)"
    cat > /etc/apache2/conf-available/laranode-php-fpm.conf <<'CONF'
<FilesMatch ".+\.ph(?:ar|p|tml)$">
    SetHandler "proxy:unix:/run/php/php8.4-fpm.sock|fcgi://localhost"
</FilesMatch>
CONF
    a2enconf laranode-php-fpm
  fi

  # Client tools only: the server package is installed (or reused) by the
  # database phase according to LARANODE_DB_ENGINE.
  log "Installing PostgreSQL client"
  apt_install postgresql-client

  log "Installing Composer"
  curl -sS https://getcomposer.org/installer \
    | php8.4 -- --install-dir=/usr/local/bin --filename=composer

  # ---- Node ---------------------------------------------------------------
  if have_cmd node; then
    local node_ver=""
    node_ver=$(node -v | tr -d 'v')
    warn "node already present (v${node_ver}); skipping nodesource setup"
    version_ge "${node_ver}" "20" \
      || die "panel build needs Node >=20; found v${node_ver} — install/upgrade and re-run"
  else
    log "Installing Node 22 via nodesource"
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
      || die "nodesource setup_22.x script failed"
    apt_install nodejs || die "apt-get install nodejs failed"
    local installed_ver=""
    installed_ver=$(node -v | tr -d 'v')
    [ "${installed_ver%%.*}" = "22" ] \
      || die "expected Node major 22 after nodesource install; got v${installed_ver}"
  fi
}

# ==============================================================================
# Phase 6 — Application provisioning
# ==============================================================================

phase_app() {
  log "App provisioning"

  [ -f "${PANEL_PATH}/composer.json" ] \
    || die "composer.json not found at ${PANEL_PATH} — repo clone missing or PANEL_PATH wrong"
  cd "${PANEL_PATH}"

  log "Installing PHP dependencies (composer install)"
  /usr/bin/php8.4 /usr/local/bin/composer install --no-interaction --optimize-autoloader

  # .env — copy example only when absent; never clobber existing config.
  if [ ! -f "${PANEL_PATH}/.env" ]; then
    cp "${PANEL_PATH}/.env.example" "${PANEL_PATH}/.env"
    log ".env created from .env.example"
  else
    log ".env already present — preserving existing configuration"
  fi

  # APP_KEY — generate ONLY when absent/blank; never --force-rotate a valid key.
  if grep -q '^APP_KEY=base64:' "${PANEL_PATH}/.env"; then
    log "APP_KEY already set — preserving (idempotent re-run)"
  else
    log "APP_KEY not set — generating"
    /usr/bin/php8.4 artisan key:generate --force
  fi

  # Resolve canonical panel hostname: LARANODE_APP_URL > public IP.
  local host_val=""
  if [ -n "${LARANODE_APP_URL:-}" ]; then
    host_val="${LARANODE_APP_URL%/}"
    log "Using LARANODE_APP_URL: ${host_val}"
  elif [ "$BIND_ADDR" = "127.0.0.1" ]; then
    # Panel reachable only from the host itself (SSH tunnel): the public IP
    # would be wrong, and this needs no outside call.
    host_val="http://127.0.0.1"
    [ "$HTTP_PORT" = 80 ] || host_val="${host_val}:${HTTP_PORT}"
    log "Panel bound to 127.0.0.1 -> APP_URL=${host_val}"
  else
    local public_ip=""
    public_ip="$(curl -fsS icanhazip.com 2>/dev/null | tr -d '[:space:]')" || true
    [ -n "$public_ip" ] \
      || die "Public IP lookup failed (curl icanhazip.com empty). Set LARANODE_APP_URL=http://<host>."
    host_val="http://${public_ip}"
    [ "$HTTP_PORT" = 80 ] || host_val="${host_val}:${HTTP_PORT}"
    log "Resolved public IP: ${public_ip} -> APP_URL=${host_val}"
  fi
  [[ "$host_val" =~ ^https?://.+$ ]] \
    || die "Resolved APP_URL '${host_val}' is not a valid URL. Set LARANODE_APP_URL=http://<hostname>."
  # Reverb host is the bare hostname: no scheme, port or path.
  local bare_host="${host_val#http://}"; bare_host="${bare_host#https://}"
  bare_host="${bare_host%%/*}"; bare_host="${bare_host%%:*}"

  # APP_URL — write only when absent or the Laravel placeholder http://localhost.
  local cur_app_url=""
  cur_app_url="$(grep -E '^APP_URL=' "${PANEL_PATH}/.env" | cut -d= -f2- | tr -d '"' | tr -d "'")" || true
  if [ -z "$cur_app_url" ] || [ "$cur_app_url" = "http://localhost" ]; then
    env_set APP_URL "$host_val" "${PANEL_PATH}/.env"
    log "APP_URL set to ${host_val}"
  else
    log "APP_URL already '${cur_app_url}' — preserving (re-run safe)"
  fi

  log "Installing sudoers drop-ins for www-data"
  local drop SRC
  for drop in laranode-panel laranode-cron laranode-runtimes laranode-ufw; do
    SRC="${PANEL_PATH}/laranode-scripts/etc/sudoers.d/${drop}"
    visudo -c -f "${SRC}" >/dev/null \
      || die "sudoers file ${drop} failed syntax check — aborting"
    install -m 440 "${SRC}" "/etc/sudoers.d/${drop}"
  done
  rm -f /etc/sudoers.d/laranode-postgres

  log "Running database migrations"
  /usr/bin/php8.4 artisan migrate --force \
    || die "artisan migrate --force failed — verify DB_* in .env and phase_database logs"

  # One-time installs (idempotent: non-zero on re-run is expected/tolerated).
  /usr/bin/php8.4 artisan storage:link 2>/dev/null || true
  /usr/bin/php8.4 artisan reverb:install --no-interaction 2>/dev/null || true

  # REVERB_HOST / VITE_REVERB_HOST — set only when absent or 'localhost'.
  local cur_reverb=""
  cur_reverb="$(grep -E '^REVERB_HOST=' "${PANEL_PATH}/.env" | cut -d= -f2- | tr -d '"' | tr -d "'")" || true
  if [ -z "$cur_reverb" ] || [ "$cur_reverb" = "localhost" ]; then
    env_set REVERB_HOST "$bare_host" "${PANEL_PATH}/.env"; log "REVERB_HOST set to ${bare_host}"
  else
    log "REVERB_HOST already '${cur_reverb}' — preserving"
  fi
  local cur_vite=""
  cur_vite="$(grep -E '^VITE_REVERB_HOST=' "${PANEL_PATH}/.env" | cut -d= -f2- | tr -d '"' | tr -d "'")" || true
  if [ -z "$cur_vite" ] || [ "$cur_vite" = "localhost" ]; then
    env_set VITE_REVERB_HOST "$bare_host" "${PANEL_PATH}/.env"; log "VITE_REVERB_HOST set to ${bare_host}"
  else
    log "VITE_REVERB_HOST already '${cur_vite}' — preserving"
  fi

  # Reverb defaults to :8080. When the panel itself is on :8080 (because :80 was
  # occupied), shift Reverb to :8081 to avoid a collision. Idempotent via env_set.
  # REVERB_PORT comes from preflight: 8080 unless taken/reserved (8081 then).
  if [ "${REVERB_PORT:-8080}" != 8080 ]; then
    env_set REVERB_SERVER_PORT "${REVERB_PORT}" "${PANEL_PATH}/.env"
    env_set REVERB_PORT        "${REVERB_PORT}" "${PANEL_PATH}/.env"
    env_set VITE_REVERB_PORT   "${REVERB_PORT}" "${PANEL_PATH}/.env"
  fi
  # Bound panel: Reverb listens on the same address only (default 0.0.0.0).
  if [ -n "$BIND_ADDR" ]; then
    env_set REVERB_SERVER_HOST "${BIND_ADDR}" "${PANEL_PATH}/.env"
  fi

  # GPU detection — best-effort.
  /usr/bin/php8.4 artisan laranode:detect-gpu 2>/dev/null || true

  # First-run seed sentinel: seed ONLY when the users table is empty.
  log "Checking first-run seed sentinel (users table row count)"
  local user_count=1
  user_count="$(/usr/bin/php8.4 artisan tinker --execute="echo App\\Models\\User::count();" 2>/dev/null | tail -1 | tr -d ' \r\n')" || user_count=1
  if [ "$user_count" = "0" ]; then
    log "Users table empty — running db:seed (first install)"
    /usr/bin/php8.4 artisan db:seed --force || die "artisan db:seed --force failed"
  else
    log "Users table has ${user_count} row(s) — skipping seed (idempotent re-run)"
  fi

  log "Building front-end assets"
  # package-lock.json is gitignored, so each install resolves the registry afresh. npm 10 then
  # crashes in arborist (peer set of vitest 4 vs vitest 5 add-ons: "reading edgesOut").
  # --legacy-peer-deps skips auto-installing peers; the ones the build needs are explicit
  # in package.json (e.g. @testing-library/dom).
  npm install --legacy-peer-deps
  # phase_services `find -type f -exec chmod 660` strips exec bits from npm
  # binaries on a previous install. Restore u+x on bin-script files so that
  # npm run build succeeds on idempotent re-runs. chmod -R silently skips
  # symlinks, so we target the actual files via find.
  find "${PANEL_PATH}/node_modules" -type f -path "*/bin/*" \
    -exec chmod u+x {} \; 2>/dev/null || true
  npm run build
}

# ==============================================================================
# Phase 7 — Services, firewall, permissions
# ==============================================================================

# ------------------------------------------------------------------------------
# Service manifest — which systemd units this installer owns vs. found and left alone.
# Written to ${LARANODE_MANIFEST_FILE:-/etc/laranode/service-manifest.json}. One service
# per line so shell and PHP can both read it. Consumers (e.g. the sleep/wake feature)
# may stop/start ONLY entries with "managed":true. Format v1:
#   {"version":1,"generated":"<UTC ISO8601>","host":{"os":"debian 13","proxmox":false,
#    "cloudpanel":false},"db":{"engine":"pgsql","unit":"postgresql@17-main.service"},
#    "services":[
#   {"unit":"laranode-reverb.service","managed":true,"role":"reverb","reason":"installed-by-laranode"},
#   {"unit":"nginx.service","managed":false,"role":"preexisting","reason":"present-before-install"}
#    ]}
# "managed":true  = created or installed by this installer (also kept across re-runs).
# "managed":false = present before the installer ran: never stop/start/restart it.
# ------------------------------------------------------------------------------
PRE_APACHE=0; PRE_PHPFPM=0; PRE_UNITS=""
PANEL_DB_UNIT=""; PANEL_DB_MANAGED=0

# capture_preexisting — read-only snapshot taken in preflight, before any install.
capture_preexisting() {
  pkg_installed apache2   && PRE_APACHE=1 || PRE_APACHE=0
  pkg_installed php8.4-fpm && PRE_PHPFPM=1 || PRE_PHPFPM=0
  PRE_UNITS=""
  have_cmd systemctl || return 0
  local pat
  for pat in 'nginx*' 'apache2*' 'mysql*' 'mariadb*' 'percona*' 'postgresql@*' 'redis*' \
             'varnish*' 'memcached*' 'clp-*' 'php*-fpm*'; do
    PRE_UNITS+=$(systemctl list-units --type=service --all --plain --no-legend "$pat" 2>/dev/null \
                   | awk '$1 ~ /\.service$/ {print $1}')$'\n'
  done
  PRE_UNITS=$(printf '%s' "$PRE_UNITS" | sed '/^$/d' | sort -u)
}

# _prior_managed — units a previous run recorded as managed (re-run must not
# reclassify what we installed earlier as "pre-existing").
_prior_managed() {
  local mf="${LARANODE_MANIFEST_FILE:-/etc/laranode/service-manifest.json}"
  [ -f "$mf" ] || return 0
  grep '"managed":true' "$mf" | sed -n 's/.*"unit":"\([^"]*\)".*/\1/p' || true
}

# write_service_manifest — call after all services are installed and started.
write_service_manifest() {
  local mf="${LARANODE_MANIFEST_FILE:-/etc/laranode/service-manifest.json}"
  local prior; prior=$(_prior_managed)
  local -a lines=()
  local seen=" "
  _mf_add() {  # unit managed role reason
    case "$seen" in *" $1 "*) return 0;; esac
    seen+="$1 "
    lines+=("$(printf '{"unit":"%s","managed":%s,"role":"%s","reason":"%s"}' "$1" "$2" "$3" "$4")")
  }
  _is_prior() { printf '%s\n' "$prior" | grep -qxF "$1"; }
  local u

  _mf_add laranode-reverb.service         true reverb "installed-by-laranode"
  _mf_add laranode-queue-worker.service   true queue  "installed-by-laranode"
  if [ "$PRE_APACHE" = 0 ] || _is_prior apache2.service; then
    _mf_add apache2.service true web "installed-by-laranode"
  else
    _mf_add apache2.service false web "present-before-install (panel vhost added only)"
  fi
  if [ "$PRE_PHPFPM" = 0 ] || _is_prior php8.4-fpm.service; then
    _mf_add php8.4-fpm.service true php "installed-by-laranode"
  else
    _mf_add php8.4-fpm.service false php "present-before-install"
  fi
  if [ -n "$PANEL_DB_UNIT" ]; then
    if [ "$PANEL_DB_MANAGED" = 1 ] || _is_prior "$PANEL_DB_UNIT"; then
      _mf_add "$PANEL_DB_UNIT" true database "installed-by-laranode"
    else
      _mf_add "$PANEL_DB_UNIT" false database "present-before-install (panel schema/role added only)"
    fi
  fi
  # Everything else seen running before the install is not ours, ever.
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    _mf_add "$u" false preexisting "present-before-install"
  done <<< "$PRE_UNITS"

  mkdir -p "$(dirname "$mf")"
  {
    printf '{"version":1,"generated":"%s","host":{"os":"%s %s","proxmox":%s,"cloudpanel":%s},' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$OS_ID" "$OS_VERSION" \
      "$([ "$IS_PROXMOX" = 1 ] && echo true || echo false)" \
      "$([ "$IS_CLOUDPANEL" = 1 ] && echo true || echo false)"
    printf '"db":{"engine":"%s","unit":"%s"},\n"services":[\n' "${DB_ENGINE:-}" "$PANEL_DB_UNIT"
    local i
    for i in "${!lines[@]}"; do
      printf '%s%s\n' "${lines[$i]}" "$([ "$i" -lt $((${#lines[@]} - 1)) ] && echo ,)"
    done
    printf ']}\n'
  } > "$mf"
  chmod 644 "$mf"
  log "Service manifest written: ${mf}"
}

# _install_scheduler_cron — the panel defines scheduled work in bootstrap/app.php
# (backups every minute, SSL-expiry notices, pruning) but nothing ever ran
# `schedule:run`. Render the cron.d template (user/path/php are the installer's own).
# LARANODE_CRON_DIR is a test seam; default /etc/cron.d.
_install_scheduler_cron() {
  local dir="${LARANODE_CRON_DIR:-/etc/cron.d}"
  local tpl="${PANEL_PATH}/laranode-scripts/templates/laranode-schedule.cron"
  [ -f "$tpl" ] || die "scheduler cron template missing: $tpl"
  mkdir -p "$dir"
  sed -e "s#__PANEL_USER__#laranode_ln#g" \
      -e "s#__PHP__#/usr/bin/php8.4#g" \
      -e "s#__PANEL_PATH__#${PANEL_PATH}#g" \
      "$tpl" > "${dir}/laranode-schedule"
  chmod 644 "${dir}/laranode-schedule"
  log "Scheduler cron installed: ${dir}/laranode-schedule"
}

phase_services() {
  log "Installing systemd service units"
  cp "${PANEL_PATH}/laranode-scripts/templates/laranode-queue-worker.service" \
    /etc/systemd/system/laranode-queue-worker.service
  cp "${PANEL_PATH}/laranode-scripts/templates/laranode-reverb.service" \
    /etc/systemd/system/laranode-reverb.service

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
  _install_scheduler_cron
  systemctl enable --now cron
  systemctl enable laranode-queue-worker.service
  systemctl enable laranode-reverb.service
  systemctl start laranode-queue-worker.service
  systemctl start laranode-reverb.service
  systemctl restart apache2
  systemctl restart php8.4-fpm
  write_service_manifest
}

# ==============================================================================
# Phase 8 — Summary
# ==============================================================================

phase_summary() {
  log "Install summary"
  local panel_url=""
  panel_url="$(grep -E '^APP_URL=' "${PANEL_PATH}/.env" | cut -d= -f2- | tr -d '"' | tr -d "'")" || true
  persist_secret "# Laranode panel — URL: ${panel_url} — DB engine: ${DB_ENGINE}"

  echo "========================================================================"
  echo "  Laranode install complete"
  echo "========================================================================"
  echo "  Panel URL:    ${panel_url}"
  echo "  DB engine:    ${DB_ENGINE}"
  if [ "$BIND_ADDR" = "127.0.0.1" ]; then
    echo "  Bound to 127.0.0.1 only. Reach it through an SSH tunnel (forward both ports):"
    echo "    ssh -L ${HTTP_PORT}:127.0.0.1:${HTTP_PORT} -L ${REVERB_PORT}:127.0.0.1:${REVERB_PORT} <user>@<this-host>"
  fi
  echo ""
  echo "  All generated credentials saved to: /root/.laranode-credentials (chmod 600)"
  echo ""
  echo "  Final step — create the panel admin account:"
  echo "    cd ${PANEL_PATH} && /usr/bin/php8.4 artisan laranode:create-admin"
  echo "========================================================================"
}

# ==============================================================================
# Entrypoint
# ==============================================================================

# ensure_probe_tools — preflight reads listeners with `ss`. A minimal image (e.g. a
# bare Debian 13) may not ship iproute2; without it every port would read as free.
# Installing iproute2 is the only change made before the plan is shown.
ensure_probe_tools() {
  command -v ss >/dev/null 2>&1 && return 0
  log "Installing iproute2 (provides ss, needed to detect busy ports)"
  apt-get update -q
  DEBIAN_FRONTEND=noninteractive apt-get install -y iproute2
  command -v ss >/dev/null 2>&1 || die "ss (iproute2) is required for port detection"
}

main() {
  ensure_probe_tools
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
