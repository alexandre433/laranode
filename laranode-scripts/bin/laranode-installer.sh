#!/bin/bash
set -euo pipefail

# ---- Test seams are not part of the operator interface ----------------------------------------
# These variables redirect or weaken safety machinery (the rollback journal dir feeds an rm -rf,
# APT_ALLOW_SERVICE_START unguards apt, the pid/start seams fake an installer identity, the
# *_DIR / *_FILE seams fake host detection). They exist for the unit tests only, so an inherited
# value (`APT_ALLOW_SERVICE_START=1 ./laranode-installer.sh`, a stray export in a profile) is
# dropped here unless the test harness says so. The documented overrides (LARANODE_OS,
# LARANODE_MANIFEST_FILE, LARANODE_PROBE_PROC, ...) are not touched.
if [ "${LARANODE_INSTALLER_TEST:-0}" != 1 ]; then
  unset APT_ALLOW_SERVICE_START LARANODE_ROLLBACK_DIR LARANODE_INSTALLER_PID LARANODE_INSTALLER_START \
        LARANODE_POLICY_RC_D LARANODE_APACHE_DIR LARANODE_APACHE_MODS_STATE LARANODE_OS_RELEASE_FILE \
        LARANODE_PVE_DIR LARANODE_CLP_DIR LARANODE_CRON_DIR LARANODE_PROC_NET_DIR LARANODE_PROC_DIR
fi

export DEBIAN_FRONTEND=noninteractive
# needrestart (default on Ubuntu 22.04+/24.04 images) restarts services after apt
# installs. List-only mode (l) and suspend stop it from restarting host services
# (sshd, nginx, the DB, ...) behind the operator's back.
export NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1

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
svc_active()  { systemctl is-active --quiet "$1"; }

# ---- Exit hooks ---------------------------------------------------------------
# One EXIT trap runs every registered cleanup, however the installer ends: normal exit,
# die, or INT/TERM/HUP (turned into an exit so the trap fires; bash would otherwise skip
# it). Only SIGKILL / OOM / power loss cannot be caught: what those leave behind is
# marked so the next start can recognise and remove it (_policy_guard_clean_stale).
_EXIT_HOOKS=()
_run_exit_hooks() {
  local rc=$? h
  trap - EXIT
  # A second Ctrl-C / TERM / HUP while the cleanups run must not abort them half-way.
  trap '' INT TERM HUP
  for h in "${_EXIT_HOOKS[@]}"; do "$h" || true; done
  return "$rc"
}
_add_exit_hook() {
  local h seen=0
  for h in "${_EXIT_HOOKS[@]}"; do [ "$h" = "$1" ] && seen=1; done
  [ "$seen" = 1 ] || _EXIT_HOOKS+=("$1")
  # traps are reset in a subshell while the hook list is inherited: always (re)install them
  trap '_run_exit_hooks' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

# ---- Listening-socket probe -------------------------------------------------
# The plan is shown (and the operator asked to confirm) BEFORE anything is installed, so
# the busy-port checks must work on a host without iproute2: no `ss` means reading
# /proc/net/tcp{,6} instead of apt-installing a package first. LARANODE_PROC_NET_DIR and
# LARANODE_PROC_DIR are test seams.
# LARANODE_PROBE_PROC=1 forces the /proc/net/tcp fallback (test seam: a host without iproute2).
_have_ss() { [ "${LARANODE_PROBE_PROC:-0}" != 1 ] && command -v ss >/dev/null 2>&1; }
_proc_net() { echo "${LARANODE_PROC_NET_DIR:-/proc/net}"; }
_proc_dir() { echo "${LARANODE_PROC_DIR:-/proc}"; }
# _probe_available — listeners can be read (ss, or /proc/net/tcp).
_probe_available() { _have_ss || [ -r "$(_proc_net)/tcp" ]; }
# _proc_listen_inodes PORT — socket inode of every TCP LISTEN (state 0A) socket on PORT.
_proc_listen_inodes() {
  local hex f; hex=$(printf '%04X' "$1")
  for f in "$(_proc_net)/tcp" "$(_proc_net)/tcp6"; do
    [ -r "$f" ] || continue
    awk -v hex="$hex" 'NR > 1 && $4 == "0A" { n = split($2, a, ":"); if (a[n] == hex) print $10 }' "$f"
  done
}
port_in_use() {
  if _have_ss; then ss -tlnH "( sport = :$1 )" | grep -q .
  else
    # NOT `... | grep -q .`: grep exits at the first inode, the second awk (tcp6) then writes
    # to a closed pipe and, under pipefail, the SIGPIPE makes a dual-stack listener read FREE.
    [ -n "$(_proc_listen_inodes "$1")" ]
  fi
}

# Apache config root and the policy-rc.d guard path are overridable so the unit tests can run the
# Apache phase against a scratch directory.
_apache_dir()    { echo "${LARANODE_APACHE_DIR:-/etc/apache2}"; }
_policy_rc_d()   { echo "${LARANODE_POLICY_RC_D:-/usr/sbin/policy-rc.d}"; }
# _port_holder PORT — name of the process listening on PORT ("another process" if unknown).
_port_holder() {
  local h="" ino fd pid
  if _have_ss; then
    h=$(ss -tlnp "( sport = :$1 )" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1 || true)
  else
    for ino in $(_proc_listen_inodes "$1"); do
      for fd in "$(_proc_dir)"/[0-9]*/fd/*; do
        [ "$(readlink "$fd" 2>/dev/null)" = "socket:[${ino}]" ] || continue
        pid=${fd%/fd/*}
        h=$(cat "${pid}/comm" 2>/dev/null || true)
        [ -z "$h" ] || break 2
      done
    done
  fi
  echo "${h:-another process}"
}

# ---- policy-rc.d guard ----------------------------------------------------------
# While apt installs apache2 / the php packages, a policy-rc.d that answers 101 stops the
# postinst scripts from starting or restarting services (a fresh Apache's default
# 'Listen 80' would collide with nginx; a live php8.4-fpm must not be bounced). The file
# is ours only if it carries the marker: one that is not is the owner's and is never
# created over, removed or "cleaned". It records the installer's pid, so a guard left by
# a killed installer (SIGKILL, OOM, power loss) is recognised as stale at the next start.
_PG_MARK='laranode-installer policy-rc.d guard'
_PRC_ADDED=0
_PG_DEPTH=0
# The installer's own pid (a test seam: unit tests run phases in subshells).
_installer_pid() { echo "${LARANODE_INSTALLER_PID:-$$}"; }
# A pid alone does not identify a process: after a reboot (or enough churn) another process can
# hold the pid a dead installer had. The identity is pid + start time: "<boot id>.<starttime>" from
# /proc/<pid>/stat (field 22, in clock ticks since boot; the boot id tells two boots apart). Empty
# when it cannot be read; a record without it falls back to the plain pid check.
_pid_start() {
  local st boot
  st=$(sed 's/.*) //' "/proc/${1}/stat" 2>/dev/null | cut -d' ' -f20) || return 0
  [ -n "$st" ] || return 0
  boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
  echo "${boot}.${st}"
}
_installer_start() { echo "${LARANODE_INSTALLER_START:-$(_pid_start "$(_installer_pid)")}"; }
# _pid_alive PID [START] — PID is running AND (when START is given) it is the same process.
_pid_alive() {
  kill -0 "$1" 2>/dev/null || return 1
  [ -z "${2:-}" ] || [ "$(_pid_start "$1")" = "$2" ]
}
_policy_guard_is_ours() { [ -f "$(_policy_rc_d)" ] && grep -q "$_PG_MARK" "$(_policy_rc_d)" 2>/dev/null; }
# The guard file answers 101 ("do not start") only while the installer that wrote it is alive.
# After a SIGKILL / OOM / power loss the pid is dead and the file answers 0 ("allowed"): it is
# inert at once and cannot block the owner's service starts, even before the next run removes it.
# "Alive" means the same pid AND the same start time: a pid reused by another process after a
# reboot answers 0 like a dead installer (see _pid_start). Without a readable start time the
# script falls back to the pid check alone.
_policy_guard_script() {  # _policy_guard_script PID START
  local pid="$1" start="$2"
  if [ -n "$start" ]; then
    printf '#!/bin/sh\n# %s pid=%s start=%s\nkill -0 %s 2>/dev/null && [ "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null).$(sed '"'"'s/.*) //'"'"' /proc/%s/stat 2>/dev/null | cut -d'"'"' '"'"' -f20)" = "%s" ] && exit 101\nexit 0\n' \
      "$_PG_MARK" "$pid" "$start" "$pid" "$pid" "$start"
  else
    printf '#!/bin/sh\n# %s pid=%s\nkill -0 %s 2>/dev/null && exit 101\nexit 0\n' "$_PG_MARK" "$pid" "$pid"
  fi
}
_policy_guard_on() {
  local prc pid start; prc=$(_policy_rc_d); pid=$(_installer_pid); start=$(_installer_start)
  # already held by this installer (an apt_install inside a guarded phase): count it
  if [ "$_PRC_ADDED" = 1 ]; then _PG_DEPTH=$((_PG_DEPTH + 1)); return 0; fi
  [ ! -e "$prc" ] || return 0                       # the owner's own policy-rc.d: leave it
  # noclobber: never overwrite a policy-rc.d that appeared since the check above
  if ( set -C; _policy_guard_script "$pid" "$start" > "$prc" ) 2>/dev/null; then
    chmod +x "$prc"
    _PRC_ADDED=1
    _PG_DEPTH=1
    _add_exit_hook _policy_guard_release
  fi
}
# _policy_guard_off — balances one _policy_guard_on; the file goes with the outermost one.
_policy_guard_off() {
  [ "$_PRC_ADDED" = 1 ] || return 0
  _PG_DEPTH=$((_PG_DEPTH - 1))
  [ "$_PG_DEPTH" -le 0 ] || return 0
  _policy_guard_release
}
# _policy_guard_release — the exit hook: remove OUR guard whatever the nesting depth.
_policy_guard_release() {
  [ "$_PRC_ADDED" = 1 ] || return 0
  if _policy_guard_is_ours; then rm -f "$(_policy_rc_d)"; fi
  _PRC_ADDED=0
  _PG_DEPTH=0
}
# _policy_guard_clean_stale — run at installer start: remove a marked guard whose installer
# is gone. Anything without the marker is not ours and stays.
_policy_guard_clean_stale() {
  local prc pid start; prc=$(_policy_rc_d)
  _policy_guard_is_ours || return 0
  pid=$(sed -n "s/^# ${_PG_MARK} pid=\([0-9][0-9]*\).*/\1/p" "$prc" | head -1)
  start=$(sed -n "s/^# ${_PG_MARK} pid=[0-9][0-9]* start=\([^ ]*\).*/\1/p" "$prc" | head -1)
  if [ -n "$pid" ] && _pid_alive "$pid" "$start"; then return 0; fi   # another installer is running
  warn "removing a stale ${prc} left by an interrupted Laranode install (it would silently stop every later package install from starting services)"
  rm -f "$prc"
}
# _panel_vhost_enabled — the panel's own Apache vhost is already enabled (a re-run).
_panel_vhost_enabled() { [ -e "$(_apache_dir)/sites-enabled/laranode.conf" ]; }

# version_ge HAVE WANT — returns 0 (true) when HAVE >= WANT (version sort)
version_ge() { printf '%s\n%s\n' "$2" "$1" | sort -V -C; }

# confirm MSG — returns 0 to proceed; auto-yes when LARANODE_UNATTENDED=1
confirm() {
  [ "${LARANODE_UNATTENDED:-0}" = "1" ] && return 0
  if [ ! -t 0 ]; then
    echo "FATAL: no terminal to confirm on (stdin is not a TTY, e.g. 'curl | bash' or CI). Re-run with LARANODE_UNATTENDED=1 to accept the plan." >&2
    return 1
  fi
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
  # umask 077: the file is created 0600 from the first byte (no 0644 window).
  ( umask 077; printf '%s\n' "$*" >> /root/.laranode-credentials )
  chmod 600 /root/.laranode-credentials
}

# _seed_env — create the panel .env from .env.example when absent. It receives the DB
# password right after, so it is never world-readable: created under umask 027 and
# handed to the panel's group (www-data/laranode_ln) at 0640. An existing .env is
# never touched.
_seed_env() {
  local env="${PANEL_PATH}/.env"
  [ -f "$env" ] && return 0
  ( umask 027; cp "${PANEL_PATH}/.env.example" "$env" )
  chmod 640 "$env"
  # owned by the panel account: artisan (key:generate) runs as laranode_ln and writes it
  if id laranode_ln >/dev/null 2>&1; then chown laranode_ln "$env"; fi
  if getent group laranode_ln >/dev/null 2>&1; then chgrp laranode_ln "$env"; fi
  return 0
}

# ------------------------------------------------------------------------------
# Host detection helpers (pure reads; every marker is overridable for tests)
# ------------------------------------------------------------------------------

# pkg_installed PKG — true when dpkg reports PKG fully installed
pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

# detect_os — sets OS_ID / OS_VERSION from os-release; refuses anything but
# Ubuntu 24.04 and Debian 13 (trixie). One installer, both paths: shared steps run
# for both and only package/repo/service-name differences branch on $OS_ID.
#   LARANODE_OS=ubuntu|debian   force the package path for a derivative whose
#                               os-release ID differs (the VERSION_ID must still be
#                               24.04 for ubuntu / 13 for debian).
#   LARANODE_OS_RELEASE_FILE    overrides /etc/os-release (tests).
detect_os() {
  local f="${LARANODE_OS_RELEASE_FILE:-/etc/os-release}"
  [ -r "$f" ] || die "Cannot read ${f} — unsupported OS (supported: Ubuntu 24.04, Debian 13)"
  OS_ID=$(. "$f" && echo "${ID:-unknown}")
  OS_VERSION=$(. "$f" && echo "${VERSION_ID:-unknown}")
  if [ -n "${LARANODE_OS:-}" ]; then
    case "$LARANODE_OS" in
      ubuntu|debian) OS_ID="$LARANODE_OS" ;;
      *) die "LARANODE_OS must be 'ubuntu' or 'debian' (got '${LARANODE_OS}')" ;;
    esac
  fi
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
# transaction would REMOVE any package, or UPGRADE a package that belongs to a host
# service stack — on EVERY host: an upgrade restarts the service, and a plain Ubuntu
# box can run nginx/PostgreSQL/sshd just as well as a Proxmox one. --no-upgrade also
# keeps apt from upgrading already-installed packages that are merely named on the
# command line. Stops apt -y from silently replacing Percona, CloudPanel's nginx/php,
# Proxmox packages, etc.
_PROTECTED_PKG_RE='^(apache2|libapache2-|proxmox-|pve-|libpve-|qemu-server|lxc-pve|percona-|mysql-|mariadb-|postgresql|libpq|cloudpanel|nginx|libnginx|php[0-9]+\.[0-9]+-|varnish|redis|docker|containerd|tailscale|ufw|openssh-server)'
apt_install() {
  local sim
  sim=$(apt-get install -s --no-upgrade -y "$@" 2>&1) \
    || die "apt-get simulation failed for: $* — ${sim}"
  local removals
  removals=$(printf '%s\n' "$sim" | grep '^Remv ' || true)
  [ -z "$removals" ] \
    || die "Refusing to install: $* — apt would REMOVE packages:"$'\n'"${removals}"
  local upgrades
  upgrades=$(printf '%s\n' "$sim" | grep -E '^Inst [^ ]+ \[' \
    | awk '{print $2}' | grep -E "$_PROTECTED_PKG_RE" || true)
  [ -z "$upgrades" ] \
    || die "Refusing to install: $* — apt would UPGRADE host-managed packages:"$'\n'"${upgrades}"
  # On a host that already runs services, any package's postinst (a library the install
  # pulls in, not only the named package) can try-restart them. The marked policy-rc.d guard
  # holds service starts back for the whole install, unless the caller installs a NEW service
  # that has to start (APT_ALLOW_SERVICE_START=1 apt_install ...). Nests with the guarded phases.
  local guarded=0 rc=0
  if [ "${APT_ALLOW_SERVICE_START:-0}" != 1 ] && [ -n "${PRE_UNITS:-}" ]; then
    _policy_guard_on; guarded=1
  fi
  apt-get install --no-upgrade -y "$@" || rc=$?
  [ "$guarded" = 0 ] || _policy_guard_off
  return "$rc"
}

# ------------------------------------------------------------------------------
# Phase 0 — Preflight: detect, resolve choices, print plan, confirm.
# NO mutations — apt/systemctl/file writes happen only in later phases.
# ------------------------------------------------------------------------------
preflight() {
  log "Preflight: surveying environment"

  # Port probing must work BEFORE the confirm prompt without touching apt: ss, or the
  # /proc/net/tcp fallback. Neither → refuse rather than install iproute2 unasked.
  _probe_available || die "Cannot read listening sockets: neither 'ss' nor /proc/net/tcp is available. Install iproute2 (apt-get install iproute2) and re-run."

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
    local _h80
    _h80=$(_port_holder 80 || true)
    case "$_h80" in
      *nginx*)  port80_holder="nginx" ;;
      *apache*|*httpd*) port80_holder="apache2" ;;
      *)        port80_holder="unknown" ;;
    esac
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
    *)     [[ "$_bind" =~ ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]] \
             || die "LARANODE_BIND must be all, local or an IPv4 address (octets 0-255), got: ${_bind}"
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
        die "Port ${HTTP_PORT} is reserved by Proxmox/SSH on this host — choose another LARANODE_HTTP_PORT." ;;
    esac
  fi
  # The panel's own Listen port must be free BEFORE Apache is touched. apachectl
  # configtest does not bind, so a busy port passes it; a graceful reload that then
  # cannot open the new listener can take a running Apache (and every live site on it)
  # down. :80 has its own rules just below. The one accepted holder is the panel's own
  # Apache vhost from a previous run.
  if [ "$HTTP_PORT" != 80 ] && port_in_use "$HTTP_PORT"; then
    local _busy_holder
    _busy_holder=$(_port_holder "$HTTP_PORT")
    if [ "$_busy_holder" = apache2 ] && _panel_vhost_enabled; then
      log "Port ${HTTP_PORT} is the panel's own Apache vhost from a previous run - reusing it"
    else
      die "Port ${HTTP_PORT} is already in use by ${_busy_holder}. Nothing was changed. Set LARANODE_HTTP_PORT to a free port and re-run."
    fi
  fi
  # An explicit :80 is honoured when Apache already holds it (re-run / shared Apache:
  # the panel just adds its vhost). Any other holder makes the install impossible.
  if [ "$port80_free" = 0 ] && [ "$HTTP_PORT" = 80 ] && [ "$port80_holder" != "apache2" ]; then
    die ":80 is held by ${port80_holder} — pick another LARANODE_HTTP_PORT."
  fi
  # A pre-existing Apache keeps its own 'Listen' lines (we only add to them). It
  # listens on every interface on :80, so the panel cannot also be narrowed to one
  # address on :80 — the two Listen lines would conflict and Apache would not start.
  if [ "$APACHE_OWNED" = 0 ] && [ "$HTTP_PORT" = 80 ] && [ -n "$BIND_ADDR" ]; then
    die "A pre-existing Apache owns :80 on every interface; the panel cannot be bound to ${BIND_ADDR}:80 beside it. Set LARANODE_HTTP_PORT to another port (e.g. 8080) or LARANODE_BIND=all."
  fi

  # A pre-existing but STOPPED apache2 / php8.4-fpm is someone else's service: refuse
  # now, before any change, unless the operator opted in to starting it.
  _refuse_stopped_preexisting

  # ---- Refuse impossible installs now, before any mutation ----------------------
  # (these used to abort halfway through the install, after packages were added)
  if [ "$DB_ENGINE" = pgsql ] && [ "${PG_PREEXISTING:-0}" -gt 0 ] && [ -z "${LARANODE_PG_PORT:-}" ]; then
    local _prev_pg_port=""
    if [ -f "${PANEL_PATH}/.env" ] && grep -q '^DB_CONNECTION="\?pgsql' "${PANEL_PATH}/.env"; then
      _prev_pg_port=$(grep -E '^DB_PORT=' "${PANEL_PATH}/.env" | cut -d= -f2- | tr -d "\"' " || true)
    fi
    [ -n "$_prev_pg_port" ] \
      || die "PostgreSQL cluster(s) already exist on this host. Set LARANODE_PG_PORT to the cluster the panel may use:"$'\n'"$(pg_lsclusters --no-header 2>/dev/null || true)"
  fi
  if have_cmd node; then
    local _node_major
    _node_major=$(node --version 2>/dev/null | sed 's/^v//; s/\..*//' || true)
    { [[ "$_node_major" =~ ^[0-9]+$ ]] && [ "$_node_major" -ge 20 ]; } \
      || die "The panel build needs Node >=20; found $(node --version 2>/dev/null || echo unknown). Install or upgrade Node and re-run."
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
  if [ "$APACHE_OWNED" = 0 ]; then
    _plan+=" · apache2: PRE-EXISTING, kept as is (panel vhost + Listen added, graceful reload; enables only the missing modules: $(_apache_modules))"
    if [ "$HTTP_PORT" = 80 ]; then
      warn "Sharing :80 with the existing Apache: the panel vhost (laranode.conf) has no ServerName, so a request with an unmatched Host or a bare IP goes to whichever vhost file loads FIRST. If your default vhost sorts BEFORE laranode.conf (e.g. 000-default.conf) the panel is NOT reachable by IP, only by a name you route to it. If it sorts AFTER (e.g. mysite.com.conf, zz-default.conf) the panel becomes the default vhost on :80 and hijacks your unmatched requests. Use LARANODE_HTTP_PORT=8080 to avoid both."
    fi
  fi
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
  apt_install git curl ca-certificates sudo openssl iproute2 gnupg
  # cron is a NEW service that has to run (the panel's scheduler); sysstat likewise below.
  APT_ALLOW_SERVICE_START=1 apt_install cron
  # add-apt-repository (ppa:ondrej/php) exists only on Ubuntu, and only the PPA
  # path needs it. Debian 13 ships php8.4 itself.
  if [ "$OS_ID" = ubuntu ] && [ "$IS_CLOUDPANEL" = 0 ]; then
    apt_install software-properties-common
  fi

  log "Installing sysstat"
  APT_ALLOW_SERVICE_START=1 apt_install sysstat
  systemctl enable sysstat
}

# ==============================================================================
# Phase 2 — Fetch the panel (user + clone)
# ==============================================================================

phase_fetch_panel() {
  log "Creating laranode_ln system user"
  useradd -m -s /bin/bash laranode_ln 2>/dev/null || true
  usermod -aG laranode_ln www-data
  # Debian's adduser default is 0755: close the home (and the .env built inside it)
  # to other local users from the start. phase_services settles the final modes.
  chmod 750 /home/laranode_ln

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
    APT_ALLOW_SERVICE_START=1 apt_install mysql-server   # a NEW service: it has to start
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
    # The password goes through the environment, never argv (visible in `ps`).
    export MYSQL_PWD="${root_pw}"
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
  # SQL arrives on stdin so the new password is not in argv either.
  mysql "${root_args[@]}" <<SQL || die "MySQL: failed to provision laranode user/database — see output above"
    CREATE USER IF NOT EXISTS 'laranode'@'localhost' IDENTIFIED BY '${db_pass}';
    ALTER  USER              'laranode'@'localhost' IDENTIFIED BY '${db_pass}';
    CREATE DATABASE IF NOT EXISTS laranode
           CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    GRANT ALL PRIVILEGES ON *.* TO 'laranode'@'localhost' WITH GRANT OPTION;
    FLUSH PRIVILEGES;
SQL
  unset MYSQL_PWD

  # ── Write .env (only after all DB ops succeeded) ─────────────────────────
  # phase_database runs before phase_app, so .env may not exist yet. Seed it
  # from .env.example first (full template) so env_set updates existing keys
  # instead of leaving a stub .env that phase_app would then preserve as-is.
  _seed_env
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
    if [ -n "${LARANODE_DATA_DIR:-}" ]; then
      apt_install postgresql-common
      local pgcc_conf="${LARANODE_PG_CREATECLUSTER_CONF:-/etc/postgresql-common/createcluster.conf}"
      mkdir -p "${LARANODE_DATA_DIR}"
      sed -i -E "/^[#[:space:]]*data_directory[[:space:]]*=/d" "$pgcc_conf"
      printf "data_directory = '%s/postgresql/%%v/%%c'\n" "${LARANODE_DATA_DIR%/}" \
        >> "$pgcc_conf"
      log "PostgreSQL data directory base: ${LARANODE_DATA_DIR%/}/postgresql/<ver>/<cluster>"
    fi
    APT_ALLOW_SERVICE_START=1 apt_install postgresql postgresql-client   # a NEW cluster: it has to start
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
  _seed_env

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

  # A pre-existing Apache keeps every Listen it had (its own :80, its :443 vhosts).
  # The panel only adds its own line; the live sites keep answering untouched.
  if [ "${APACHE_OWNED:-1}" = 0 ]; then
    if [ "$HTTP_PORT" -ne 80 ] && ! grep -qxE "[[:space:]]*Listen[[:space:]]+${_listen}[[:space:]]*" "$ports_conf"; then
      printf 'Listen %s\n' "${_listen}" >> "$ports_conf"
    fi
    return 0
  fi

  if [ "$HTTP_PORT" -ne 80 ] || [ -n "$BIND_ADDR" ]; then
    sed -i -E "/^[[:space:]]*Listen[[:space:]]+(80|(([0-9]{1,3}\.){3}[0-9]{1,3}:)?${HTTP_PORT})[[:space:]]*\$/d" "$ports_conf"
    printf 'Listen %s\n' "${_listen}" >> "$ports_conf"
  fi

  if [ "${IS_PROXMOX:-0}" = 1 ]; then
    # :443 is reserved on a Proxmox host (reverse proxies, tailnet serve): never grab it
    # with a wildcard listener, even while it happens to be free.
    sed -i -E 's/^([[:space:]]*)Listen[[:space:]]+443([[:space:]]+https)?[[:space:]]*$/\1# laranode: :443 reserved on Proxmox, disabled: Listen 443\2/' "$ports_conf"
  elif port_in_use 443 && [ "$(_port_holder 443)" != apache2 ]; then
    sed -i -E 's/^([[:space:]]*)Listen[[:space:]]+443([[:space:]]+https)?[[:space:]]*$/\1# laranode: :443 busy, disabled: Listen 443\2/' "$ports_conf"
    warn ":443 is in use on this host — Apache's 'Listen 443' disabled; panel stays HTTP-only (use the SSH tunnel)."
  elif [ -n "$BIND_ADDR" ]; then
    # A bound panel must not leave mod_ssl's wildcard :443 open to the network.
    sed -i -E "s/^([[:space:]]*)Listen[[:space:]]+443([[:space:]]+https)?[[:space:]]*\$/\1Listen ${BIND_ADDR}:443\2/" "$ports_conf"
  fi
}

# _refresh_service UNIT OWNED — apply new config to a unit. A unit this installer
# owns is restarted. A pre-existing one is NEVER restarted: a graceful reload keeps
# the main PID and drops no connection; a stopped one is only started.
_refresh_service() {
  local unit="$1" owned="$2"
  if [ "$owned" = 1 ]; then
    systemctl restart "$unit" || die "${unit} restart failed"
  elif svc_active "$unit"; then
    systemctl reload "$unit" || die "${unit} reload failed (pre-existing unit left running with its old config)"
  else
    systemctl start "$unit" || die "${unit} start failed"
  fi
}

# _disable_default_site — the stock 000-default site belongs to whoever configured
# the Apache; only an Apache this installer installed loses it.
_disable_default_site() {
  if [ "${APACHE_OWNED:-1}" = 1 ]; then
    a2dissite 000-default >/dev/null 2>&1 || true
  fi
  return 0
}

# _apache_modules — modules the panel vhost needs. A pre-existing Apache gets only
# what the panel vhost itself uses (proxy_fcgi for the PHP-FPM handler, rewrite for
# public/.htaccess); no mod_ssl (it would open a brand-new :443) and none of the
# extras (headers, setenvif, proxy_http), which would change every existing site.
# An Apache this installer installed gets the full set the panel's features use.
_apache_modules() {
  if [ "${APACHE_OWNED:-1}" = 0 ]; then
    echo "proxy proxy_fcgi rewrite"
  else
    echo "proxy_fcgi rewrite setenvif headers proxy proxy_http ssl"
  fi
}

# _vhost_render TEMPLATE DEST PORT DOCROOT — render the panel vhost. On a
# pre-existing Apache the PHP-FPM handler is set inside this vhost only: the global
# a2enconf php8.4-fpm would re-route .php for every existing site.
_vhost_render() {
  local tmpl="$1" dest="$2" port="$3" docroot="$4"
  sed -e "s|__PORT__|${port}|g" -e "s|__DOCROOT__|${docroot}|g" "$tmpl" > "$dest"
  if [ "${APACHE_OWNED:-1}" = 0 ]; then
    sed -i '/^<\/VirtualHost>/d' "$dest"
    cat >> "$dest" <<'VHOST'
    <FilesMatch ".+\.ph(?:ar|p|tml)$">
        SetHandler "proxy:unix:/run/php/php8.4-fpm.sock|fcgi://localhost"
    </FilesMatch>
</VirtualHost>
VHOST
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

# _apache_enable_modules — enable what the panel vhost needs. On a pre-existing Apache
# that is only the small set the panel itself uses, and only the modules not already
# on; whatever this installer switched on is recorded (APACHE_MODS_ENABLED, manifest).
APACHE_MODS_ENABLED=""
# Where the modules this installer enabled are persisted AT ONCE (the manifest is only
# written in the last phase, so a die in between would otherwise lose the record).
_apache_mods_state() { echo "${LARANODE_APACHE_MODS_STATE:-/etc/laranode/apache-modules-enabled}"; }
_apache_enable_modules() {
  local m st; st=$(_apache_mods_state)
  APACHE_MODS_ENABLED=""
  for m in $(_apache_modules); do
    a2query -m "$m" >/dev/null 2>&1 && continue
    a2enmod "$m" >/dev/null || die "a2enmod ${m} failed"
    # recorded one by one: a die in the middle of the loop still knows what is ours
    APACHE_MODS_ENABLED+="${APACHE_MODS_ENABLED:+ }${m}"
    mkdir -p "$(dirname "$st")"
    echo "$m" >> "$st"
  done
}

# ---- rollback of a pre-existing Apache -----------------------------------------------------
# Armed once the owner's files are snapshotted; runs on ANY later die (configtest, reload,
# "not active", "not listening", a2ensite, ...), so the owner's next reload/restart never trips
# over a Listen line, vhost or module we added. An Apache this installer installed is ours and
# is never rolled back.
#
# The snapshot is a JOURNAL on disk (LARANODE_ROLLBACK_DIR, default /etc/laranode/apache-rollback),
# written BEFORE the first change and removed on success. A SIGKILL / OOM / power loss cannot
# run the exit hook, so the next installer start finds the journal of a dead installer and rolls
# its changes back first (_apache_journal_recover); if that is not possible it refuses and says
# where the journal is. Files: pid, start (pid identity), apache_dir, vhost_dest, ports.conf (the original),
# vhost.orig (a previous panel vhost), vhost_enabled, mods.before (modules recorded before this run),
# was_active, reloaded, started_by_run (this run started a stopped Apache), complete.
_journal_dir() { echo "${LARANODE_ROLLBACK_DIR:-/etc/laranode/apache-rollback}"; }
_WB_ARMED=0
_apache_journal_open() {  # _apache_journal_open APACHE_DIR VHOST_DEST
  local j ad="$1" dest="$2"; j=$(_journal_dir)
  rm -rf "$j"; mkdir -p "$j"
  _installer_pid > "$j/pid"
  _installer_start > "$j/start"      # pid + start time: a reused pid is not this installer
  # The modules recorded BEFORE this run (an earlier run's, kept in the state file): a rollback
  # disables only what was enabled since this point, never an earlier run's modules.
  if [ -f "$(_apache_mods_state)" ]; then cp "$(_apache_mods_state)" "$j/mods.before"; else : > "$j/mods.before"; fi
  echo "$ad" > "$j/apache_dir"; echo "$dest" > "$j/vhost_dest"
  cp -p "${ad}/ports.conf" "$j/ports.conf"
  if [ -e "$dest" ]; then cp -p "$dest" "$j/vhost.orig"; fi
  if [ -e "${ad}/sites-enabled/laranode.conf" ]; then : > "$j/vhost_enabled"; fi
  if svc_active apache2; then : > "$j/was_active"; fi
  : > "$j/complete"      # a journal without this was cut short before any change: nothing to undo
}
_apache_commit() {
  _WB_ARMED=0
  rm -rf "$(_journal_dir)"
}
# _apache_rollback_journal — put the owner's Apache back from the journal. The journal is kept
# (return 1) when a restore failed, so the next start retries or refuses instead of forgetting.
_apache_rollback_journal() {
  local j ad dest m st rc=0 mods keep=""; j=$(_journal_dir); st=$(_apache_mods_state)
  [ -f "$j/complete" ] || { rm -rf "$j"; return 0; }
  ad=$(cat "$j/apache_dir"); dest=$(cat "$j/vhost_dest")
  cp -p "$j/ports.conf" "${ad}/ports.conf" || { warn "could not restore ${ad}/ports.conf from ${j}/ports.conf"; rc=1; }
  if [ -f "$j/vhost.orig" ]; then
    cp -p "$j/vhost.orig" "$dest" || { warn "could not restore ${dest} from ${j}/vhost.orig"; rc=1; }   # the previous working panel vhost
    [ -f "$j/vhost_enabled" ] || a2dissite laranode >/dev/null 2>&1 || true
  else
    a2dissite laranode >/dev/null 2>&1 || true
    rm -f "$dest"
  fi
  # modules THIS run switched on (recorded one by one in the state file, and not in the snapshot
  # taken when the journal opened), newest first (proxy_fcgi depends on proxy). An earlier run's
  # modules stay enabled and stay recorded: its vhost, restored just above, needs them.
  if [ -f "$st" ]; then
    mods=$(sed '/^$/d' "$st" | tac)
    for m in $mods; do
      if [ -f "$j/mods.before" ] && grep -qxF "$m" "$j/mods.before"; then keep+="${m}"$'\n'; continue; fi
      if a2dismod "$m" >/dev/null 2>&1; then :; else warn "could not disable module ${m}"; keep+="${m}"$'\n'; fi
    done
    if [ -n "$keep" ]; then printf '%s' "$keep" | tac > "$st"; else rm -f "$st"; fi
  fi
  APACHE_MODS_ENABLED=""
  # Put the running Apache back on the restored configuration, but only if it may have loaded
  # ours (the reload was reached). An Apache that was running before this run is NEVER stopped;
  # only one this run started is stopped again, and only when the journal says THIS run started
  # it (started_by_run): an Apache that is active now but was not started by this run (the owner,
  # or a boot, started it after a SIGKILL) is the owner's and is left running. The owner's stopped
  # Apache is never started.
  if [ -f "$j/was_active" ]; then
    if [ -f "$j/reloaded" ]; then
      systemctl reload apache2 || warn "apache2 reload after the rollback failed: check it before its next restart"
    fi
  elif [ -f "$j/started_by_run" ] && svc_active apache2; then
    systemctl stop apache2 || warn "could not stop the apache2 this run started"
  fi
  [ "$rc" = 0 ] || return 1
  rm -rf "$j"
}
_apache_rollback() {            # the exit hook of the running installer
  [ "$_WB_ARMED" = 1 ] || return 0
  _WB_ARMED=0
  warn "rolling back this run's changes to the pre-existing Apache"
  _apache_rollback_journal || warn "the rollback is incomplete: journal kept in $(_journal_dir)"
}
# _apache_journal_recover — run at start: a previous installer was killed (SIGKILL / OOM / power
# loss) between its first change to a pre-existing Apache and its end. Undo that first.
_apache_journal_recover() {
  local j pid start; j=$(_journal_dir)
  [ -d "$j" ] || return 0
  pid=$(cat "$j/pid" 2>/dev/null || true)
  start=$(cat "$j/start" 2>/dev/null || true)
  if [ -n "$pid" ] && [ "$pid" != "$(_installer_pid)" ] && _pid_alive "$pid" "$start"; then
    die "Another Laranode installer (pid ${pid}) is changing this host's Apache right now. Wait for it to finish, then re-run."
  fi
  warn "a previous Laranode install was killed while it was changing apache2: undoing its changes first (restoring ports.conf and the panel vhost from ${j}, disabling the modules it enabled)"
  _apache_rollback_journal || true
  [ ! -d "$j" ] || die "Could not undo a killed install's changes to apache2. The original ports.conf is ${j}/ports.conf: restore it by hand (and remove the Listen/vhost/modules that install added), delete ${j}, then re-run. Nothing else was changed."
}

phase_webserver() {
  log "Installing Apache Web Server"
  local ad; ad=$(_apache_dir)
  # Suppress service auto-start during apt: on a host where :80 is already held
  # (e.g. nginx) Apache's default 'Listen 80' would fail to bind and abort the
  # install under set -e. We configure ports first, then start Apache ourselves.
  # The guard is removed on success, die and signals; a policy-rc.d that is not ours is left alone.
  _policy_guard_on
  apt_install apache2
  apt_install certbot python3-certbot-apache
  _policy_guard_off

  [ -n "${HTTP_PORT:-}" ]  || die "HTTP_PORT not set — preflight must run first"
  [ -n "${PANEL_PATH:-}" ] || die "PANEL_PATH not set — preflight must run first"

  # Render the panel vhost from the template. NEVER writes 000-default.conf.
  local tmpl="${PANEL_PATH}/laranode-scripts/templates/apache-panel.template"
  local dest="${ad}/sites-available/laranode.conf"
  [ -f "$tmpl" ] || die "apache-panel.template missing at ${tmpl}"
  # A pre-existing Apache's own files are restored if anything below fails (modules
  # included, so the snapshot comes first): the next reload/restart by its owner must not
  # trip over a line we added.
  if [ "$APACHE_OWNED" = 0 ]; then
    # The snapshot is a journal on disk (also read by the next start after a SIGKILL); a
    # re-run's previously working panel vhost is part of it.
    _apache_journal_open "$ad" "$dest"
    _WB_ARMED=1
    _add_exit_hook _apache_rollback
  fi

  log "Enabling required Apache modules"
  _apache_enable_modules

  _vhost_render "$tmpl" "$dest" "$HTTP_PORT" "${PANEL_PATH}/public"

  # Panel never uses the stock default site (only an Apache we installed loses it).
  _disable_default_site

  _apache_ports_conf "${ad}/ports.conf"

  a2ensite laranode || die "a2ensite laranode failed"
  # A die from here on rolls a pre-existing Apache back (the EXIT hook armed above).
  apachectl configtest || die "Apache config test failed — review ${dest}"

  [ "$APACHE_OWNED" = 0 ] || systemctl enable apache2 >/dev/null 2>&1 || true
  # from here the running Apache may have loaded our config: a rollback must reload it back
  [ "$_WB_ARMED" = 0 ] || : > "$(_journal_dir)/reloaded"
  ( _refresh_service apache2 "$APACHE_OWNED" ) \
    || die "apache2 reload/start failed — the panel's changes to ${ad} were rolled back"
  # THIS run started a stopped pre-existing Apache (opt-in): record it, so a rollback or the next
  # start's recovery stops only an Apache that this run started, never one the owner started since.
  if [ "$_WB_ARMED" = 1 ] && [ ! -f "$(_journal_dir)/was_active" ]; then : > "$(_journal_dir)/started_by_run"; fi
  svc_active apache2 || die "apache2 is not active after (re)load — the panel's changes to ${ad} were rolled back (the running Apache keeps its previous configuration)"

  # Confirm the socket is open (full HTTP 200 check is phase_services, after the
  # app is bootstrapped). This surfaces port-fork bugs early.
  # A graceful reload returns before Apache has opened the new listener: wait for it.
  local _w
  for _w in $(seq 1 20); do
    ss -tlnH "( sport = :${HTTP_PORT} )" | grep -q . && break
    sleep 1
  done
  ss -tlnH "( sport = :${HTTP_PORT} )" | grep -q . \
    || die "Apache is not listening on :${HTTP_PORT} after (re)load (a pre-existing Apache is rolled back to its previous configuration)"

  _configure_firewall
  _apache_commit

  log "Apache panel vhost active on :${HTTP_PORT}"
}

# ==============================================================================
# Phase 5 — PHP 8.4, Node.js, Composer, PostgreSQL client
# ==============================================================================

# _install_php_packages PKG... — the php8.4 / extension install. On a host whose php8.4-fpm
# pre-dates this run, the package postinst scripts restart that live pool (verified: the
# pool's PID changes during the extension install), which the "never restart someone else's
# service" rule forbids. The marked policy-rc.d guard stops that; phase_services then
# reloads the pool, which is how it picks the new extensions up. When the installer installed
# php8.4-fpm itself there is nothing live to protect and no guard is used.
_install_php_packages() {
  if [ "${PHPFPM_OWNED:-1}" = 0 ]; then _policy_guard_on; fi
  apt_install "$@" || { _policy_guard_off; return 1; }
  _policy_guard_off
}

# _php_fpm_up — enable and start php8.4-fpm, but only when this installer installed
# it. A pre-existing php8.4-fpm keeps its boot state and its running process; the
# services phase reloads it (or, with LARANODE_START_STOPPED=1, starts it).
_php_fpm_up() {
  if [ "${PHPFPM_OWNED:-1}" = 1 ]; then
    log "Enabling PHP-FPM"
    systemctl enable php8.4-fpm || die "systemctl enable php8.4-fpm failed"
    systemctl start php8.4-fpm  || die "systemctl start php8.4-fpm failed"
  else
    log "Pre-existing php8.4-fpm: boot state and running process left as they are"
  fi
}

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
  _install_php_packages "${php_pkgs[@]}" || die "apt-get install php8.4 extensions failed"

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

  _php_fpm_up

  # php8.4-fpm package provides /etc/apache2/conf-available/php8.4-fpm.conf;
  # a2enconf must run after the package is installed.
  if [ "$APACHE_OWNED" = 0 ]; then
    # Pre-existing Apache: a global conf would route .php for ALL its sites through
    # php8.4-fpm. The panel vhost carries its own handler instead (_vhost_render).
    log "Pre-existing Apache: PHP-FPM handler set in the panel vhost only (no global a2enconf)"
  elif [ -f /etc/apache2/conf-available/php8.4-fpm.conf ]; then
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

# ── Root never executes PHP that lives in the panel tree ──────────────────────
# Laravel `require`s bootstrap/cache/*.php, config/, vendor/ ... on every artisan call, and
# composer runs the project's scripts. Part of the tree is writable by the web user
# (storage/), and in the old layout bootstrap/cache was too: PHP planted there by www-data
# would run as root on the next installer re-run. So composer and artisan run as the panel
# account (laranode_ln), in the panel directory, never as root.
_as_panel_user() {
  runuser -u laranode_ln -- env HOME=/home/laranode_ln COMPOSER_HOME=/home/laranode_ln/.composer "$@"
}
_artisan() { _as_panel_user /usr/bin/php8.4 artisan "$@"; }

# _prepare_panel_tree — before any PHP runs: the tree belongs to the panel account (a fresh
# `git clone` as root, or a legacy layout), and the generated bootstrap caches are not
# trusted: they are deleted and rebuilt by composer's package:discover.
_prepare_panel_tree() {
  local p="${PANEL_PATH}"
  chown -R -h laranode_ln:laranode_ln "$p"
  if [ -d "$p/bootstrap/cache" ] && [ ! -L "$p/bootstrap/cache" ]; then
    find "$p/bootstrap/cache" -maxdepth 1 -type f -name '*.php' -delete
    chmod 750 "$p/bootstrap/cache"
  fi
}

phase_app() {
  log "App provisioning"

  [ -f "${PANEL_PATH}/composer.json" ] \
    || die "composer.json not found at ${PANEL_PATH} — repo clone missing or PANEL_PATH wrong"
  cd "${PANEL_PATH}"
  _prepare_panel_tree

  log "Installing PHP dependencies (composer install)"
  _as_panel_user /usr/bin/php8.4 /usr/local/bin/composer install --no-interaction --optimize-autoloader

  # .env — copy example only when absent; never clobber existing config.
  if [ ! -f "${PANEL_PATH}/.env" ]; then
    _seed_env
    log ".env created from .env.example"
  else
    log ".env already present — preserving existing configuration"
  fi

  # APP_KEY — generate ONLY when absent/blank; never --force-rotate a valid key.
  if grep -q '^APP_KEY=base64:' "${PANEL_PATH}/.env"; then
    log "APP_KEY already set — preserving (idempotent re-run)"
  else
    log "APP_KEY not set — generating"
    _artisan key:generate --force
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

  # The scripts www-data may run as root live in a ROOT-OWNED copy, never in the panel
  # checkout (which laranode_ln writes). The panel finds them through .env.
  log "Installing the privileged scripts (root-owned) and sudoers drop-ins for www-data"
  _install_privileged_scripts
  _install_sudoers
  env_set LARANODE_BIN_PATH "${LN_LIB_DEST}/bin" "${PANEL_PATH}/.env"
  env_set LARANODE_TEMPLATES_PATH "${LN_LIB_DEST}/templates" "${PANEL_PATH}/.env"

  log "Running database migrations"
  _artisan migrate --force \
    || die "artisan migrate --force failed — verify DB_* in .env and phase_database logs"

  # One-time installs (idempotent: non-zero on re-run is expected/tolerated).
  _artisan storage:link 2>/dev/null || true
  _artisan reverb:install --no-interaction 2>/dev/null || true

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
  _artisan laranode:detect-gpu 2>/dev/null || true

  # First-run seed sentinel: seed ONLY when the users table is empty.
  log "Checking first-run seed sentinel (users table row count)"
  local user_count=1
  user_count="$(_artisan tinker --execute="echo App\\Models\\User::count();" 2>/dev/null | tail -1 | tr -d ' \r\n')" || user_count=1
  if [ "$user_count" = "0" ]; then
    log "Users table empty — running db:seed (first install)"
    _artisan db:seed --force || die "artisan db:seed --force failed"
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
# *_OWNED = 1 when this installer may restart the unit (it installed it, here or on a
# previous run). 0 = the package was there before us: its listeners, sites and
# running process are left alone (reload at most, never restart).
APACHE_OWNED=1; PHPFPM_OWNED=1
PANEL_DB_UNIT=""; PANEL_DB_MANAGED=0

# _prior_managed — units a previous run recorded as managed (re-run must not
# reclassify what we installed earlier as "pre-existing").
_prior_managed() {
  local mf="${LARANODE_MANIFEST_FILE:-/etc/laranode/service-manifest.json}"
  [ -f "$mf" ] || return 0
  grep '"managed":true' "$mf" | sed -n 's/.*"unit":"\([^"]*\)".*/\1/p' || true
}

# _unit_is_prior UNIT — a previous run of this installer marked UNIT managed:true.
_unit_is_prior() { _prior_managed | grep -qxF "$1"; }

# capture_preexisting — read-only snapshot taken in preflight, before any install.
capture_preexisting() {
  pkg_installed apache2   && PRE_APACHE=1 || PRE_APACHE=0
  pkg_installed php8.4-fpm && PRE_PHPFPM=1 || PRE_PHPFPM=0
  APACHE_OWNED=1; PHPFPM_OWNED=1
  # Ownership = the package was installed by this installer (absent before this run,
  # or recorded managed:true by an earlier run). A package that was already there is
  # the operator's, running or not: a stopped one may be a standby, a maintenance
  # switch-off or an on-demand service, and enabling/starting/reconfiguring it would
  # change what boots and what listens.
  if [ "$PRE_APACHE" = 1 ] && ! _unit_is_prior apache2.service; then APACHE_OWNED=0; fi
  if [ "$PRE_PHPFPM" = 1 ] && ! _unit_is_prior php8.4-fpm.service; then PHPFPM_OWNED=0; fi
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

# _apache_listen_conflicts — "PORT HOLDER" for every port in apache2's own ports.conf
# that another process already holds. Listen lines inside the ssl/gnutls IfModule
# blocks are skipped (they only apply when mod_ssl is enabled).
_apache_listen_conflicts() {
  local pc p
  pc="$(_apache_dir)/ports.conf"
  [ -f "$pc" ] || return 0
  for p in $(awk '/<IfModule[ \t]+[^>]*(ssl|gnutls)/ {skip=1} skip && /<\/IfModule>/ {skip=0; next}
                  !skip && /^[ \t]*Listen[ \t]/ {n=split($2, a, ":"); print a[n]}' "$pc" | sort -un); do
    if port_in_use "$p"; then echo "${p} $(_port_holder "$p")"; fi
  done
}

# _refuse_stopped_preexisting — a pre-existing apache2 / php8.4-fpm that is installed
# but NOT running can only be brought up by starting it, which this installer never
# does to someone else's service unless told to. Runs in preflight, before any change.
_refuse_stopped_preexisting() {
  local stopped=""
  if [ "$APACHE_OWNED" = 0 ] && ! svc_active apache2; then stopped+=" apache2"; fi
  if [ "$PHPFPM_OWNED" = 0 ] && ! svc_active php8.4-fpm; then stopped+=" php8.4-fpm"; fi
  [ -n "$stopped" ] || return 0
  # Starting a stopped apache2 whose own Listen port another service holds would fail
  # AFTER packages and the database were installed: say so now, whatever the opt-in.
  if [ "$APACHE_OWNED" = 0 ] && ! svc_active apache2; then
    local conflicts
    conflicts=$(_apache_listen_conflicts)
    [ -z "$conflicts" ] || die "apache2 is installed but stopped, and its own ports.conf Listen port(s) are held by other services: $(echo "$conflicts" | awk '{printf "%s (%s) ", $1, $2}'). It could not be started, and this installer does not edit someone else's Apache listeners. Free that port or change apache2's Listen yourself, then re-run. Nothing was changed."
  fi
  [ "${LARANODE_START_STOPPED:-0}" = 1 ] && return 0
  die "Installed but not running (present before this installer):${stopped}. The panel needs it running; this installer does not start, enable or reconfigure someone else's stopped service on its own. Start it yourself and re-run, or re-run with LARANODE_START_STOPPED=1 to let the installer start it (it is NOT enabled at boot, so it and the panel stay down after a reboot, and its own configuration is left as it is). Nothing was changed."
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

  # Apache modules this installer switched on (kept across re-runs, so an uninstall or
  # an audit still knows which ones are ours).
  local mods_prior="" mods_all m mods_json=""
  if [ -f "$mf" ]; then
    mods_prior=$(grep -o '"apache_modules_enabled":\[[^]]*\]' "$mf" | sed 's/^[^[]*\[//; s/\]$//' | tr -d '"' | tr ',' ' ' || true)
  fi
  # ... plus what the webserver phase persisted at once (covers a run that died before this point)
  local mods_state="" st; st=$(_apache_mods_state)
  [ ! -f "$st" ] || mods_state=$(cat "$st")
  mods_all=$(printf '%s\n' $mods_prior $mods_state ${APACHE_MODS_ENABLED:-} | sed '/^$/d' | sort -u)
  for m in $mods_all; do mods_json+="${mods_json:+,}\"${m}\""; done

  mkdir -p "$(dirname "$mf")"
  {
    printf '{"version":1,"generated":"%s","host":{"os":"%s %s","proxmox":%s,"cloudpanel":%s},' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$OS_ID" "$OS_VERSION" \
      "$([ "$IS_PROXMOX" = 1 ] && echo true || echo false)" \
      "$([ "$IS_CLOUDPANEL" = 1 ] && echo true || echo false)"
    printf '"db":{"engine":"%s","unit":"%s"},"apache_modules_enabled":[%s],\n"services":[\n' "${DB_ENGINE:-}" "$PANEL_DB_UNIT" "$mods_json"
    local i
    for i in "${!lines[@]}"; do
      printf '%s%s\n' "${lines[$i]}" "$([ "$i" -lt $((${#lines[@]} - 1)) ] && echo ,)"
    done
    printf ']}\n'
  } > "$mf"
  chmod 644 "$mf"
  rm -f "$st"      # the manifest is now the record
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

# ── Privileged scripts, sudoers, permissions ──────────────────────────────────
#
# Threat: www-data (the PHP user) runs scripts as root through sudo. If www-data, or
# laranode_ln (which www-data is grouped with), can write the script, its directory, a
# template it reads or a parent directory, www-data owns root. So:
#   * the scripts, their lib/ and templates/ are COPIED to LN_LIB_DEST, owned by root,
#     mode 755/644, and sudoers names files only inside it;
#   * the panel checkout stays laranode_ln's (that is how the panel is updated) but is not
#     group-writable: only storage/ is. .env is 640. Composer/artisan run as laranode_ln,
#     never as root (see _as_panel_user).
# Updating the scripts after a `git pull` is a deliberate root step:
#   sudo /usr/local/lib/laranode/bin/laranode-sync-scripts.sh      (see docs/security-sudo.md)
LN_LIB_DEST=/usr/local/lib/laranode

_install_privileged_scripts() {
  [ -f "${PANEL_PATH}/laranode-scripts/bin/laranode-sync-scripts.sh" ] \
    || die "laranode-sync-scripts.sh missing from ${PANEL_PATH}/laranode-scripts/bin"
  mkdir -p /usr/local/lib && chown root:root /usr/local/lib && chmod u=rwx,go=rx /usr/local/lib
  bash "${PANEL_PATH}/laranode-scripts/bin/laranode-sync-scripts.sh" "${PANEL_PATH}" \
    || die "could not install the privileged scripts into ${LN_LIB_DEST}"
}

_install_sudoers() {
  local drop
  for drop in laranode-panel laranode-cron laranode-runtimes laranode-ufw; do
    [ -f "/etc/sudoers.d/${drop}" ] || die "sudoers drop-in ${drop} was not installed"
    visudo -c -f "/etc/sudoers.d/${drop}" >/dev/null || die "sudoers drop-in ${drop} failed syntax check"
  done
  rm -f /etc/sudoers.d/laranode-postgres
}

_settle_permissions() {
  local h=/home/laranode_ln p="${PANEL_PATH}"
  mkdir -p "$h/logs"
  chown -R laranode_ln:laranode_ln "$h"
  # group (www-data) may read and traverse, never write
  find "$h" -type d -exec chmod 750 {} +
  find "$h" -type f -exec chmod 640 {} +
  # the web process writes inside the panel in ONE place (storage/) plus its own log dir.
  # bootstrap/cache is NOT web-writable: Laravel `require`s it on every artisan run, and the
  # caches are prebuilt by composer (package:discover) as the panel account.
  chmod 770 "$h/logs"
  find "$h/logs" -type f -exec chmod 660 {} +
  if [ -d "$p/storage" ]; then
    find "$p/storage" -type d -exec chmod 770 {} +
    find "$p/storage" -type f -exec chmod 660 {} +
  fi
  [ -f "$p/.env" ] && chmod 640 "$p/.env"
  # the source copy of the scripts is only ever read (by the root sync): keep it that way
  find "$p/laranode-scripts/bin" -type f -name '*.sh' -exec chmod 750 {} + 2>/dev/null || true
  # the root-owned copy
  if [ -d "${LN_LIB_DEST}" ]; then
    chown -R root:root "${LN_LIB_DEST}"
    chmod 755 "${LN_LIB_DEST}"
  fi
}

phase_services() {
  log "Installing systemd service units"
  cp "${PANEL_PATH}/laranode-scripts/templates/laranode-queue-worker.service" \
    /etc/systemd/system/laranode-queue-worker.service
  cp "${PANEL_PATH}/laranode-scripts/templates/laranode-reverb.service" \
    /etc/systemd/system/laranode-reverb.service

  log "Setting file permissions"
  _settle_permissions

  log "Enabling and starting services"
  systemctl daemon-reload
  _install_scheduler_cron
  systemctl enable --now cron
  systemctl enable laranode-queue-worker.service
  systemctl enable laranode-reverb.service
  systemctl start laranode-queue-worker.service
  systemctl start laranode-reverb.service
  _refresh_service apache2 "$APACHE_OWNED"
  _refresh_service php8.4-fpm "$PHPFPM_OWNED"
  write_service_manifest
  _install_sleep_wake
}

# _install_sleep_wake — optional service sleep/wake (OFF until an admin enables it on the
# Power page). Installs the sudoers drop-in and registers ONLY what the manifest above
# lists as managed:true, so pre-existing services are never manageable.
_install_sleep_wake() {
  local src="${LN_LIB_DEST}/etc/sudoers.d/laranode-sleep"
  if [ -f "$src" ] && visudo -c -f "$src" >/dev/null 2>&1; then
    install -o root -g root -m 440 "$src" /etc/sudoers.d/laranode-sleep
    bash "${LN_LIB_DEST}/bin/laranode-managed-register.sh" reverb queue fpm hostdb \
      || warn "sleep/wake registration failed; the feature stays unavailable"
    _reassert_sleep_wake
  else
    warn "laranode-sleep sudoers missing or failed syntax check; sleep/wake feature skipped"
  fi
}

# _reassert_sleep_wake — a re-run of the installer re-copies the unit templates and
# enables/starts reverb + queue (phase_services), which would silently undo sleep for every
# key an admin switched ON, and leave a drop-in pinned to the OLD ExecStart. For each key
# whose state says enabled=1, run `enable` again with its stored idle: the drop-in is
# re-rendered from the new unit file and the service goes back to sleep. Prior-state
# bookkeeping (was_enabled/was_active) is kept by the script, so a later disable still
# restores the original boot enablement. Best effort: a refusal only warns.
_reassert_sleep_wake() {
  local sleep_sh="${LN_LIB_DEST}/bin/laranode-sleep.sh"
  local dir="${LARANODE_MANAGED_DIR:-/etc/laranode}/sleep" k st idle
  [ -d "$dir" ] || return 0
  for k in reverb queue fpm hostdb; do
    st="${dir}/${k}.state"
    [ -f "$st" ] && grep -qx 'enabled=1' "$st" || continue
    idle="$(sed -n 's/^idle_minutes=//p' "$st" | head -1)"
    if [ "$k" = queue ]; then
      if bash "$sleep_sh" queue enable; then log "sleep/wake: re-applied sleep for queue"
      else warn "sleep/wake: could not re-apply sleep for queue after the re-run"; fi
    elif [[ "$idle" =~ ^[1-9][0-9]{0,3}$ ]]; then
      if bash "$sleep_sh" "$k" enable "$idle"; then log "sleep/wake: re-applied sleep for ${k} (${idle} min)"
      else warn "sleep/wake: could not re-apply sleep for ${k} after the re-run (toggle it on the Power page)"; fi
    else
      warn "sleep/wake: ${k} had sleep on but no stored idle minutes; toggle it again on the Power page"
    fi
  done
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
  echo "    cd ${PANEL_PATH} && sudo -u laranode_ln /usr/bin/php8.4 artisan laranode:create-admin"
  echo "========================================================================"
}

# ==============================================================================
# Entrypoint
# ==============================================================================

main() {
  # An unsupported OS is refused first. Nothing touches apt (no `apt-get update`, no package)
  # until the plan has been shown and confirmed: the preflight reads listeners with `ss`, or
  # /proc/net/tcp when iproute2 is absent. preflight runs detect_os again; it is a pure read.
  detect_os
  # A guard left by an installer that was killed (SIGKILL / OOM / power loss) would silently
  # stop every later package install on this host from starting services.
  _policy_guard_clean_stale
  # The same for a pre-existing Apache a killed installer left half-configured.
  _apache_journal_recover
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
