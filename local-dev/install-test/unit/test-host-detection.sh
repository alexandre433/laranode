#!/usr/bin/env bash
# local-dev/install-test/unit/test-host-detection.sh
# Host-only tests (no Docker, no root, ~1 s) for the OS / Proxmox / CloudPanel /
# Percona logic in laranode-installer.sh. Every external fact is stubbed through
# the installer's own helpers or the LARANODE_*_DIR / LARANODE_OS_RELEASE_FILE
# overrides, so the tests run the same on Git Bash, WSL and Linux.
set -uo pipefail
# The installer drops its test seams from the inherited environment unless this is set.
export LARANODE_INSTALLER_TEST=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${LARANODE_INSTALLER:-${SCRIPT_DIR}/../../../laranode-scripts/bin/laranode-installer.sh}"
FIX="${SCRIPT_DIR}/fixtures"

PASS=0; FAIL=0
pass()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
flunk() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
# t NAME CMD... — run CMD in a subshell, PASS when it exits 0
t() { local n="$1"; shift; if ( "$@" ) >/tmp/laranode-ut.$$ 2>&1; then pass "$n"; else flunk "$n"; sed 's/^/        /' /tmp/laranode-ut.$$; fi; }
# tf NAME CMD... — PASS when CMD exits non-zero (a refusal)
tf() { local n="$1"; shift; if ( "$@" ) >/tmp/laranode-ut.$$ 2>&1; then flunk "$n (expected refusal)"; else pass "$n"; fi; }
# tfm NAME MSG CMD...: refused AND by the guard under test (its message), not by a later step
tfm() { local n="$1" m="$2"; shift 2
  if ( "$@" ) >/tmp/laranode-ut.$$ 2>&1; then flunk "$n (expected refusal)"
  elif grep -qF -- "$m" /tmp/laranode-ut.$$; then pass "$n"
  else flunk "$n (refused, but not with '$m')"; sed 's/^/        /' /tmp/laranode-ut.$$; fi; }
trap 'rm -f /tmp/laranode-ut.$$' EXIT

# Common setup for each subshell: fresh installer, plain Ubuntu host, quiet logs.
base() {
  # shellcheck source=/dev/null
  source "$INSTALLER"
  export LARANODE_OS_RELEASE_FILE="${FIX}/os-release.ubuntu-24.04"
  export LARANODE_PVE_DIR=/nonexistent-pve LARANODE_CLP_DIR=/nonexistent-clp
  export LARANODE_UNATTENDED=1 LARANODE_REF=unit-test-ref   # preflight resolves the clone ref
  unset LARANODE_DB_ENGINE LARANODE_HTTP_PORT LARANODE_BIND LARANODE_PG_PORT
  have_cmd()    { return 1; }
  port_in_use() { return 1; }
  _probe_available() { return 0; }
  pkg_installed() { return 1; }
  pg_cluster_count() { echo 0; }
  _as_panel_user() { "$@"; }   # env_set/_seed_env edit AS laranode_ln (runuser): run as the test user here
  log() { :; }; warn() { :; }
}
expect() { [ "$2" = "$3" ] || { echo "expected $1='$3' got '$2'"; return 1; }; }

# ---- detect_os ---------------------------------------------------------------
echo "=== detect_os ==="
os_ok()  { base; export LARANODE_OS_RELEASE_FILE="${FIX}/os-release.$1"; detect_os; expect OS_ID "$OS_ID" "$2" && expect OS_VERSION "$OS_VERSION" "$3"; }
os_bad() { base; export LARANODE_OS_RELEASE_FILE="${FIX}/os-release.$1"; detect_os; }
t  "ubuntu 24.04 accepted"          os_ok ubuntu-24.04 ubuntu 24.04
t  "debian 13 accepted"             os_ok debian-13    debian 13
tf "debian 12 refused"              os_bad debian-12
tf "ubuntu 22.04 refused"           os_bad ubuntu-22.04
tf "alpine refused"                 os_bad alpine
tf "missing os-release refused"     bash -c "source '$INSTALLER'; LARANODE_OS_RELEASE_FILE=/nonexistent detect_os"
msg_names_supported() { out=$(bash -c "source '$INSTALLER'; LARANODE_OS_RELEASE_FILE='${FIX}/os-release.debian-12' detect_os" 2>&1 || true); echo "$out" | grep -q 'Ubuntu 24.04, Debian 13'; }
t  "refusal names the supported OSes" msg_names_supported

# ---- LARANODE_OS override + per-OS package branches --------------------------
echo "=== LARANODE_OS / OS branches ==="
os_override_ok()  { base; export LARANODE_OS_RELEASE_FILE="${FIX}/os-release.ubuntu-derivative" LARANODE_OS=ubuntu; detect_os; expect OS_ID "$OS_ID" ubuntu; }
os_derivative_no_override() { base; export LARANODE_OS_RELEASE_FILE="${FIX}/os-release.ubuntu-derivative"; detect_os; }
os_override_wrong_version() { base; export LARANODE_OS_RELEASE_FILE="${FIX}/os-release.ubuntu-derivative" LARANODE_OS=debian; detect_os; }
os_override_garbage()       { base; export LARANODE_OS=arch; detect_os; }
os_override_debian_on_debian() { base; export LARANODE_OS_RELEASE_FILE="${FIX}/os-release.debian-13" LARANODE_OS=debian; detect_os; expect OS_ID "$OS_ID" debian; }
t  "LARANODE_OS=ubuntu accepts an Ubuntu-24.04 derivative"        os_override_ok
tf "derivative refused without LARANODE_OS"                       os_derivative_no_override
tf "LARANODE_OS=debian on a 24.04 host refused (version must match)" os_override_wrong_version
tf "LARANODE_OS with an unknown value refused"                    os_override_garbage
t  "LARANODE_OS equal to the detected OS is a no-op"              os_override_debian_on_debian
pk_run() {  # pk_run <os-release fixture> -> APT_CALLS holds every apt_install call
  base; export LARANODE_OS_RELEASE_FILE="${FIX}/os-release.$1"; detect_os; detect_proxmox; detect_cloudpanel
  APT_CALLS=$(mktemp); apt_install() { echo "$*" >> "$APT_CALLS"; }; apt-get() { :; }; systemctl() { :; }
  phase_packages >/dev/null 2>&1
}
pk_ubuntu_has_ppa_tool() { pk_run ubuntu-24.04; grep -qx 'software-properties-common' "$APT_CALLS"; }
pk_debian_no_ppa_tool()  { pk_run debian-13;    ! grep -q 'software-properties-common' "$APT_CALLS" && grep -q '^git ' "$APT_CALLS"; }
t "ubuntu path installs software-properties-common (ondrej PPA tool)" pk_ubuntu_has_ppa_tool
t "debian path skips it (native php8.4) but shares the base tool set"  pk_debian_no_ppa_tool

# ---- Proxmox / CloudPanel markers -------------------------------------------
echo "=== host markers ==="
pve_cmd()  { base; have_cmd() { [ "$1" = pveversion ]; }; detect_proxmox; expect IS_PROXMOX "$IS_PROXMOX" 1; }
pve_dir()  { base; d=$(mktemp -d); export LARANODE_PVE_DIR="$d"; detect_proxmox; rmdir "$d"; expect IS_PROXMOX "$IS_PROXMOX" 1; }
pve_none() { base; detect_proxmox; expect IS_PROXMOX "$IS_PROXMOX" 0; }
t "pveversion present -> Proxmox"          pve_cmd
t "/etc/pve dir present -> Proxmox"        pve_dir
t "plain host -> not Proxmox"              pve_none
clp_pkg()  { base; pkg_installed() { [ "$1" = cloudpanel ]; }; detect_cloudpanel; expect IS_CLOUDPANEL "$IS_CLOUDPANEL" 1; }
clp_cmd()  { base; have_cmd() { [ "$1" = clpctl ]; }; detect_cloudpanel; expect IS_CLOUDPANEL "$IS_CLOUDPANEL" 1; }
clp_dir()  { base; d=$(mktemp -d); export LARANODE_CLP_DIR="$d"; detect_cloudpanel; rmdir "$d"; expect IS_CLOUDPANEL "$IS_CLOUDPANEL" 1; }
clp_none() { base; detect_cloudpanel; expect IS_CLOUDPANEL "$IS_CLOUDPANEL" 0; }
t "cloudpanel package -> CloudPanel"       clp_pkg
t "clpctl binary -> CloudPanel"            clp_cmd
t "/home/clp dir -> CloudPanel"            clp_dir
t "plain host -> not CloudPanel"           clp_none

# ---- mysql_server_pkg (Percona / MariaDB / MySQL) ---------------------------
echo "=== mysql_server_pkg ==="
mp_percona() { base; pkg_installed() { [ "$1" = percona-server-server ]; }; expect pkg "$(mysql_server_pkg)" percona-server-server; }
mp_maria()   { base; pkg_installed() { [ "$1" = mariadb-server ]; }; expect pkg "$(mysql_server_pkg)" mariadb-server; }
mp_none()    { base; expect pkg "$(mysql_server_pkg)" ""; }
t "Percona detected by package name"   mp_percona
t "MariaDB detected by package name"   mp_maria
t "no MySQL-family package -> empty"   mp_none

# ---- preflight: engine / bind / ports per host -------------------------------
echo "=== preflight per host ==="
pf_debian_default() { base; export LARANODE_OS_RELEASE_FILE="${FIX}/os-release.debian-13"; preflight; expect DB_ENGINE "$DB_ENGINE" pgsql; }
pf_debian_mysql()   { base; export LARANODE_OS_RELEASE_FILE="${FIX}/os-release.debian-13" LARANODE_DB_ENGINE=mysql; preflight; }
pf_debian_mysql_with_percona() { base; export LARANODE_OS_RELEASE_FILE="${FIX}/os-release.debian-13" LARANODE_DB_ENGINE=mysql; pkg_installed() { [ "$1" = percona-server-server ]; }; preflight; }
pf_ubuntu_default() { base; preflight; expect DB_ENGINE "$DB_ENGINE" mysql && expect BIND_ADDR "$BIND_ADDR" "" && expect HTTP_PORT "$HTTP_PORT" 80 && expect REVERB_PORT "$REVERB_PORT" 8080; }
t  "debian 13 defaults to pgsql"                      pf_debian_default
tf "debian 13 + mysql engine refused"                 pf_debian_mysql
t  "debian + mysql allowed when Percona is installed" pf_debian_mysql_with_percona
t  "ubuntu plain host: mysql, all interfaces, :80, reverb 8080" pf_ubuntu_default

pf_pve_bind()    { base; have_cmd() { [ "$1" = pveversion ]; }; preflight; expect IS_PROXMOX "$IS_PROXMOX" 1 && expect BIND_ADDR "$BIND_ADDR" 127.0.0.1; }
pf_pve_all()     { base; have_cmd() { [ "$1" = pveversion ]; }; export LARANODE_BIND=all; preflight; expect BIND_ADDR "$BIND_ADDR" ""; }
pf_pve_ip()      { base; have_cmd() { [ "$1" = pveversion ]; }; export LARANODE_BIND=100.102.0.53; preflight; expect BIND_ADDR "$BIND_ADDR" 100.102.0.53; }
pf_pve_8006()    { base; have_cmd() { [ "$1" = pveversion ]; }; port_in_use() { [ "$1" = 80 ]; }; export LARANODE_HTTP_PORT=8006; preflight; }
pf_pve_443()     { base; have_cmd() { [ "$1" = pveversion ]; }; export LARANODE_HTTP_PORT=443; preflight; }
pf_pve_3128()    { base; have_cmd() { [ "$1" = pveversion ]; }; export LARANODE_HTTP_PORT=3128; preflight; }
pf_pve_ok_port() { base; have_cmd() { [ "$1" = pveversion ]; }; export LARANODE_HTTP_PORT=8088; preflight; expect HTTP_PORT "$HTTP_PORT" 8088; }
pf_bad_bind()    { base; export LARANODE_BIND="not-an-ip"; preflight; }
pf_bad_port()    { base; export LARANODE_HTTP_PORT=abc; preflight; }
t  "Proxmox host binds 127.0.0.1 by default"      pf_pve_bind
t  "Proxmox host: LARANODE_BIND=all honored"      pf_pve_all
t  "Proxmox host: LARANODE_BIND=<ip> honored"     pf_pve_ip
tf "Proxmox host refuses panel port 8006"         pf_pve_8006
tf "Proxmox host refuses panel port 443"          pf_pve_443
tf "Proxmox host refuses panel port 3128"         pf_pve_3128
t  "Proxmox host accepts a free panel port"       pf_pve_ok_port
tf "invalid LARANODE_BIND refused"                pf_bad_bind
tf "non-numeric LARANODE_HTTP_PORT refused"       pf_bad_port

pf_clp_port()   { base; d=$(mktemp -d); export LARANODE_CLP_DIR="$d"; port_in_use() { [ "$1" = 80 ]; }; preflight; rmdir "$d"; expect HTTP_PORT "$HTTP_PORT" 8090; }
pf_clp_reverb() { base; d=$(mktemp -d); export LARANODE_CLP_DIR="$d"; port_in_use() { [ "$1" = 80 ]; }; preflight; rmdir "$d"; expect REVERB_PORT "$REVERB_PORT" 8081; }
pf_clp_bind()   { base; d=$(mktemp -d); export LARANODE_CLP_DIR="$d"; port_in_use() { [ "$1" = 80 ]; }; preflight; rmdir "$d"; expect BIND_ADDR "$BIND_ADDR" 127.0.0.1; }
pf_plain_80busy() { base; port_in_use() { [ "$1" = 80 ]; }; preflight; expect HTTP_PORT "$HTTP_PORT" 8080 && expect REVERB_PORT "$REVERB_PORT" 8081; }
pf_8080_busy()  { base; port_in_use() { [ "$1" = 8080 ]; }; preflight; expect HTTP_PORT "$HTTP_PORT" 80 && expect REVERB_PORT "$REVERB_PORT" 8081; }
t "CloudPanel + :80 busy -> panel on 8090 (never 8080, Varnish backend)" pf_clp_port
t "CloudPanel host -> Reverb 8081"                pf_clp_reverb
t "CloudPanel host binds 127.0.0.1 by default"    pf_clp_bind
t "plain host + :80 busy -> 8080 and Reverb 8081" pf_plain_80busy
t ":8080 held by another service -> Reverb 8081"  pf_8080_busy
pf_80_explicit_apache() { base; port_in_use() { [ "$1" = 80 ]; }; ss() { echo 'LISTEN 0 511 *:80 *:* users:(("apache2",pid=1,fd=4))'; }; export LARANODE_HTTP_PORT=80; preflight; expect HTTP_PORT "$HTTP_PORT" 80; }
pf_80_explicit_nginx()  { base; port_in_use() { [ "$1" = 80 ]; }; ss() { echo 'LISTEN 0 511 *:80 *:* users:(("nginx",pid=1,fd=4))'; }; export LARANODE_HTTP_PORT=80; preflight; }
t  "explicit LARANODE_HTTP_PORT=80 kept when Apache already holds :80 (re-run)" pf_80_explicit_apache
tf "explicit LARANODE_HTTP_PORT=80 refused when nginx holds :80"                pf_80_explicit_nginx

# ---- apt_install: refuses removals / host-stack upgrades --------------------
echo "=== apt_install guard ==="
# Each test sets SIM (what `apt-get -s` prints) and a host type, then runs apt_install
# in a nested subshell (die exits). A refusal must (a) print the guard's message and
# (b) never reach the real `apt-get install`. A pass-through must reach it.
apt_run() {  # apt_run "<sim output>" -> sets OUT, REAL(0/1)
  SIMOUT="$1"; CALLS=$(mktemp)
  OUT=$( (
    apt-get() { if [ "$2" = "-s" ]; then printf '%s\n' "$SIMOUT"; else echo REAL >> "$CALLS"; fi; }
    apt_install apache2
  ) 2>&1 ) || true
  REAL=0; grep -q REAL "$CALLS" && REAL=1
  return 0
}
apt_refused() { [ "$REAL" = 0 ] && printf '%s' "$OUT" | grep -q "Refusing to install"; }
apt_passed()  { [ "$REAL" = 1 ] && ! printf '%s' "$OUT" | grep -q "Refusing"; }
apt_removal()     { base; apt_run $'Remv percona-server-server [8.4.7]\nInst mysql-server (8.0 Ubuntu)'; apt_refused && printf '%s' "$OUT" | grep -q percona-server-server; }
apt_upgrade_clp() { base; IS_CLOUDPANEL=1; apt_run 'Inst nginx-common [1.28.0-1+clp-noble] (1.29 Ubuntu)'; apt_refused && printf '%s' "$OUT" | grep -q nginx-common; }
apt_upgrade_pve() { base; IS_PROXMOX=1;    apt_run 'Inst pve-manager [9.2.21] (9.3.0 Proxmox)'; apt_refused && printf '%s' "$OUT" | grep -q pve-manager; }
apt_benign_upgrade_clp() { base; IS_CLOUDPANEL=1; apt_run $'Inst libcurl4 [8.5.0] (8.5.1 Ubuntu)\nInst apache2 (2.4 Ubuntu)'; apt_passed; }
apt_new_install_clp()    { base; IS_CLOUDPANEL=1; apt_run 'Inst apache2 (2.4 Ubuntu)'; apt_passed; }
apt_sim_fails() {
  base; CALLS=$(mktemp)
  OUT=$( ( apt-get() { [ "$2" = "-s" ] && return 100; echo REAL >> "$CALLS"; }; apt_install no-such-package ) 2>&1 ) || true
  ! grep -q REAL "$CALLS" && printf '%s' "$OUT" | grep -q 'simulation failed'
}
t "apt_install refuses when apt would REMOVE a package (no real install)"           apt_removal
t "CloudPanel host: refuses when apt would UPGRADE nginx (no real install)"         apt_upgrade_clp
t "Proxmox host: refuses when apt would UPGRADE pve-manager (no real install)"      apt_upgrade_pve
t "CloudPanel host: unrelated library upgrade passes through"                       apt_benign_upgrade_clp
t "CloudPanel host: fresh install of a new package passes through"                  apt_new_install_clp
t "apt_install refuses when the simulation fails (unknown package)"                 apt_sim_fails

# ---- MySQL branch must not install over Percona ------------------------------
echo "=== _mysql_branch ==="
mysql_over_percona() {
  base
  PANEL_PATH=$(mktemp -d); : > "$PANEL_PATH/.env.example"
  APT_CALLS=$(mktemp)
  apt_install() { echo "$*" >> "$APT_CALLS"; }
  mysql_server_pkg() { echo percona-server-server; }
  systemctl() { return 0; }
  mysql() { return 0; }
  openssl() { echo secretpw; }
  persist_secret() { :; }
  _mysql_branch
  if grep -q 'mysql-server' "$APT_CALLS"; then echo "apt_install mysql-server was called:"; cat "$APT_CALLS"; return 1; fi
  grep -q '^DB_CONNECTION="mysql"$' "$PANEL_PATH/.env"
}
mysql_fresh_installs() {
  base
  PANEL_PATH=$(mktemp -d); : > "$PANEL_PATH/.env.example"
  APT_CALLS=$(mktemp)
  apt_install() { echo "$*" >> "$APT_CALLS"; }
  systemctl() { return 0; }
  mysql() { return 0; }
  openssl() { echo secretpw; }
  persist_secret() { :; }
  _mysql_branch
  grep -q '^mysql-server$' "$APT_CALLS"
}
t "Percona present: mysql-server is NOT installed, panel DB still provisioned" mysql_over_percona
t "no MySQL-family server: mysql-server is installed (baseline unchanged)"     mysql_fresh_installs

# ---- PostgreSQL branch must not pick/alter an existing cluster ---------------
echo "=== _pgsql_branch ==="
pg_stubs() {
  base
  PANEL_PATH=$(mktemp -d); : > "$PANEL_PATH/.env.example"
  APT_CALLS=$(mktemp)
  apt_install() { echo "$*" >> "$APT_CALLS"; }
  pg_lsclusters() { echo "16 main 5432 online postgres /var/lib/postgresql/16/main /var/log/postgresql/postgresql-16-main.log"; }
  have_cmd() { [ "$1" = pg_lsclusters ]; }
  systemctl() { return 0; }
  openssl() { echo secretpw; }
  persist_secret() { :; }
  sudo() { echo "SUDO_CALLED $*" >> "$APT_CALLS"; return 0; }
}
pg_existing_needs_port() { pg_stubs; PG_PREEXISTING=1; _pgsql_branch; }
# die() exits, so run the branch in a nested subshell and inspect the call log after.
pg_existing_no_server_install() {
  pg_stubs; PG_PREEXISTING=1
  ( _pgsql_branch ) >/dev/null 2>&1 || true
  ! grep -qE '^postgresql( |$)' "$APT_CALLS" && grep -q '^postgresql-client$' "$APT_CALLS" && ! grep -q SUDO_CALLED "$APT_CALLS"
}
pg_fresh_installs_server() {
  pg_stubs; PG_PREEXISTING=0
  ( _pgsql_branch ) >/dev/null 2>&1 || true
  grep -q '^postgresql postgresql-client$' "$APT_CALLS"
}
pg_datadir_config() {
  pg_stubs; PG_PREEXISTING=0
  conf=$(mktemp); printf '#data_directory = "ConfigDir"\n' > "$conf"
  export LARANODE_PG_CREATECLUSTER_CONF="$conf" LARANODE_DATA_DIR="$(mktemp -d)/pgdata/"
  ( _pgsql_branch ) >/dev/null 2>&1 || true
  grep -qxF "data_directory = '${LARANODE_DATA_DIR%/}/postgresql/%v/%c'" "$conf" \
    && [ "$(grep -c data_directory "$conf")" = 1 ] \
    && [ "$(sed -n 1p "$APT_CALLS")" = postgresql-common ] \
    && grep -q '^postgresql postgresql-client$' "$APT_CALLS"
}
tf "existing cluster, no LARANODE_PG_PORT: refuses to pick one"             pg_existing_needs_port
t  "existing cluster: server package untouched, no psql/sudo executed"      pg_existing_no_server_install
t  "fresh host: postgresql server + client installed"                       pg_fresh_installs_server
t  "LARANODE_DATA_DIR: createcluster.conf written, common installed first" pg_datadir_config

# ---- ports.conf rewrite ------------------------------------------------------
echo "=== _apache_ports_conf ==="
ports_run() { base; p=$(mktemp); cp "${FIX}/ports.conf" "$p"; "$@"; }
ports_default_80() { ports_run :; HTTP_PORT=80 BIND_ADDR=""; _apache_ports_conf "$p"; diff -q "$p" "${FIX}/ports.conf" >/dev/null; }
ports_8080() { ports_run :; HTTP_PORT=8080 BIND_ADDR=""; _apache_ports_conf "$p"; grep -qxE 'Listen 8080' "$p" && ! grep -qxE 'Listen 80' "$p"; }
ports_bound_80() { ports_run :; HTTP_PORT=80 BIND_ADDR=127.0.0.1; _apache_ports_conf "$p"; grep -qxE 'Listen 127.0.0.1:80' "$p" && ! grep -qxE 'Listen 80' "$p"; }
ports_bound_8090() { ports_run :; HTTP_PORT=8090 BIND_ADDR=127.0.0.1; _apache_ports_conf "$p"; grep -qxE 'Listen 127.0.0.1:8090' "$p" && ! grep -qxE 'Listen (80|8090)' "$p"; }
ports_idempotent() { ports_run :; HTTP_PORT=8090 BIND_ADDR=127.0.0.1; _apache_ports_conf "$p"; _apache_ports_conf "$p"; [ "$(grep -c 'Listen 127.0.0.1:8090' "$p")" = 1 ]; }
ports_443_busy() { ports_run :; HTTP_PORT=8080 BIND_ADDR=""; port_in_use() { [ "$1" = 443 ]; }; ss() { return 1; }; _apache_ports_conf "$p"; ! grep -qE '^[[:space:]]*Listen 443' "$p" && grep -q 'laranode: :443 busy' "$p"; }
ports_443_free() { ports_run :; HTTP_PORT=8080 BIND_ADDR=""; _apache_ports_conf "$p"; [ "$(grep -cE '^[[:space:]]*Listen 443' "$p")" = 2 ]; }
ports_443_own() { ports_run :; HTTP_PORT=8080 BIND_ADDR=""; port_in_use() { [ "$1" = 443 ]; }; ss() { echo 'LISTEN 0 511 *:443 *:* users:(("apache2",pid=1,fd=4))'; }; _apache_ports_conf "$p"; [ "$(grep -cE '^[[:space:]]*Listen 443' "$p")" = 2 ]; }
t "port 80, all interfaces: ports.conf untouched"                ports_default_80
t "port 8080: only 'Listen 8080' remains (no wildcard :80)"      ports_8080
t "bound local on :80: 'Listen 127.0.0.1:80' only"               ports_bound_80
t "bound local on :8090: single address-scoped Listen"           ports_bound_8090
t "re-run does not duplicate the Listen line"                    ports_idempotent
t ":443 held by another service: 'Listen 443' disabled"          ports_443_busy
t ":443 free: Apache's own 'Listen 443' kept"                    ports_443_free
t ":443 held by Apache itself (re-run): 'Listen 443' kept"       ports_443_own
ports_443_pve_free() { ports_run :; HTTP_PORT=80 BIND_ADDR=127.0.0.1; IS_PROXMOX=1; _apache_ports_conf "$p"; ! grep -qE '^[[:space:]]*Listen 443' "$p" && grep -q 'reserved on Proxmox' "$p"; }
t ":443 free on a Proxmox host: 'Listen 443' still disabled (reserved)" ports_443_pve_free

# ---- firewall policy ---------------------------------------------------------
echo "=== _configure_firewall ==="
fw_run() { base; UFW_CALLS=$(mktemp); ufw() { echo "ufw $*" >> "$UFW_CALLS"; }; HTTP_PORT=80; REVERB_PORT=8080; BIND_ADDR=""; "$@"; }
fw_pve()    { fw_run :; have_cmd() { return 0; }; IS_PROXMOX=1; _configure_firewall; [ ! -s "$UFW_CALLS" ]; }
fw_clp()    { fw_run :; have_cmd() { return 0; }; IS_CLOUDPANEL=1; _configure_firewall; [ ! -s "$UFW_CALLS" ]; }
fw_bound()  { fw_run :; have_cmd() { return 0; }; BIND_ADDR=127.0.0.1; _configure_firewall; [ ! -s "$UFW_CALLS" ]; }
fw_plain()  { fw_run :; have_cmd() { [ "$1" = ufw ]; }; HTTP_PORT=8080; REVERB_PORT=8081; _configure_firewall; grep -q 'ufw allow 8080' "$UFW_CALLS" && grep -q 'ufw allow 8081' "$UFW_CALLS" && grep -q 'ufw allow 22' "$UFW_CALLS"; }
fw_no_ufw() { fw_run :; _configure_firewall; [ ! -s "$UFW_CALLS" ]; }
t "Proxmox host: no ufw rule is ever added"            fw_pve
t "CloudPanel host: no ufw rule is ever added"         fw_clp
t "bound panel: no ufw rule is added"                  fw_bound
t "plain public host: ufw allow panel/reverb/443/22"   fw_plain
t "ufw absent: nothing runs (warning only)"            fw_no_ufw

# ---- scheduler cron ----------------------------------------------------------
echo "=== scheduler cron ==="
TPL_SRC="${SCRIPT_DIR}/../../../laranode-scripts/templates/laranode-schedule.cron"
cron_setup() { base; PANEL_PATH=$(mktemp -d); LN_LIB_DEST=$(mktemp -d); mkdir -p "$LN_LIB_DEST/templates"; cp "$TPL_SRC" "$LN_LIB_DEST/templates/"; export LARANODE_CRON_DIR=$(mktemp -d); }
cron_renders() {
  cron_setup; _install_scheduler_cron
  line=$(grep -v '^#' "$LARANODE_CRON_DIR/laranode-schedule")
  [ "$line" = "* * * * * laranode_ln /usr/bin/php8.4 ${PANEL_PATH}/artisan schedule:run >> /dev/null 2>&1" ] \
    || { echo "got: $line"; return 1; }
  ! grep -q '__' "$LARANODE_CRON_DIR/laranode-schedule"
}
cron_missing_tpl() { cron_setup; rm "$LN_LIB_DEST/templates/laranode-schedule.cron"; _install_scheduler_cron; }
cron_filename_ok() { cron_setup; _install_scheduler_cron; case "$(ls "$LARANODE_CRON_DIR")" in *.*) return 1;; esac; }   # cron ignores names with dots
cron_wired() { base; # phase_services must call it, and phase_packages must install the cron daemon
  body=$(declare -f phase_services); case "$body" in *_install_scheduler_cron*) ;; *) echo "phase_services does not install scheduler"; return 1;; esac
  declare -f phase_packages | grep -qE 'apt_install .*\bcron\b'
}
t  "cron.d line uses installer user, php8.4 and panel path"        cron_renders
tf "missing cron template aborts the install"                       cron_missing_tpl
t  "cron.d file name has no dot (cron would ignore it)"             cron_filename_ok
t  "phase_services wires the scheduler; phase_packages installs cron" cron_wired

# ---- service manifest --------------------------------------------------------
echo "=== service manifest ==="
mf_setup() { base; export LARANODE_MANIFEST_FILE="$(mktemp -d)/etc/service-manifest.json"; OS_ID=debian OS_VERSION=13; IS_PROXMOX=1 IS_CLOUDPANEL=0; DB_ENGINE=pgsql; PRE_APACHE=0 PRE_PHPFPM=0 PRE_UNITS="" PANEL_DB_UNIT="" PANEL_DB_MANAGED=0; }
mf_line() { grep -F "\"unit\":\"$1\"" "$LARANODE_MANIFEST_FILE"; }   # the one line for a unit
mf_managed()  { mf_line "$1" | grep -q '"managed":true'; }
mf_left_alone() { mf_line "$1" | grep -q '"managed":false'; }
mf_valid_json() { if command -v jq >/dev/null 2>&1; then jq -e . "$LARANODE_MANIFEST_FILE" >/dev/null; else echo "(jq absent: skipped)"; fi; }
mf_fresh() {
  mf_setup; PANEL_DB_UNIT=postgresql@17-main.service PANEL_DB_MANAGED=1
  write_service_manifest; mf_valid_json
  for u in laranode-reverb.service laranode-queue-worker.service apache2.service php8.4-fpm.service postgresql@17-main.service; do mf_managed $u || { echo "$u not managed"; return 1; }; done
}
mf_preexisting_left_alone() {
  mf_setup; PRE_APACHE=1 PRE_PHPFPM=1 PANEL_DB_UNIT=mariadb.service PANEL_DB_MANAGED=0
  PRE_UNITS=$'nginx.service\nredis-server.service\npostgresql@16-main.service\nclp-agent.service\nmysql.service'
  write_service_manifest; mf_valid_json
  for u in apache2.service php8.4-fpm.service mariadb.service nginx.service redis-server.service postgresql@16-main.service clp-agent.service mysql.service; do mf_left_alone $u || { echo "$u should be managed:false"; return 1; }; done
  mf_managed laranode-reverb.service && mf_managed laranode-queue-worker.service
}
mf_never_double_listed() { mf_setup; PRE_UNITS=$'apache2.service\nlaranode-reverb.service'; write_service_manifest; [ "$(grep -c '"unit":"apache2.service"' "$LARANODE_MANIFEST_FILE")" = 1 ] && [ "$(grep -c '"unit":"laranode-reverb.service"' "$LARANODE_MANIFEST_FILE")" = 1 ] && mf_managed laranode-reverb.service; }
mf_rerun_keeps_ownership() {   # run 1 installs apache; run 2 sees it "pre-existing" but it is still ours
  mf_setup; write_service_manifest
  PRE_APACHE=1 PRE_PHPFPM=1 PRE_UNITS=$'apache2.service\nphp8.4-fpm.service'; write_service_manifest
  mf_managed apache2.service && mf_managed php8.4-fpm.service
}
mf_rerun_never_adopts() {   # a unit once recorded as left-alone must not become managed on re-run
  mf_setup; PRE_APACHE=1; PANEL_DB_UNIT=mysql.service; write_service_manifest
  PRE_APACHE=1; write_service_manifest
  mf_left_alone apache2.service && mf_left_alone mysql.service
}
mf_meta() { mf_setup; PANEL_DB_UNIT=postgresql@17-main.service; write_service_manifest; grep -q '"version":1' "$LARANODE_MANIFEST_FILE" && grep -q '"os":"debian 13"' "$LARANODE_MANIFEST_FILE" && grep -q '"proxmox":true' "$LARANODE_MANIFEST_FILE" && grep -q '"engine":"pgsql","unit":"postgresql@17-main.service"' "$LARANODE_MANIFEST_FILE"; }
mf_perms() { mf_setup; write_service_manifest; [ -f "$LARANODE_MANIFEST_FILE" ] && [ "$(stat -c %a "$LARANODE_MANIFEST_FILE" 2>/dev/null || echo 644)" = 644 ]; }
mf_wired() {
  base
  declare -f phase_services | grep -q write_service_manifest && declare -f preflight | grep -q capture_preexisting \
    && declare -f _mysql_branch | grep -q 'PANEL_DB_UNIT=mysql.service' && declare -f _pgsql_branch | grep -q 'PANEL_DB_UNIT='
}
capture_runs_clean() {   # capture_preexisting with no systemctl must not fail the install
  base; PRE_APACHE=9; pkg_installed() { [ "$1" = apache2 ]; }; capture_preexisting; [ "$PRE_APACHE" = 1 ] && [ "$PRE_PHPFPM" = 0 ] && [ -z "$PRE_UNITS" ]
}
t "fresh host: everything the installer set up is managed:true (valid JSON)"   mf_fresh
t "pre-existing apache/php/db/nginx/redis/PG16/clp: managed:false"             mf_preexisting_left_alone
t "no unit listed twice; our units win over the pre-existing snapshot"          mf_never_double_listed
t "re-run keeps ownership of what run 1 installed"                              mf_rerun_keeps_ownership
t "re-run never adopts a pre-existing service"                                  mf_rerun_never_adopts
t "manifest carries version, host, engine and db unit"                          mf_meta
t "manifest file created world-readable"                                        mf_perms
t "preflight snapshots, db branches name their unit, phase_services writes"     mf_wired
t "capture_preexisting works without systemctl"                                 capture_runs_clean

# ---- dollar-quote tags (PostgreSQL rejects a tag that starts with a digit) -----
echo "=== pg dollar-quote tags ==="
tag_letter_first() {
  local line i tag
  while IFS= read -r line; do
    for i in $(seq 1 300); do
      tag=""; eval "$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[A-Z_]+=//; s/[[:space:]]+#.*$//; s/^/tag=/')"
      case "$tag" in [a-z]*) ;; *) echo "tag '$tag' from: $line"; return 1;; esac
    done
  done < <(grep -E '^[[:space:]]*(DB_PASS_TAG|PGSQL_PG_TAG)=' "$INSTALLER")
}
t "dollar-quote tags always start with a letter (300 draws each)" tag_letter_first

# ---- front-end install must survive registry drift (no committed lockfile) ------
echo "=== npm install ==="
npm_legacy_peers() { grep -qE '^[[:space:]]+_as_panel_user npm install --legacy-peer-deps$' "$INSTALLER"; }
npm_dom_explicit() { grep -q '"@testing-library/dom"' "${SCRIPT_DIR}/../../../package.json"; }
t "installer runs npm install --legacy-peer-deps (arborist edgesOut crash)"     npm_legacy_peers
t "package.json lists @testing-library/dom explicitly (peer of RTL 16)"          npm_dom_explicit


# ==============================================================================
# PR #4 review fixes (each test must FAIL on the pre-fix installer)
# ==============================================================================

# ---- 1. a pre-existing Apache keeps every Listen it had ----------------------
echo "=== pre-existing Apache keeps its listeners ==="
ports_pre_8080()  { ports_run :; APACHE_OWNED=0; HTTP_PORT=8080 BIND_ADDR=""; _apache_ports_conf "$p"; grep -qxE 'Listen 80' "$p" && grep -qxE 'Listen 8080' "$p"; }
ports_pre_bound() { ports_run :; APACHE_OWNED=0; HTTP_PORT=8090 BIND_ADDR=127.0.0.1; _apache_ports_conf "$p"; grep -qxE 'Listen 80' "$p" && grep -qxE 'Listen 127.0.0.1:8090' "$p"; }
ports_pre_443_untouched() { ports_run :; APACHE_OWNED=0; HTTP_PORT=8090 BIND_ADDR=127.0.0.1; _apache_ports_conf "$p"; [ "$(grep -cE '^[[:space:]]*Listen 443' "$p")" = 2 ]; }
ports_pre_idem()  { ports_run :; APACHE_OWNED=0; HTTP_PORT=8080 BIND_ADDR=""; _apache_ports_conf "$p"; _apache_ports_conf "$p"; [ "$(grep -cxE 'Listen 8080' "$p")" = 1 ]; }
t "pre-existing Apache + panel on 8080: stock 'Listen 80' kept, 'Listen 8080' added" ports_pre_8080
t "pre-existing Apache + bound panel: 'Listen 80' kept, scoped panel Listen added"   ports_pre_bound
t "pre-existing Apache: its own 'Listen 443' is never rewritten"                    ports_pre_443_untouched
t "pre-existing Apache: re-run does not duplicate the panel Listen"                 ports_pre_idem

pre_env() { base; export LARANODE_MANIFEST_FILE=/nonexistent-manifest; svc_active() { [ "$1" = apache2 ]; }; pkg_installed() { [ "$1" = apache2 ]; }; port_in_use() { [ "$1" = 80 ]; }; ss() { echo 'LISTEN 0 511 *:80 *:* users:(("apache2",pid=1,fd=4))'; }; }
pf_pre_apache_bind_80() { pre_env; export LARANODE_HTTP_PORT=80 LARANODE_BIND=local; preflight; }
pf_pre_apache_open_80() { pre_env; export LARANODE_HTTP_PORT=80; preflight; expect HTTP_PORT "$HTTP_PORT" 80; }
pf_pre_apache_default() { pre_env; preflight; expect HTTP_PORT "$HTTP_PORT" 8080 && expect APACHE_OWNED "$APACHE_OWNED" 0; }
pf_own_apache_bind_80() {  # re-run of our own bound install: manifest says apache2 is ours
  pre_env; mf=$(mktemp); echo '{"unit":"apache2.service","managed":true,"role":"web"}' > "$mf"; export LARANODE_MANIFEST_FILE="$mf"
  export LARANODE_HTTP_PORT=80 LARANODE_BIND=local; preflight; expect APACHE_OWNED "$APACHE_OWNED" 1; }
tf "pre-existing Apache on :80 + LARANODE_BIND=local + :80 refused (cannot narrow its Listen)" pf_pre_apache_bind_80
t  "pre-existing Apache on :80, explicit :80, all interfaces: shares :80 (vhost only)"          pf_pre_apache_open_80
t  "pre-existing Apache on :80: panel defaults to 8080, Apache marked not owned"                pf_pre_apache_default
t  "re-run of our own bound install (manifest managed:true) is still allowed"                   pf_own_apache_bind_80

# ---- 2/3. no restart, no a2dissite, no ssl module on a pre-existing Apache/php-fpm -
echo "=== pre-existing services are never restarted ==="
svc_run() {  # svc_run <unit> <owned> <active:0|1>  -> SVC_LOG
  SVC_LOG=$(mktemp); base
  systemctl() { echo "$*" >> "$SVC_LOG"; }
  svc_active() { [ "$ACTIVE" = 1 ]; }
  ACTIVE=$3; _refresh_service "$1" "$2"
}
refresh_owned()       { svc_run apache2 1 1; grep -qx 'restart apache2' "$SVC_LOG"; }
refresh_pre_active()  { svc_run apache2 0 1; grep -qx 'reload apache2' "$SVC_LOG" && ! grep -q restart "$SVC_LOG"; }
refresh_pre_inactive(){ svc_run php8.4-fpm 0 0; grep -qx 'start php8.4-fpm' "$SVC_LOG" && ! grep -qE 'restart|reload' "$SVC_LOG"; }
no_bare_restarts()    { base; ! declare -f phase_webserver phase_services | grep -E 'systemctl restart (apache2|php8\.4-fpm)'; }
dissite_owned()       { base; DLOG=$(mktemp); a2dissite() { echo "$*" >> "$DLOG"; }; APACHE_OWNED=1; _disable_default_site; grep -q 000-default "$DLOG"; }
dissite_pre()         { base; DLOG=$(mktemp); a2dissite() { echo "$*" >> "$DLOG"; }; APACHE_OWNED=0; _disable_default_site; ! grep -q . "$DLOG"; }
mods_owned_ssl()      { base; APACHE_OWNED=1; _apache_modules | tr ' ' '\n' | grep -qx ssl; }
mods_pre_no_ssl()     { base; APACHE_OWNED=0; ! _apache_modules | tr ' ' '\n' | grep -qx ssl; }
t "our own Apache/php-fpm: restart (we installed it)"                        refresh_owned
t "pre-existing running unit: graceful reload only, never restart"           refresh_pre_active
t "pre-existing stopped unit: start only"                                    refresh_pre_inactive
t "phase_webserver/phase_services contain no bare 'systemctl restart apache2|php8.4-fpm'" no_bare_restarts
t "a2dissite 000-default runs on an Apache this installer installed"         dissite_owned
t "a2dissite 000-default never runs on a pre-existing Apache"                dissite_pre
t "our own Apache gets mod_ssl enabled"                                      mods_owned_ssl
t "pre-existing Apache: mod_ssl is not enabled (would open a new :443)"      mods_pre_no_ssl

vhost_pre_handler() { base; d=$(mktemp -d); printf '<VirtualHost *:__PORT__>\n    DocumentRoot __DOCROOT__\n</VirtualHost>\n' > "$d/t"; APACHE_OWNED=0; _vhost_render "$d/t" "$d/o" 8080 /x/public; grep -q 'proxy:unix:/run/php/php8.4-fpm.sock' "$d/o" && grep -q 'VirtualHost \*:8080' "$d/o" && [ "$(grep -c '</VirtualHost>' "$d/o")" = 1 ]; }
vhost_owned_plain() { base; d=$(mktemp -d); printf '<VirtualHost *:__PORT__>\n    DocumentRoot __DOCROOT__\n</VirtualHost>\n' > "$d/t"; APACHE_OWNED=1; _vhost_render "$d/t" "$d/o" 80 /x/public; ! grep -q 'proxy:unix' "$d/o" && grep -q 'DocumentRoot /x/public' "$d/o"; }
t "pre-existing Apache: php-fpm handler lives in the panel vhost only"        vhost_pre_handler
t "our own Apache: vhost rendered without an inline handler (global conf)"   vhost_owned_plain

# ---- 4. unsupported OS refused before any apt call -------------------------------
echo "=== refusal precedes any install ==="
main_refuses_before_apt() {
  base; export LARANODE_OS_RELEASE_FILE="${FIX}/os-release.debian-12"
  CALLS=$(mktemp); apt-get() { echo "apt-get $*" >> "$CALLS"; return 1; }
  ( main ) >/dev/null 2>&1 && return 1
  [ ! -s "$CALLS" ]
}
t "main on Debian 12 without 'ss': refused with zero apt-get calls" main_refuses_before_apt

# ---- 5. LARANODE_BIND scopes mod_ssl's :443 too -------------------------------------
echo "=== bound panel does not leave Apache on a public :443 ==="
ports_bound_443() { ports_run :; APACHE_OWNED=1; HTTP_PORT=80 BIND_ADDR=127.0.0.1; _apache_ports_conf "$p"; ! grep -qE '^[[:space:]]*Listen 443' "$p" && grep -qE '^[[:space:]]*Listen 127.0.0.1:443' "$p"; }
ports_bound_443_busy() { ports_run :; APACHE_OWNED=1; HTTP_PORT=80 BIND_ADDR=127.0.0.1; port_in_use() { [ "$1" = 443 ]; }; ss() { return 1; }; _apache_ports_conf "$p"; ! grep -qE '^[[:space:]]*Listen (127.0.0.1:)?443' "$p"; }
t "LARANODE_BIND=local on a normal host: 'Listen 443' becomes 'Listen 127.0.0.1:443'" ports_bound_443
t "bound panel + :443 held by another service: 'Listen 443' disabled, not duplicated"   ports_bound_443_busy

# ---- 6. apt guard on every host, needrestart off ----------------------------------------
echo "=== apt guard everywhere ==="
apt_plain_upgrade_refused() { base; apt_run 'Inst nginx-common [1.0] (1.1 Ubuntu)'; apt_refused && printf '%s' "$OUT" | grep -q nginx-common; }
apt_plain_ssh_refused()     { base; apt_run 'Inst openssh-server [1:9.6] (1:9.7 Ubuntu)'; apt_refused; }
apt_plain_benign_ok()       { base; apt_run $'Inst libcurl4 [8.5.0] (8.5.1 Ubuntu)\nInst apache2 (2.4 Ubuntu)'; apt_passed; }
apt_no_upgrade_flag() { base; CALLS=$(mktemp); ( apt-get() { echo "$*" >> "$CALLS"; }; apt_install curl ) >/dev/null 2>&1; [ "$(grep -c -- '--no-upgrade' "$CALLS")" = 2 ]; }
needrestart_off() { ( source "$INSTALLER"; [ "${NEEDRESTART_MODE:-}" = l ] && [ "${NEEDRESTART_SUSPEND:-}" = 1 ] ); }
t "plain host: refuses when apt would UPGRADE a protected service package (nginx)" apt_plain_upgrade_refused
t "plain host: refuses when apt would upgrade openssh-server"                       apt_plain_ssh_refused
t "plain host: unrelated library upgrade still passes"                              apt_plain_benign_ok
t "apt-get install runs with --no-upgrade (simulation and real)"                    apt_no_upgrade_flag
t "needrestart cannot restart services during the install (NEEDRESTART_MODE=l)"    needrestart_off

# ---- 7. secrets never world-readable -----------------------------------------------------------
echo "=== .env / secrets permissions ==="
seed_env_640() {
  # r4: the copy and the 0640 happen AS the panel user (stubbed to run as the test user here), so
  # the file is the panel account's own — no root chmod/chown/chgrp follows a planted link
  base; PANEL_PATH=$(mktemp -d); printf 'APP_KEY=\n' > "$PANEL_PATH/.env.example"
  _as_panel_user() { "$@"; }
  _seed_env
  [ -f "$PANEL_PATH/.env" ] && [ "$(stat -c %a "$PANEL_PATH/.env")" = 640 ]
}
seed_env_keeps_existing() { base; PANEL_PATH=$(mktemp -d); echo 'KEEP=1' > "$PANEL_PATH/.env"; : > "$PANEL_PATH/.env.example"; _seed_env; grep -qx 'KEEP=1' "$PANEL_PATH/.env"; }
no_plain_env_cp() { base; ! declare -f _mysql_branch _pgsql_branch phase_app | grep -E 'cp .*\.env\.example'; }
home_750() {
  base; PANEL_PATH=$(mktemp -d); mkdir "$PANEL_PATH/laranode-scripts"; MLOG=$(mktemp)
  useradd() { :; }; usermod() { :; }; chown() { :; }; chmod() { echo "chmod $*" >> "$MLOG"; }; id() { return 0; }
  unset LARANODE_REF; export LARANODE_HOST_CONF="$PANEL_PATH/host.conf"
  _prepare_panel_tree() { :; }; _install_privileged_scripts() { :; }; _stash_sync_script() { :; }
  phase_fetch_panel >/dev/null 2>&1
  grep -qx 'chmod 750 /home/laranode_ln' "$MLOG"
}
t "_seed_env creates .env at 0640 with group laranode_ln (no 0644 window)"   seed_env_640
t "_seed_env never overwrites an existing .env"                              seed_env_keeps_existing
t "DB branches and phase_app no longer 'cp .env.example' directly"           no_plain_env_cp
t "/home/laranode_ln is 0750 right after useradd (Debian default is 0755)"   home_750

# ---- nits: refuse early, argv secrets, TTY, IPv4 octets -------------------------------------------
echo "=== early refusals / argv secrets ==="
pf_pg_needs_port()  { base; pg_cluster_count() { echo 2; }; export LARANODE_DB_ENGINE=pgsql; preflight; }
pf_pg_with_port()   { base; pg_cluster_count() { echo 2; }; export LARANODE_DB_ENGINE=pgsql LARANODE_PG_PORT=5433; preflight; }
pf_node_old()       { base; have_cmd() { [ "$1" = node ]; }; node() { echo v18.19.0; }; preflight; }
pf_node_ok()        { base; have_cmd() { [ "$1" = node ]; }; node() { echo v22.1.0; }; preflight; }
pf_bad_octet()      { base; export LARANODE_BIND=999.1.1.1; preflight; }
pf_good_ip()        { base; export LARANODE_BIND=100.64.0.7; preflight; expect BIND_ADDR "$BIND_ADDR" 100.64.0.7; }
confirm_no_tty()    { base; export LARANODE_UNATTENDED=0; out=$(confirm "go?" </dev/null 2>&1); rc=$?; [ $rc -ne 0 ] && printf '%s' "$out" | grep -q LARANODE_UNATTENDED; }
tf "pgsql + existing clusters + no LARANODE_PG_PORT: refused in preflight (nothing mutated yet)" pf_pg_needs_port
t  "pgsql + existing clusters + LARANODE_PG_PORT: preflight passes"                              pf_pg_with_port
tf "Node < 20 present: refused in preflight"                                                    pf_node_old
t  "Node 22 present: preflight passes"                                                          pf_node_ok
tf "LARANODE_BIND=999.1.1.1 refused (octet > 255)"                                              pf_bad_octet
t  "LARANODE_BIND=<valid ipv4> accepted"                                                        pf_good_ip
t  "confirm without TTY and without LARANODE_UNATTENDED=1 says so"                              confirm_no_tty

mysql_pw_not_in_argv() {
  base; PANEL_PATH=$(mktemp -d); : > "$PANEL_PATH/.env.example"
  ALOG=$(mktemp); SQLLOG=$(mktemp)
  pkg_installed() { [ "$1" = mysql-server ]; }
  systemctl() { return 0; }; persist_secret() { :; }; openssl() { echo dbsecretpw; }
  export LARANODE_MYSQL_ROOT_PASSWORD=rootsecretpw
  mysql() {
    echo "$*" >> "$ALOG"
    # socket auth is "broken": only works when the password arrives via MYSQL_PWD or -p
    if [ -z "${MYSQL_PWD:-}" ] && ! printf '%s' "$*" | grep -q -- '-p'; then return 1; fi
    [ -t 0 ] || cat >> "$SQLLOG"
    return 0
  }
  _mysql_branch
  ! grep -q 'rootsecretpw' "$ALOG" && ! grep -q 'dbsecretpw' "$ALOG"
}
t "MySQL root and panel passwords never appear in mysql's argv (env + stdin)" mysql_pw_not_in_argv

# ---- pre-existing (cheap): Reverb must not run as root ---------------------------------------------------
reverb_not_root() { grep -qx 'User=laranode_ln' "${SCRIPT_DIR}/../../../laranode-scripts/templates/laranode-reverb.service"; }
t "laranode-reverb.service runs as laranode_ln, not root" reverb_not_root


# ==============================================================================
# Round 2 (re-review of 9217bb5)
# ==============================================================================

# ---- finding 1: the panel's own Listen port must be free BEFORE Apache is touched ----
echo "=== busy panel port is refused before any Apache change ==="
# A running, pre-existing Apache holds :80. Something else holds $BUSY. A graceful
# reload with a 'Listen $BUSY' it cannot bind can take the live sites down, and
# apachectl configtest does not bind - so preflight must refuse.
busy_env() {  # busy_env <port> <holder-process>
  BUSY=$1; HOLDER=$2
  base; export LARANODE_MANIFEST_FILE=/nonexistent-manifest
  pkg_installed() { [ "$1" = apache2 ]; }; svc_active() { [ "$1" = apache2 ]; }
  port_in_use() { [ "$1" = 80 ] || [ "$1" = "$BUSY" ]; }
  ss() {
    case "$*" in
      *":${BUSY} )"*) echo "LISTEN 0 5 0.0.0.0:${BUSY} 0.0.0.0:* users:((\"${HOLDER}\",pid=7,fd=3))" ;;
      *":80 )"*)      echo 'LISTEN 0 511 *:80 *:* users:(("apache2",pid=1,fd=4))' ;;
    esac
  }
  _panel_vhost_enabled() { return 1; }
}
pf_busy_fallback()   { busy_env 8080 python3; preflight; }
pf_busy_explicit()   { busy_env 9000 tomcat; export LARANODE_HTTP_PORT=9000; preflight; }
pf_busy_msg()        { busy_env 8080 python3; out=$( (preflight) 2>&1 ); [ $? -ne 0 ] && printf '%s' "$out" | grep -q '8080' && printf '%s' "$out" | grep -q 'python3' && printf '%s' "$out" | grep -q 'LARANODE_HTTP_PORT'; }
pf_busy_other_apache(){ busy_env 8080 apache2; preflight; }
pf_busy_own_rerun()  { busy_env 8080 apache2; _panel_vhost_enabled() { return 0; }; preflight; expect HTTP_PORT "$HTTP_PORT" 8080; }
pf_free_8080()       { busy_env 9999 x; preflight; expect HTTP_PORT "$HTTP_PORT" 8080; }
pf_busy_clp()        { busy_env 8090 varnishd; IS_CLOUDPANEL=1; detect_cloudpanel() { IS_CLOUDPANEL=1; }; preflight; }
tf "nginx/Apache on :80 + another service on :8080: refused before Apache is touched"   pf_busy_fallback
tf "explicit LARANODE_HTTP_PORT held by another service: refused"                       pf_busy_explicit
t  "the refusal names the port, the holder and LARANODE_HTTP_PORT"                      pf_busy_msg
tf "port held by the owner's own Apache (no panel vhost yet): refused"                  pf_busy_other_apache
t  "re-run: port held by the panel's own Apache vhost is accepted"                      pf_busy_own_rerun
t  "free fallback port still works"                                                     pf_free_8080
tf "CloudPanel fallback :8090 busy: refused"                                            pf_busy_clp

# ---- finding 2: ownership = the package was absent before this run -------------------
echo "=== a pre-existing STOPPED apache2 / php8.4-fpm is not ours ==="
# w2_env APACHE(run|stop|none) FPM(run|stop|none)
w2_env() {
  base; export LARANODE_MANIFEST_FILE=/nonexistent-manifest
  _A=$1; _F=$2
  pkg_installed() { { [ "$1" = apache2 ] && [ "$_A" != none ]; } || { [ "$1" = php8.4-fpm ] && [ "$_F" != none ]; }; }
  svc_active()    { { [ "$1" = apache2 ] && [ "$_A" = run ]; }  || { [ "$1" = php8.4-fpm ] && [ "$_F" = run ]; }; }
  port_in_use()   { [ "$1" = 80 ] && [ "$_A" = run ]; }
  ss() { echo 'LISTEN 0 511 *:80 *:* users:(("apache2",pid=1,fd=4))'; }
}
pf_stop_apache()        { w2_env stop none; preflight; }
pf_stop_apache_msg()    { w2_env stop none; out=$( (preflight) 2>&1 ); [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'LARANODE_START_STOPPED' && printf '%s' "$out" | grep -qi 'apache2'; }
pf_stop_apache_optin()  { w2_env stop none; export LARANODE_START_STOPPED=1; preflight; expect APACHE_OWNED "$APACHE_OWNED" 0 && expect PRE_APACHE "$PRE_APACHE" 1; }
pf_stop_fpm()           { w2_env none stop; preflight; }
pf_stop_fpm_optin()     { w2_env none stop; export LARANODE_START_STOPPED=1; preflight; expect PHPFPM_OWNED "$PHPFPM_OWNED" 0; }
pf_stop_prior_managed() { w2_env stop stop; mf=$(mktemp); printf '%s\n' '{"unit":"apache2.service","managed":true,"role":"web"}' '{"unit":"php8.4-fpm.service","managed":true,"role":"php"}' > "$mf"; export LARANODE_MANIFEST_FILE="$mf"; preflight; expect APACHE_OWNED "$APACHE_OWNED" 1 && expect PHPFPM_OWNED "$PHPFPM_OWNED" 1; }
pf_absent_owned()       { w2_env none none; preflight; expect APACHE_OWNED "$APACHE_OWNED" 1 && expect PHPFPM_OWNED "$PHPFPM_OWNED" 1; }
pf_run_not_owned()      { w2_env run run; preflight; expect APACHE_OWNED "$APACHE_OWNED" 0 && expect PHPFPM_OWNED "$PHPFPM_OWNED" 0; }
tf "pre-existing STOPPED apache2: refused unless LARANODE_START_STOPPED=1"           pf_stop_apache
t  "the refusal names LARANODE_START_STOPPED and apache2"                            pf_stop_apache_msg
t  "LARANODE_START_STOPPED=1: stopped apache2 is allowed and stays NOT owned"        pf_stop_apache_optin
tf "pre-existing STOPPED php8.4-fpm: refused unless LARANODE_START_STOPPED=1"        pf_stop_fpm
t  "LARANODE_START_STOPPED=1: stopped php8.4-fpm is allowed and stays NOT owned"     pf_stop_fpm_optin
t  "a re-run (manifest managed:true) keeps owning stopped units, no flag needed"     pf_stop_prior_managed
t  "package absent before the run: owned (installed by this run)"                    pf_absent_owned
t  "pre-existing running units: not owned"                                           pf_run_not_owned

fpm_up_owned()   { base; SVC_LOG=$(mktemp); systemctl() { echo "$*" >> "$SVC_LOG"; }; PHPFPM_OWNED=1; _php_fpm_up; grep -qx 'enable php8.4-fpm' "$SVC_LOG" && grep -qx 'start php8.4-fpm' "$SVC_LOG"; }
fpm_up_pre()     { base; SVC_LOG=$(mktemp); systemctl() { echo "$*" >> "$SVC_LOG"; }; PHPFPM_OWNED=0; _php_fpm_up; ! grep -q . "$SVC_LOG"; }
fpm_wired()      { base; declare -f phase_php_node | grep -q '_php_fpm_up' && ! declare -f phase_php_node | grep -qE 'systemctl (enable|start) php8.4-fpm'; }
t "php8.4-fpm we installed: enabled + started"                                       fpm_up_owned
t "pre-existing php8.4-fpm: no enable, no start (boot state untouched)"              fpm_up_pre
t "phase_php_node goes through _php_fpm_up (no bare enable/start)"                   fpm_wired

# ---- nit: apache2 is a protected package ---------------------------------------------
apt_apache2_refused()  { base; apt_run 'Inst apache2 [2.4.58-1] (2.4.58-2 Ubuntu)'; apt_refused; }
apt_apache2bin_refused(){ base; apt_run 'Inst apache2-bin [2.4.58-1] (2.4.58-2 Ubuntu)'; apt_refused; }
apt_apache2_new_ok()   { base; apt_run $'Inst apache2 (2.4.58-1 Ubuntu)\nInst apache2-bin (2.4.58-1 Ubuntu)'; apt_passed; }
t "apt would UPGRADE an installed apache2: refused"                                  apt_apache2_refused
t "apt would UPGRADE apache2-bin: refused"                                           apt_apache2bin_refused
t "a fresh apache2 install (no upgrade) still passes"                                apt_apache2_new_ok

# ---- nit: the phases are tested by behaviour (systemctl/a2* call lists), not by grep ----
echo "=== phase behaviour with stubs ==="
svc_stub() {  # records every systemctl call in SVC_LOG; svc_active follows $ACTIVE_UNITS
  SVC_LOG=$(mktemp)
  systemctl() { echo "$*" >> "$SVC_LOG"; }
  svc_active() { case " $ACTIVE_UNITS " in *" $1 "*) return 0;; esac; grep -qxE "(re)?start $1" "$SVC_LOG"; }
}
ps_run() {  # phase_services with the filesystem stubbed
  svc_stub; log() { :; }
  cp() { :; }; mkdir() { :; }; chown() { :; }; find() { :; }; chmod() { :; }
  _install_scheduler_cron() { :; }; write_service_manifest() { :; }
  PANEL_PATH=/nonexistent; phase_services
}
ps_pre_running() { base; ACTIVE_UNITS="apache2 php8.4-fpm"; APACHE_OWNED=0; PHPFPM_OWNED=0; ps_run
  grep -qx 'reload apache2' "$SVC_LOG" && grep -qx 'reload php8.4-fpm' "$SVC_LOG" && ! grep -qE '^(restart|stop) |^start (apache2|php8.4-fpm)|^enable (--now )?(apache2|php8.4-fpm)' "$SVC_LOG"; }
ps_owned()       { base; ACTIVE_UNITS="apache2 php8.4-fpm"; APACHE_OWNED=1; PHPFPM_OWNED=1; ps_run
  grep -qx 'restart apache2' "$SVC_LOG" && grep -qx 'restart php8.4-fpm' "$SVC_LOG" && ! grep -q '^reload ' "$SVC_LOG"; }
ps_mixed()       { base; ACTIVE_UNITS="apache2 php8.4-fpm"; APACHE_OWNED=0; PHPFPM_OWNED=1; ps_run
  grep -qx 'reload apache2' "$SVC_LOG" && grep -qx 'restart php8.4-fpm' "$SVC_LOG"; }
ps_pre_stopped() { base; ACTIVE_UNITS=""; APACHE_OWNED=0; PHPFPM_OWNED=0; ps_run
  grep -qx 'start apache2' "$SVC_LOG" && grep -qx 'start php8.4-fpm' "$SVC_LOG" && ! grep -qE '^enable (--now )?(apache2|php8.4-fpm)' "$SVC_LOG"; }
t "phase_services, pre-existing running apache2+fpm: reload both, nothing else"   ps_pre_running
t "phase_services, we installed both: restart both, no reload"                    ps_owned
t "phase_services passes each unit's OWN flag (apache pre-existing, fpm ours)"    ps_mixed
t "phase_services, opted-in stopped pre-existing units: start only, never enable" ps_pre_stopped

# phase_webserver against a scratch /etc/apache2
wb_setup() {  # wb_setup <owned 0|1> <running 0|1> <port>
  base; svc_stub; log() { :; }
  AD=$(mktemp -d); mkdir -p "$AD/sites-available" "$AD/sites-enabled"
  cp "${FIX}/ports.conf" "$AD/ports.conf"; cp "$AD/ports.conf" "$AD/ports.conf.orig"
  export LARANODE_APACHE_DIR="$AD" LARANODE_POLICY_RC_D="$AD/policy-rc.d" LARANODE_APACHE_MODS_STATE="$AD/mods.state" LARANODE_ROLLBACK_DIR="$AD/rollback"
  PANEL_PATH=$(mktemp -d); LN_LIB_DEST=$(mktemp -d); mkdir -p "$LN_LIB_DEST/templates"
  printf '<VirtualHost *:__PORT__>\n    DocumentRoot __DOCROOT__\n</VirtualHost>\n' > "$LN_LIB_DEST/templates/apache-panel.template"
  APACHE_OWNED=$1; HTTP_PORT=$3; BIND_ADDR=""; IS_PROXMOX=0; IS_CLOUDPANEL=0
  [ "$2" = 1 ] && ACTIVE_UNITS="apache2" || ACTIVE_UNITS=""
  WLOG=$(mktemp); ENABLED_MODS=" "
  apt_install()  { :; }
  a2query()      { case "$ENABLED_MODS" in *" $2 "*) return 0;; *) return 1;; esac; }
  a2enmod()      { echo "a2enmod $*" >> "$WLOG"; }
  a2dismod()     { echo "a2dismod $*" >> "$WLOG"; }
  a2ensite()     { echo "a2ensite $*" >> "$WLOG"; : > "$AD/sites-enabled/$1.conf"; }
  a2dissite()    { echo "a2dissite $*" >> "$WLOG"; rm -f "$AD/sites-enabled/$1.conf"; }
  apachectl()    { [ "${CONFTEST_FAIL:-0}" != 1 ]; }
  ss()           { echo "LISTEN 0 511 *:${HTTP_PORT} *:* users:((\"apache2\",pid=1,fd=4))"; }
  sleep()        { :; }; chmod() { :; }; _configure_firewall() { :; }
  port_in_use()  { return 1; }
}
wb_pre_running() { wb_setup 0 1 8080; ( phase_webserver ) >/dev/null 2>&1 || return 1
  grep -qx 'reload apache2' "$SVC_LOG" && ! grep -qE '^(restart|start|enable)' "$SVC_LOG" \
  && ! grep -q 'a2dissite' "$WLOG" && ! grep -qw ssl "$WLOG" \
  && grep -qxE 'Listen 80' "$AD/ports.conf" && grep -qxE 'Listen 8080' "$AD/ports.conf"; }
wb_owned()       { wb_setup 1 0 80; ( phase_webserver ) >/dev/null 2>&1 || return 1
  grep -qx 'enable apache2' "$SVC_LOG" && grep -qx 'restart apache2' "$SVC_LOG" && grep -q 'a2dissite 000-default' "$WLOG" && grep -qw ssl "$WLOG"; }
wb_pre_stopped() { wb_setup 0 0 80; ( phase_webserver ) >/dev/null 2>&1 || return 1
  grep -qx 'start apache2' "$SVC_LOG" && ! grep -qE '^(restart|reload|enable)' "$SVC_LOG" && ! grep -q 'a2dissite' "$WLOG" \
  && cmp -s "$AD/ports.conf" "$AD/ports.conf.orig"; }
wb_conftest_rollback() { wb_setup 0 1 8080; CONFTEST_FAIL=1; ( phase_webserver ) >/dev/null 2>&1 && return 1
  cmp -s "$AD/ports.conf" "$AD/ports.conf.orig" && [ ! -e "$AD/sites-enabled/laranode.conf" ] && [ ! -e "$AD/sites-available/laranode.conf" ] && ! grep -q '^reload' "$SVC_LOG"; }
wb_reload_rollback()   { wb_setup 0 1 8080; systemctl() { echo "$*" >> "$SVC_LOG"; [ "$1" != reload ]; }; ( phase_webserver ) >/dev/null 2>&1 && return 1
  cmp -s "$AD/ports.conf" "$AD/ports.conf.orig" && [ ! -e "$AD/sites-enabled/laranode.conf" ]; }
wb_pre_modules()  { wb_setup 0 1 8080; phase_webserver >/dev/null 2>&1 || return 1
  for m in proxy proxy_fcgi rewrite; do grep -qx "a2enmod $m" "$WLOG" || { echo "missing $m"; return 1; }; done
  ! grep -qE 'a2enmod (headers|setenvif|proxy_http|ssl)' "$WLOG" && [ "$APACHE_MODS_ENABLED" = "proxy proxy_fcgi rewrite" ]; }
wb_pre_modules_skip_enabled() { wb_setup 0 1 8080; ENABLED_MODS=" proxy proxy_fcgi "; ( phase_webserver ) >/dev/null 2>&1 || return 1
  grep -qx 'a2enmod rewrite' "$WLOG" && ! grep -qE 'a2enmod (proxy|proxy_fcgi)$' "$WLOG"; }
wb_owned_modules() { wb_setup 1 0 80; ( phase_webserver ) >/dev/null 2>&1 || return 1
  for m in proxy_fcgi rewrite setenvif headers proxy proxy_http ssl; do grep -qw "$m" "$WLOG" || { echo "missing $m"; return 1; }; done; }
t  "phase_webserver, pre-existing running Apache: reload only, Listen 80 kept, no a2dissite, no ssl" wb_pre_running
t  "phase_webserver, Apache we installed: enable + restart, 000-default off, ssl on"                 wb_owned
t  "phase_webserver, opted-in stopped pre-existing Apache: start only (never enable), ports.conf untouched" wb_pre_stopped
t  "failed configtest on a pre-existing Apache: ports.conf, vhost and site link rolled back"         wb_conftest_rollback
t  "failed reload on a pre-existing Apache: ports.conf and site link rolled back"                    wb_reload_rollback
t  "pre-existing Apache: only the modules the panel vhost needs are enabled and recorded"           wb_pre_modules
t  "pre-existing Apache: modules that are already on are not touched"                               wb_pre_modules_skip_enabled
t  "Apache we installed keeps the full module set (panel features need it)"                          wb_owned_modules

mf_records_mods() { mf_setup; APACHE_MODS_ENABLED="proxy rewrite"; write_service_manifest; mf_valid_json && grep -q '"apache_modules_enabled":\["proxy","rewrite"\]' "$LARANODE_MANIFEST_FILE"; }
mf_no_mods()      { mf_setup; APACHE_MODS_ENABLED=""; write_service_manifest; mf_valid_json && grep -q '"apache_modules_enabled":\[\]' "$LARANODE_MANIFEST_FILE"; }
mf_mods_rerun()   { mf_setup; APACHE_MODS_ENABLED="proxy rewrite"; write_service_manifest; APACHE_MODS_ENABLED=""; write_service_manifest; grep -q '"apache_modules_enabled":\["proxy","rewrite"\]' "$LARANODE_MANIFEST_FILE"; }
t "manifest records the Apache modules this installer enabled"                      mf_records_mods
t "manifest: no modules enabled -> empty list"                                      mf_no_mods
t "manifest: a re-run that enables nothing keeps the earlier record"                mf_mods_rerun

# ---- nit: warn about the shared-:80 default-vhost ordering ---------------------------
plan_warn() {  # plan_warn <HTTP_PORT env value> -> $OUT is everything preflight said
  pre_env; export LARANODE_HTTP_PORT=$1; log() { echo "$*"; }; warn() { echo "WARN: $*"; }
  OUT=$(preflight 2>&1)
}
warn_shared_80()      { plan_warn 80;   printf '%s' "$OUT" | grep -qi 'default vhost' && printf '%s' "$OUT" | grep -q 'laranode.conf'; }
no_warn_8080()        { plan_warn 8080; ! printf '%s' "$OUT" | grep -qi 'default vhost'; }
t "explicit :80 beside a pre-existing Apache: plan warns about default-vhost ordering"  warn_shared_80
t "panel on its own port: no shared-:80 warning"                                         no_warn_8080
warn_both_ways()      { plan_warn 80; printf '%s' "$OUT" | grep -q 'NOT reachable' && printf '%s' "$OUT" | grep -qi 'hijacks'; }
t "the shared-:80 warning covers BOTH orderings (panel unreachable / panel hijacks)"    warn_both_ways

# ---- a stopped pre-existing Apache whose own Listen port another service holds ------------
echo "=== stopped Apache that could not start is refused before any change ==="
stop_conflict_env() {  # $1 = busy port, $2 = holder; nginx-style host with a stopped apache2
  w2_env stop none
  AD=$(mktemp -d); cp "${FIX}/ports.conf" "$AD/ports.conf"; export LARANODE_APACHE_DIR="$AD"
  CONF_PORT=$1; CONF_HOLDER=$2
  port_in_use() { [ "$1" = "$CONF_PORT" ]; }
  ss() { echo "LISTEN 0 511 0.0.0.0:${CONF_PORT} 0.0.0.0:* users:((\"${CONF_HOLDER}\",pid=3,fd=6))"; }
}
pf_stop_listen_busy_optin() { stop_conflict_env 80 nginx; export LARANODE_START_STOPPED=1; preflight; }
pf_stop_listen_busy_noflag(){ stop_conflict_env 80 nginx; preflight; }
pf_stop_listen_msg()        { stop_conflict_env 80 nginx; export LARANODE_START_STOPPED=1; out=$( (preflight) 2>&1 ); [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'nginx' && printf '%s' "$out" | grep -q '80' && ! printf '%s' "$out" | grep -q 'LARANODE_START_STOPPED'; }
pf_stop_ssl_block_ignored() { stop_conflict_env 443 nginx; export LARANODE_START_STOPPED=1; preflight; }
pf_stop_listen_free()       { stop_conflict_env 9 x; export LARANODE_START_STOPPED=1; preflight; expect APACHE_OWNED "$APACHE_OWNED" 0; }
tf "stopped apache2 + its Listen 80 held by nginx: refused even with LARANODE_START_STOPPED=1" pf_stop_listen_busy_optin
tf "same, without the opt-in: still refused"                                                   pf_stop_listen_busy_noflag
t  "the refusal names the real conflict (port + holder), not the opt-in"                       pf_stop_listen_msg
t  "Listen 443 inside the ssl IfModule is not a conflict"                                      pf_stop_ssl_block_ignored
t  "stopped apache2 whose ports are free + opt-in: accepted"                                   pf_stop_listen_free

wb_rerun_rollback() { wb_setup 0 1 8080; echo OLDVHOST > "$AD/sites-available/laranode.conf"; : > "$AD/sites-enabled/laranode.conf"; CONFTEST_FAIL=1
  ( phase_webserver ) >/dev/null 2>&1 && return 1
  grep -qx OLDVHOST "$AD/sites-available/laranode.conf" && [ -e "$AD/sites-enabled/laranode.conf" ] && cmp -s "$AD/ports.conf" "$AD/ports.conf.orig"; }
t "failed re-run on a pre-existing Apache restores the previous working panel vhost" wb_rerun_rollback

# ==============================================================================
# Round 3 (review of b11daf2)
# ==============================================================================

# ---- 1. policy-rc.d guard: marked, cleaned when stale, never removed when not ours ----
echo "=== policy-rc.d guard ==="
PG_MARK='laranode-installer policy-rc.d guard'
pg_setup() { base; PRC="$(mktemp -d)/policy-rc.d"; export LARANODE_POLICY_RC_D="$PRC"; }
dead_pid() { (exit 0) & local p=$!; wait "$p" 2>/dev/null; echo "$p"; }
pg_marked() { pg_setup; _policy_guard_on; grep -q "$PG_MARK" "$PRC" && grep -q 'exit 101' "$PRC" && [ "$_PRC_ADDED" = 1 ] \
  && _policy_guard_off && [ ! -e "$PRC" ]; }
pg_foreign_kept() { pg_setup; printf '#!/bin/sh\nexit 0\n' > "$PRC"; _policy_guard_on; _policy_guard_off; _policy_guard_clean_stale
  [ "$_PRC_ADDED" = 0 ] && [ "$(cat "$PRC")" = "$(printf '#!/bin/sh\nexit 0')" ]; }
pg_foreign_mark_like_kept() { pg_setup; printf '#!/bin/sh\n# mine, not laranode\nexit 101\n' > "$PRC"; _policy_guard_clean_stale; [ -e "$PRC" ]; }
pg_stale_cleaned() { pg_setup; printf '#!/bin/sh\n# %s pid=%s\nexit 101\n' "$PG_MARK" "$(dead_pid)" > "$PRC"; _policy_guard_clean_stale 2>/dev/null; [ ! -e "$PRC" ]; }
pg_live_kept()  { pg_setup; printf '#!/bin/sh\n# %s pid=%s\nexit 101\n' "$PG_MARK" "$$" > "$PRC"; _policy_guard_clean_stale 2>/dev/null; [ -e "$PRC" ]; }
pg_die_removes(){ pg_setup; ( _policy_guard_on; die boom ) >/dev/null 2>&1; [ ! -e "$PRC" ]; }
pg_signal() {  # pg_signal TERM|INT|HUP -> the guard is gone after the installer is signalled
  pg_setup
  # The installer signals ITSELF in a foreground subshell: a background job of a
  # non-interactive shell starts with SIGINT ignored, which would hide whether the trap
  # is installed. If the signal is not turned into an exit, the shell dies without
  # running its EXIT trap and the guard survives.
  ( source "$INSTALLER"; export LARANODE_POLICY_RC_D="$PRC"; _policy_guard_on; kill -"$1" "$BASHPID"; sleep 5 & wait $! ) >/dev/null 2>&1
  [ ! -e "$PRC" ] || { echo "guard survived SIG$1"; return 1; }
}
pg_sigkill_then_cleanup() {
  pg_setup
  # a separate process (not a subshell): the guard records the installer's own $$, which is
  # the process SIGKILL takes away
  export INSTALLER PRC
  bash -c 'source "$INSTALLER"; export LARANODE_POLICY_RC_D="$PRC"; _policy_guard_on; sleep 30' >/dev/null 2>&1 &
  local p=$! i
  for i in $(seq 1 60); do [ -e "$PRC" ] && break; sleep 0.1; done
  kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null
  [ -e "$PRC" ] || { echo "SIGKILL left nothing to clean (guard was never created?)"; return 1; }
  # the NEXT installer start removes what the killed one left behind
  _policy_guard_clean_stale 2>/dev/null; [ ! -e "$PRC" ]
}
pg_main_cleans_first() {
  pg_setup; printf '#!/bin/sh\n# %s pid=%s\nexit 101\n' "$PG_MARK" "$(dead_pid)" > "$PRC"
  MLOG=$(mktemp); detect_os() { :; }
  preflight() { [ -e "$PRC" ] && echo "stale-at-preflight" >> "$MLOG" || echo "clean-at-preflight" >> "$MLOG"; }
  phase_packages() { :; }; phase_fetch_panel() { :; }; phase_database() { :; }; phase_webserver() { :; }; phase_php_node() { :; }
  phase_app() { :; }; phase_services() { :; }; phase_summary() { :; }
  main >/dev/null 2>&1
  [ "$(head -1 "$MLOG")" = clean-at-preflight ]
}
t  "guard file carries the marker, exit 101, and is removed by _policy_guard_off"        pg_marked
t  "a policy-rc.d that is not ours is never replaced, removed or 'cleaned'"                pg_foreign_kept
t  "an unmarked policy-rc.d that merely looks similar is not cleaned"                      pg_foreign_mark_like_kept
pg_foreign_swapped_in() {   # the owner drops their own policy-rc.d while our guard is up: off must not delete it
  pg_setup; _policy_guard_on; [ -e "$PRC" ] || { echo "guard not created"; return 1; }
  printf '#!/bin/sh\n# owner policy\nexit 101\n' > "$PRC"
  _policy_guard_off; [ -f "$PRC" ] && grep -q 'owner policy' "$PRC"
}
t  "a policy-rc.d the owner put in place while our guard was up is not removed"            pg_foreign_swapped_in
t  "a stale marked guard (its installer is dead) is removed at the next start"             pg_stale_cleaned
t  "a marked guard whose installer is still alive is left alone"                           pg_live_kept
t  "die while the guard is on removes it"                                                  pg_die_removes
t  "SIGTERM while the guard is on removes it"                                              pg_signal TERM
t  "SIGINT while the guard is on removes it"                                               pg_signal INT
t  "SIGHUP while the guard is on removes it"                                               pg_signal HUP
t  "SIGKILL leaves the guard, the next start cleans it"                                    pg_sigkill_then_cleanup
t  "main cleans a stale guard BEFORE preflight (and before any apt call)"                  pg_main_cleans_first

# phase_webserver / the php package install use the marked guard, and never touch a foreign one
wb_guard_marked() { wb_setup 0 1 8080
  apt_install() { [ -e "$LARANODE_POLICY_RC_D" ] && grep -q "$PG_MARK" "$LARANODE_POLICY_RC_D" && echo guarded >> "$WLOG"; }
  ( phase_webserver ) >/dev/null 2>&1 || return 1
  [ "$(grep -c guarded "$WLOG")" = 2 ] && [ ! -e "$LARANODE_POLICY_RC_D" ]; }
wb_guard_foreign() { wb_setup 0 1 8080; printf '#!/bin/sh\nexit 0\n' > "$LARANODE_POLICY_RC_D"
  apt_install() { grep -q "$PG_MARK" "$LARANODE_POLICY_RC_D" && echo ours >> "$WLOG"; }
  ( phase_webserver ) >/dev/null 2>&1 || return 1
  ! grep -q ours "$WLOG" && [ "$(cat "$LARANODE_POLICY_RC_D")" = "$(printf '#!/bin/sh\nexit 0')" ]; }
t "phase_webserver wraps its apt installs in the MARKED guard and removes it"              wb_guard_marked
t "phase_webserver leaves a foreign policy-rc.d exactly as it was"                         wb_guard_foreign

# ---- 7. a live pre-existing php8.4-fpm must not be restarted by the extension postinsts ----
echo "=== php packages vs a live pre-existing php8.4-fpm ==="
pn_run() {  # pn_run <PHPFPM_OWNED>  -> phase_php_node with the world stubbed; PNLOG lists each apt_install and whether the guard was up
  base; PNLOG=$(mktemp); svc_stub; ACTIVE_UNITS="php8.4-fpm"
  PRC="$(mktemp -d)/policy-rc.d"; export LARANODE_POLICY_RC_D="$PRC"
  PHPFPM_OWNED=$1; APACHE_OWNED=0; IS_CLOUDPANEL=0; OS_ID=ubuntu; OS_VERSION=24.04
  apt_install() { echo "$([ -e "$PRC" ] && grep -q "$PG_MARK" "$PRC" && echo guarded || echo open) $*" >> "$PNLOG"; }
  add-apt-repository() { :; }; apt-get() { :; }; update-alternatives() { :; }; curl() { :; }
  node() { echo v22.1.0; }; php8.4() { :; }
  phase_php_node >/dev/null 2>&1
}
pn_pre_guarded() { pn_run 0; grep -q '^guarded php8.4 php8.4-fpm' "$PNLOG" && [ ! -e "$PRC" ]; }
pn_owned_open()  { pn_run 1; grep -q '^open php8.4 php8.4-fpm' "$PNLOG"; }
pn_other_open()  { pn_run 0; ! grep -E '^guarded (postgresql-client|nodejs)' "$PNLOG"; }
pn_die_unguards(){ pn_run 0; apt_install() { die "apt broke"; }; ( phase_php_node ) >/dev/null 2>&1; [ ! -e "$PRC" ]; }
t "pre-existing php8.4-fpm: the php/extension install runs under the marked guard, guard removed after" pn_pre_guarded
t "php8.4-fpm that we installed: no guard (nothing live to protect)"                      pn_owned_open
t "only the php packages are guarded, not postgresql-client or nodejs"                    pn_other_open
t "a failing php install still removes the guard"                                         pn_die_unguards

# ---- 2/3. rollback after the reload, and of the modules we enabled ----
echo "=== webserver rollback after reload, modules rolled back and recorded ==="
rb_ok() { cmp -s "$AD/ports.conf" "$AD/ports.conf.orig" && [ ! -e "$AD/sites-enabled/laranode.conf" ] && [ ! -e "$AD/sites-available/laranode.conf" ]; }
mods_dismodded() { local m; for m in "$@"; do grep -qx "a2dismod $m" "$WLOG" || { echo "no a2dismod $m"; return 1; }; done; }
wb_rb_nolisten() { wb_setup 0 1 8080; ss() { :; }
  ( phase_webserver ) >/dev/null 2>&1 && return 1
  rb_ok && [ "$(grep -cx 'reload apache2' "$SVC_LOG")" = 2 ] && ! grep -q '^start' "$SVC_LOG" && mods_dismodded proxy proxy_fcgi rewrite; }
wb_rb_notactive() { wb_setup 0 1 8080
  svc_active() { ! grep -qx 'reload apache2' "$SVC_LOG"; }   # up until the first reload, down after it
  ( phase_webserver ) >/dev/null 2>&1 && return 1
  rb_ok && ! grep -q '^start' "$SVC_LOG" && [ "$(grep -cx 'reload apache2' "$SVC_LOG")" = 2 ] && mods_dismodded proxy proxy_fcgi rewrite; }
wb_rb_stopped_stays_stopped() { wb_setup 0 0 8080; ss() { :; }
  ( phase_webserver ) >/dev/null 2>&1 && return 1
  rb_ok && grep -qx 'stop apache2' "$SVC_LOG" && mods_dismodded proxy proxy_fcgi rewrite; }
wb_rb_late_die() { wb_setup 0 1 8080; _configure_firewall() { die "firewall boom"; }
  ( phase_webserver ) >/dev/null 2>&1 && return 1
  rb_ok && mods_dismodded proxy proxy_fcgi rewrite; }
wb_rb_a2ensite() { wb_setup 0 1 8080; a2ensite() { return 1; }
  ( phase_webserver ) >/dev/null 2>&1 && return 1
  rb_ok && mods_dismodded proxy proxy_fcgi rewrite && [ ! -s "$AD/mods.state" ]; }
wb_rb_midloop() { wb_setup 0 1 8080; a2enmod() { echo "a2enmod $*" >> "$WLOG"; [ "$1" != proxy_fcgi ]; }
  ( phase_webserver ) >/dev/null 2>&1 && return 1
  mods_dismodded proxy && ! grep -qxE 'a2dismod (proxy_fcgi|rewrite)' "$WLOG" && rb_ok; }
wb_rb_only_ours() { wb_setup 0 1 8080; ENABLED_MODS=" proxy rewrite "; ss() { :; }
  ( phase_webserver ) >/dev/null 2>&1 && return 1
  mods_dismodded proxy_fcgi && ! grep -qxE 'a2dismod (proxy|rewrite)' "$WLOG"; }
wb_owned_no_rb() { wb_setup 1 0 8080; ss() { :; }; ( phase_webserver ) >/dev/null 2>&1 && return 1
  ! grep -q a2dismod "$WLOG" && ! cmp -s "$AD/ports.conf" "$AD/ports.conf.orig"; }
wb_state_persists() { wb_setup 0 1 8080; ( phase_webserver ) >/dev/null 2>&1 || return 1
  [ "$(sort -u "$AD/mods.state" | tr '\n' ' ')" = "proxy proxy_fcgi rewrite " ]; }
wb_state_to_manifest() { mf_setup; export LARANODE_APACHE_MODS_STATE="$(mktemp)"; printf 'proxy\nproxy_fcgi\n' > "$LARANODE_APACHE_MODS_STATE"
  APACHE_MODS_ENABLED=""; write_service_manifest
  grep -q '"apache_modules_enabled":\["proxy","proxy_fcgi"\]' "$LARANODE_MANIFEST_FILE" && [ ! -s "$LARANODE_APACHE_MODS_STATE" ]; }
t "reload ok but the listener never opens: files, modules restored, Apache reloaded again"   wb_rb_nolisten
t "reload ok but apache2 is not active afterwards: files and modules restored, never started" wb_rb_notactive
t "a stopped Apache we started (opt-in) is stopped again when the install fails"             wb_rb_stopped_stays_stopped
t "any later die inside the phase rolls the pre-existing Apache back"                        wb_rb_late_die
t "a die after a2enmod (a2ensite fails): modules dismodded, record cleared"                  wb_rb_a2ensite
t "a die in the middle of the module loop dismods what was already enabled"                  wb_rb_midloop
t "rollback dismods only the modules THIS run enabled"                                       wb_rb_only_ours
t "an Apache we installed is not rolled back (it is ours)"                                   wb_owned_no_rb
t "enabled modules are persisted at once (state file), before any later phase"               wb_state_persists
t "the manifest unions the state file, then clears it"                                       wb_state_to_manifest

# ---- 4. no apt, no iproute2 before the plan is confirmed: /proc/net/tcp fallback ----
echo "=== port probe without ss ==="
proc_setup() {  # a host without iproute2: listeners come from /proc/net/tcp{,6}
  base; source "$INSTALLER"; log() { :; }; warn() { :; }; have_cmd() { return 1; }
  _have_ss() { return 1; }
  PD=$(mktemp -d); mkdir -p "$PD/net" "$PD/proc"; export LARANODE_PROC_NET_DIR="$PD/net" LARANODE_PROC_DIR="$PD/proc"
  H='  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode'
  { echo "$H"
    echo '   0: 00000000:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1234 1 0000000000000000 100 0 0 10 0'
    echo '   1: 0100007F:1F90 0100007F:ABCD 01 00000000:00000000 00:00000000 00000000     0        0 5555 1 0000000000000000 100 0 0 10 0'
    echo '   2: 0100007F:2328 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 7777 1 0000000000000000 100 0 0 10 0'; } > "$PD/net/tcp"
  { echo "$H"
    echo '   0: 00000000000000000000000000000000:1F91 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 4321 1 0000000000000000 100 0 0 10 0'; } > "$PD/net/tcp6"
  mkdir -p "$PD/proc/4242/fd" "$PD/proc/99/fd"; echo apache2 > "$PD/proc/4242/comm"; echo python3 > "$PD/proc/99/comm"
  ln -s 'socket:[1234]' "$PD/proc/4242/fd/3" 2>/dev/null; ln -s 'socket:[4321]' "$PD/proc/99/fd/5" 2>/dev/null
  HAVE_SYMLINKS=0; [ -L "$PD/proc/4242/fd/3" ] && HAVE_SYMLINKS=1
}
pr_busy_v4()      { proc_setup; port_in_use 80; }
pr_busy_v4_high() { proc_setup; port_in_use 9000; }           # 0x2328 listening on 127.0.0.1
pr_busy_v6()      { proc_setup; port_in_use 8081; }
pr_free_est()     { proc_setup; ! port_in_use 8080; }         # 8080 is only an ESTABLISHED connection
pr_free_none()    { proc_setup; ! port_in_use 8099; }
pr_no_tcp6()      { proc_setup; rm -f "$PD/net/tcp6"; port_in_use 80 && ! port_in_use 8081; }
pr_holder()       { proc_setup; [ "$HAVE_SYMLINKS" = 1 ] || { echo "(no symlinks here: skipped)"; return 0; }; [ "$(_port_holder 80)" = apache2 ] && [ "$(_port_holder 8081)" = python3 ]; }
pr_holder_unknown(){ proc_setup; [ "$(_port_holder 9000)" = "another process" ]; }
pr_probe_missing(){ proc_setup; rm -f "$PD/net/tcp" "$PD/net/tcp6"; pkg_installed() { return 1; }; pg_cluster_count() { echo 0; }; preflight; }
pr_preflight_busy() { proc_setup; pkg_installed() { return 1; }; pg_cluster_count() { echo 0; }; export LARANODE_HTTP_PORT=8081 LARANODE_MANIFEST_FILE=/nonexistent
  out=$( (preflight) 2>&1 ); [ $? -ne 0 ] && printf '%s' "$out" | grep -q '8081'; }
pr_preflight_own_rerun() { proc_setup; [ "$HAVE_SYMLINKS" = 1 ] || { echo "(no symlinks here: skipped)"; return 0; }
  pkg_installed() { [ "$1" = apache2 ]; }; svc_active() { [ "$1" = apache2 ]; }; pg_cluster_count() { echo 0; }
  export LARANODE_HTTP_PORT=80 LARANODE_MANIFEST_FILE=/nonexistent; _panel_vhost_enabled() { return 0; }; preflight; }
mn_no_apt_before_plan() { base; _have_ss() { return 1; }; MLOG=$(mktemp); detect_os() { :; }
  apt-get() { echo "apt-get $*" >> "$MLOG"; }; apt_install() { echo "apt_install $*" >> "$MLOG"; }
  preflight() { echo "PREFLIGHT" >> "$MLOG"; }
  phase_packages() { :; }; phase_fetch_panel() { :; }; phase_database() { :; }; phase_webserver() { :; }; phase_php_node() { :; }
  phase_app() { :; }; phase_services() { :; }; phase_summary() { :; }
  main >/dev/null 2>&1
  [ "$(head -1 "$MLOG")" = PREFLIGHT ] && ! grep -q apt "$MLOG"; }
t  "no ss: a v4 listener on :80 is found via /proc/net/tcp"                               pr_busy_v4
t  "no ss: a listener on a high port (0x2328) is found"                                    pr_busy_v4_high
t  "no ss: an IPv6-only listener (tcp6) is found"                                          pr_busy_v6
t  "no ss: an ESTABLISHED connection is not a listener"                                    pr_free_est
t  "no ss: an unused port is free"                                                         pr_free_none
t  "no ss: a missing tcp6 file is fine"                                                    pr_no_tcp6
t  "no ss: the holder's name is found through /proc/<pid>/fd"                               pr_holder
t  "no ss: an unknown holder reads 'another process'"                                      pr_holder_unknown
tf "neither ss nor /proc/net/tcp: refused (every port would read free)"                    pr_probe_missing
t  "no ss: a busy panel port is still refused, naming the port"                            pr_preflight_busy
t  "no ss: the panel's own Apache on a re-run is still accepted (holder from /proc)"       pr_preflight_own_rerun
t  "main: nothing runs apt before preflight (no apt-get update, no iproute2) when ss is missing" mn_no_apt_before_plan
# ==== round 4 =================================================================================
# ---- 2. a dual-stack listener (tcp AND tcp6) must not read FREE (SIGPIPE under pipefail) ----
echo "=== port probe: several listener inodes (tcp + tcp6) ==="
proc_dual() {  # port 80 listens on v4 (inodes 1234, 1235) AND v6 (4400); no ss
  proc_setup
  H='  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode'
  { echo "$H"
    echo '   0: 00000000:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1234 1 0000000000000000 100 0 0 10 0'
    echo '   1: 0100007F:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1235 1 0000000000000000 100 0 0 10 0'; } > "$PD/net/tcp"
  { echo "$H"
    echo '   0: 00000000000000000000000000000000:0050 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 4400 1 0000000000000000 100 0 0 10 0'; } > "$PD/net/tcp6"
}
pr_dual_busy() { proc_dual; local i; for i in $(seq 1 200); do port_in_use 80 || { echo "iteration $i: :80 read FREE with tcp+tcp6 listeners"; return 1; }; done; }
pr_dual_v6_only_busy() { proc_dual; : > "$PD/net/tcp"; echo "$H" > "$PD/net/tcp"; local i; for i in $(seq 1 50); do port_in_use 80 || return 1; done; }
pr_dual_free() { proc_dual; local i; for i in $(seq 1 50); do ! port_in_use 8099 || return 1; done; }
pr_dual_holder() { proc_dual; [ "$HAVE_SYMLINKS" = 1 ] || { echo "(no symlinks here: skipped)"; return 0; }
  ln -s 'socket:[1235]' "$PD/proc/4242/fd/4" 2>/dev/null; [ "$(_port_holder 80)" = apache2 ]; }
pr_dual_inodes() { proc_dual; [ "$(_proc_listen_inodes 80 | tr '\n' ' ')" = "1234 1235 4400 " ]; }
t "no ss: :80 held on tcp (2 sockets) AND tcp6 reads busy, 200 times (no SIGPIPE under pipefail)" pr_dual_busy
t "no ss: a tcp6-only listener beside an empty tcp reads busy"                                     pr_dual_v6_only_busy
t "no ss: an unused port stays free with both tables populated"                                    pr_dual_free
t "no ss: _proc_listen_inodes returns every inode of tcp then tcp6"                                pr_dual_inodes
t "no ss: _port_holder walks several inodes"                                                       pr_dual_holder
seam_probe_proc() { base; ss() { return 0; }; command() { [ "$1" = -v ] && [ "$2" = ss ] && return 0; builtin command "$@"; }; _have_ss || return 1
  LARANODE_PROBE_PROC=1; ! _have_ss; }
t "LARANODE_PROBE_PROC=1 forces the /proc probe even where ss exists"                                seam_probe_proc

# ---- 1. the rollback matrix: was running x reload reached x where it failed ----
echo "=== rollback matrix (a running pre-existing Apache is NEVER stopped) ==="
wb_fail() {  # wb_fail <was_active 0|1> <failpoint> -> runs the phase, expects it to die; SVC_LOG/WLOG/AD for the checks
  wb_setup 0 "$1" 8080
  case "$2" in
    configtest) CONFTEST_FAIL=1;;
    a2ensite)   a2ensite() { return 1; };;
    a2enmod)    a2enmod() { echo "a2enmod $*" >> "$WLOG"; return 1; };;
    reload)     systemctl() { echo "$*" >> "$SVC_LOG"; [ "$1" != reload ]; };;
    listener)   ss() { :; };;
    late)       _configure_firewall() { die "firewall boom"; };;
  esac
  ( phase_webserver ) >/dev/null 2>&1 && { echo "phase unexpectedly succeeded"; return 1; }
  return 0
}
no_stop()      { ! grep -q '^stop' "$SVC_LOG" || { echo "systemctl stop was called:"; cat "$SVC_LOG"; return 1; }; }
no_systemctl() { [ ! -s "$SVC_LOG" ] || { echo "systemctl was called:"; cat "$SVC_LOG"; return 1; }; }
# running before, the reload was never reached: the owner's Apache is untouched, so is its unit
wb_m_run_pre()    { wb_fail 1 "$1" && rb_ok && no_systemctl; }
# running before, our config was reloaded: reload it back, never stop
wb_m_run_post()   { wb_fail 1 "$1" && rb_ok && no_stop && [ "$(grep -cx 'reload apache2' "$SVC_LOG")" -ge 2 ] && ! grep -qE '^(start|restart)' "$SVC_LOG"; }
# stopped before (opt-in start), the start was never reached: nothing to stop
wb_m_stop_pre()   { wb_fail 0 "$1" && rb_ok && no_systemctl; }
# stopped before, we started it: stop it again
wb_m_stop_post()  { wb_fail 0 "$1" && rb_ok && grep -qx 'stop apache2' "$SVC_LOG" && [ "$(grep -c '^stop' "$SVC_LOG")" = 1 ]; }
for fp in configtest a2ensite a2enmod; do
  t "running Apache, $fp fails before the reload: files back, systemctl never called (no stop!)" wb_m_run_pre "$fp"
  t "stopped Apache, $fp fails before the start: files back, systemctl never called"             wb_m_stop_pre "$fp"
done
for fp in reload listener late; do
  t "running Apache, $fp fails after our config was loaded: reloaded back, never stopped"        wb_m_run_post "$fp"
done
for fp in listener late; do
  t "stopped Apache we started, $fp fails: stopped again, exactly once"                          wb_m_stop_post "$fp"
done
wb_conftest_never_stops() { wb_setup 0 1 8080; CONFTEST_FAIL=1; ( phase_webserver ) >/dev/null 2>&1 && return 1
  no_stop && ! grep -q '^reload' "$SVC_LOG"; }
t "failed configtest on a running pre-existing Apache: no stop, no reload"                       wb_conftest_never_stops
wb_ok_no_journal() { wb_setup 0 1 8080; ( phase_webserver ) >/dev/null 2>&1 || return 1; [ ! -e "$LARANODE_ROLLBACK_DIR" ] && ! grep -q '^stop' "$SVC_LOG"; }
wb_owned_no_journal() { wb_setup 1 0 80; ( phase_webserver ) >/dev/null 2>&1 || return 1; [ ! -e "$LARANODE_ROLLBACK_DIR" ]; }
wb_journal_during() { wb_setup 0 1 8080; JOUT=$(mktemp)
  apachectl() { local j="$LARANODE_ROLLBACK_DIR"; [ -f "$j/complete" ] && [ -f "$j/pid" ] && cmp -s "$j/ports.conf" "$AD/ports.conf.orig" && echo yes > "$JOUT"; return 0; }
  ( phase_webserver ) >/dev/null 2>&1 || return 1; [ "$(cat "$JOUT" 2>/dev/null)" = yes ]; }
t "a successful install leaves no rollback journal"                                              wb_ok_no_journal
t "an Apache we installed is ours: no journal at all"                                            wb_owned_no_journal
t "the journal (original ports.conf, pid, complete) exists before the config is tested"          wb_journal_during

# ---- 5. SIGKILL: the next start rolls the half-configured Apache back ----
echo "=== journal: a killed installer is recovered at the next start ==="
wb_killed() {  # run the phase in a subshell that dies by SIGKILL at configtest, as a separate "installer pid"
  wb_setup 0 "${1:-1}" 8080
  ( export LARANODE_INSTALLER_PID=$BASHPID; apachectl() { kill -9 "$BASHPID"; }; phase_webserver ) >/dev/null 2>&1
  [ $? -eq 137 ] || { echo "the subshell was not SIGKILLed (rc=$?)"; return 1; }
}
jr_recovers() { wb_killed 1 || return 1
  [ -d "$LARANODE_ROLLBACK_DIR" ] || { echo "no journal left by the killed installer"; return 1; }
  ! cmp -s "$AD/ports.conf" "$AD/ports.conf.orig" || { echo "premise: ports.conf was never changed"; return 1; }
  : > "$WLOG"; : > "$SVC_LOG"
  ( _apache_journal_recover ) >/dev/null 2>&1 || { echo "recovery failed"; return 1; }
  rb_ok && mods_dismodded proxy proxy_fcgi rewrite && no_systemctl && [ ! -e "$LARANODE_ROLLBACK_DIR" ]; }
jr_recovers_stopped() { wb_killed 0 || return 1; : > "$SVC_LOG"; ( _apache_journal_recover ) >/dev/null 2>&1 || return 1
  rb_ok && no_systemctl && [ ! -e "$LARANODE_ROLLBACK_DIR" ]; }
jr_live_pid_refused() { wb_setup 0 1 8080; sleep() { command sleep "$@"; }; command sleep 30 & local lp=$!
  ( export LARANODE_INSTALLER_PID=$lp; _apache_journal_open "$AD" "$AD/sites-available/laranode.conf" )
  cp -p "$AD/ports.conf" "$AD/ports.conf.keep"; echo "Listen 9999" >> "$AD/ports.conf"
  out=$( ( _apache_journal_recover ) 2>&1 ); local rc=$?
  kill "$lp" 2>/dev/null
  [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "$lp" && grep -qx 'Listen 9999' "$AD/ports.conf" && [ -d "$LARANODE_ROLLBACK_DIR" ]; }
jr_failed_restore_refuses() { wb_killed 1 || return 1
  out=$( ( cp() { return 1; }; _apache_journal_recover ) 2>&1 ); local rc=$?
  [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "$LARANODE_ROLLBACK_DIR" && [ -d "$LARANODE_ROLLBACK_DIR" ] && [ -s "$LARANODE_ROLLBACK_DIR/ports.conf" ]; }
jr_incomplete_discarded() { wb_setup 0 1 8080; mkdir -p "$LARANODE_ROLLBACK_DIR"; dead_pid > "$LARANODE_ROLLBACK_DIR/pid"
  echo "Listen 9999" >> "$AD/ports.conf"
  ( _apache_journal_recover ) >/dev/null 2>&1 && [ ! -e "$LARANODE_ROLLBACK_DIR" ] && grep -qx 'Listen 9999' "$AD/ports.conf" && no_systemctl; }
jr_none_is_noop() { wb_setup 0 1 8080; ( _apache_journal_recover ) >/dev/null 2>&1 && no_systemctl && [ ! -e "$LARANODE_ROLLBACK_DIR" ]; }
jr_main_recovers_first() {
  base; MLOG=$(mktemp); detect_os() { :; }
  _apache_journal_recover() { echo RECOVER >> "$MLOG"; }
  preflight() { echo PREFLIGHT >> "$MLOG"; }
  phase_packages() { :; }; phase_fetch_panel() { :; }; phase_database() { :; }; phase_webserver() { :; }; phase_php_node() { :; }
  phase_app() { :; }; phase_services() { :; }; phase_summary() { :; }
  main >/dev/null 2>&1
  [ "$(head -2 "$MLOG" | tr '\n' ' ')" = "RECOVER PREFLIGHT " ]; }
t  "SIGKILL at configtest: the next start restores ports.conf, vhost and modules, calls no systemctl" jr_recovers
t  "SIGKILL on a stopped Apache we were starting: recovered, nothing started or stopped"               jr_recovers_stopped
t  "a journal whose installer is still alive is refused (two installers), nothing touched"             jr_live_pid_refused
t  "a restore that fails keeps the journal and refuses, naming where it is"                           jr_failed_restore_refuses
t  "a journal cut short before any change (no 'complete') is discarded"                               jr_incomplete_discarded
t  "no journal: recovery does nothing"                                                                jr_none_is_noop
t  "main recovers a killed install BEFORE preflight"                                                  jr_main_recovers_first

# ---- 3. the guard answers 0 once its installer is dead; 101 while it lives ----
echo "=== policy-rc.d guard: self-expiring ==="
pg_expiry_dead() { pg_setup; export LARANODE_INSTALLER_PID; LARANODE_INSTALLER_PID=$(dead_pid); _policy_guard_on; [ -e "$PRC" ] || return 1
  sh "$PRC" start apache2; [ $? -eq 0 ]; }
pg_expiry_live() { pg_setup; command sleep 30 & local lp=$!; export LARANODE_INSTALLER_PID=$lp; _policy_guard_on
  sh "$PRC" start apache2; local rc=$?; kill "$lp" 2>/dev/null; [ $rc -eq 101 ]; }
pg_expiry_stale_still_cleaned() { pg_setup; LARANODE_INSTALLER_PID=$(dead_pid); export LARANODE_INSTALLER_PID; _policy_guard_on; _PRC_ADDED=0
  ( unset LARANODE_INSTALLER_PID; _policy_guard_clean_stale 2>/dev/null ); [ ! -e "$PRC" ]; }
t "guard of a dead installer answers 0 (a service start is allowed again)"                pg_expiry_dead
t "guard of a live installer answers 101 (service starts held back)"                      pg_expiry_live
t "a dead installer's guard is still removed at the next start"                           pg_expiry_stale_still_cleaned

# ---- 4/7. signals: traps, deferral while a child runs, no abort of the cleanups ----
echo "=== signals and exit hooks ==="
sig_child() {  # sig_child INT|TERM|HUP: the signal arrives while a foreground child runs; the hook must run AFTER the child
  local D; D=$(mktemp -d); export D SIGN="$1"
  ( source "$INSTALLER"; hook() { [ -f "$D/child.done" ] && echo saw-child-done > "$D/hook"; }
    _add_exit_hook hook
    me=$BASHPID; ( command sleep 0.3; kill -"$SIGN" "$me" ) &
    sh -c 'sleep 1; touch "$D/child.done"'
    touch "$D/after" ) >/dev/null 2>&1
  local rc=$? want; case "$1" in INT) want=130;; TERM) want=143;; HUP) want=129;; esac
  [ -f "$D/hook" ] || { echo "hook did not run after the child (or at all)"; return 1; }
  [ ! -f "$D/after" ] || { echo "the script kept going after SIG$1"; return 1; }
  [ "$rc" = "$want" ] || { echo "exit status $rc, wanted $want"; return 1; }
}
sig_second_signal() {  # a second TERM while the cleanups run must not abort them
  local D; D=$(mktemp -d); export D
  ( source "$INSTALLER"; slow() { command sleep 1; echo slow > "$D/slow"; }; later() { echo later > "$D/later"; }
    _add_exit_hook slow; _add_exit_hook later
    me=$BASHPID; ( command sleep 0.2; kill -TERM "$me"; command sleep 0.4; kill -TERM "$me" ) &
    command sleep 5 & wait $! ) >/dev/null 2>&1
  [ -f "$D/slow" ] && [ -f "$D/later" ] || { echo "cleanups cut short: $(ls "$D" | tr '\n' ' ')"; return 1; }
}
hook_dedupe() { local D; D=$(mktemp -d); export D
  ( source "$INSTALLER"; h() { echo x >> "$D/runs"; }; _add_exit_hook h; _add_exit_hook h; _add_exit_hook h ) >/dev/null 2>&1
  [ "$(wc -l < "$D/runs")" = 1 ]; }
hook_order() { local D; D=$(mktemp -d); export D
  ( source "$INSTALLER"; a() { echo a >> "$D/o"; }; b() { echo b >> "$D/o"; }; _add_exit_hook a; _add_exit_hook b; _add_exit_hook a ) >/dev/null 2>&1
  [ "$(tr '\n' ' ' < "$D/o")" = "a b " ]; }
hook_failing_does_not_stop_next() { local D; D=$(mktemp -d); export D
  ( source "$INSTALLER"; bad() { return 1; }; good() { echo g > "$D/g"; }; _add_exit_hook bad; _add_exit_hook good ) >/dev/null 2>&1; [ -f "$D/g" ]; }
hook_keeps_exit_status() { ( source "$INSTALLER"; h() { return 0; }; _add_exit_hook h; exit 7 ) >/dev/null 2>&1; [ $? -eq 7 ]; }
t "SIGINT during a foreground child: deferred until it ends, hook runs after it, status 130" sig_child INT
t "SIGTERM during a foreground child: deferred until it ends, hook runs after it, status 143" sig_child TERM
t "SIGHUP during a foreground child: deferred until it ends, hook runs after it, status 129"  sig_child HUP
t "a second TERM while the exit hooks run does not abort the remaining cleanups"              sig_second_signal
t "the same hook registered three times runs once"                                            hook_dedupe
t "hooks run in registration order, a repeat does not reorder them"                           hook_order
t "a failing hook does not stop the next one"                                                 hook_failing_does_not_stop_next
t "the exit status survives the hooks"                                                        hook_keeps_exit_status

# ---- 3b. noclobber: a link planted at the policy-rc.d path is never written through ----
echo "=== guard creation never writes through a planted link ==="
pg_noclobber_link() { pg_setup; local T; T="$(mktemp -d)/victim"
  ln -s "$T" "$PRC" 2>/dev/null || { echo "(no symlinks here: skipped)"; return 0; }
  _policy_guard_on
  [ ! -e "$T" ] && [ "$_PRC_ADDED" = 0 ] && [ -L "$PRC" ]; }
t "a dangling link at the policy-rc.d path: no file is created through it, guard not claimed" pg_noclobber_link

# ---- 6. guard scope: every apt install on a host with pre-existing services ----
echo "=== apt_install guard scope ==="
ai_run() {  # ai_run "<PRE_UNITS>" CMD... ; AILOG gets "guarded|open" per real install
  base; AILOG=$(mktemp); PRC="$(mktemp -d)/policy-rc.d"; export LARANODE_POLICY_RC_D="$PRC"; PRE_UNITS="$1"; shift
  apt-get() { if [ "$2" = "-s" ]; then return 0; fi
    echo "$([ -e "$PRC" ] && grep -q "$PG_MARK" "$PRC" && echo guarded || echo open)" >> "$AILOG"; return "${APT_RC:-0}"; }
  "$@"
}
ai_guarded()   { ai_run "nginx.service" apt_install foo; [ "$(cat "$AILOG")" = guarded ] && [ ! -e "$PRC" ]; }
ai_open_none() { ai_run "" apt_install foo; [ "$(cat "$AILOG")" = open ]; }
ai_open_flag() { ai_run "nginx.service" env_apt_flag; [ "$(cat "$AILOG")" = open ]; }
env_apt_flag() { APT_ALLOW_SERVICE_START=1 apt_install foo; }
ai_nested()    { ai_run "nginx.service" ai_nested_body; }
ai_nested_body() { _policy_guard_on; apt_install foo; [ -e "$PRC" ] || { echo "inner apt_install took the outer guard away"; return 1; }
  _policy_guard_off; [ ! -e "$PRC" ] && [ "$(cat "$AILOG")" = guarded ]; }
ai_fail_unguards() { APT_RC=1; ai_run "nginx.service" apt_install foo; local rc=$?; [ $rc -ne 0 ] && [ ! -e "$PRC" ]; }
ai_foreign_kept() { ai_run "nginx.service" ai_foreign_body; }
ai_foreign_body() { printf '#!/bin/sh\nexit 0\n' > "$PRC"; apt_install foo; [ "$(cat "$PRC")" = "$(printf '#!/bin/sh\nexit 0')" ] && [ "$(cat "$AILOG")" = open ]; }
t "host with pre-existing services: an ordinary apt_install runs under the marked guard"        ai_guarded
t "no pre-existing services: no guard (a fresh host starts everything it installs)"             ai_open_none
t "APT_ALLOW_SERVICE_START=1: no guard (a new service has to start)"                            ai_open_flag
t "apt_install inside a guarded phase leaves the outer guard up"                                ai_nested
t "a failing apt-get still removes the guard and reports the failure"                           ai_fail_unguards
t "a foreign policy-rc.d is neither replaced nor removed by apt_install"                        ai_foreign_kept
pk_flags() {  # phase_packages: which installs may start services
  base; PKLOG=$(mktemp); OS_ID=ubuntu; IS_CLOUDPANEL=0
  apt_install() { echo "${APT_ALLOW_SERVICE_START:-0} $*" >> "$PKLOG"; }
  apt-get() { :; }; systemctl() { :; }
  phase_packages >/dev/null 2>&1
  grep -qx '1 cron' "$PKLOG" && grep -qx '1 sysstat' "$PKLOG" && grep -q '^0 git ' "$PKLOG" && grep -qx '0 software-properties-common' "$PKLOG"; }
my_flag() { base; PANEL_PATH=$(mktemp -d); : > "$PANEL_PATH/.env.example"; MYLOG=$(mktemp)
  apt_install() { echo "${APT_ALLOW_SERVICE_START:-0} $*" >> "$MYLOG"; }; systemctl() { return 0; }; mysql() { return 0; }; openssl() { echo pw; }; persist_secret() { :; }
  _mysql_branch; grep -qx '1 mysql-server' "$MYLOG"; }
pgf_flag() { pg_stubs; PG_PREEXISTING=0; ( _pgsql_branch ) >/dev/null 2>&1 || true; grep -qx '1 postgresql postgresql-client' "$APT_CALLS"; }
pgf_flag_apt() { pg_stubs; apt_install() { echo "${APT_ALLOW_SERVICE_START:-0} $*" >> "$APT_CALLS"; }; PG_PREEXISTING=0; ( _pgsql_branch ) >/dev/null 2>&1 || true; grep -qx '1 postgresql postgresql-client' "$APT_CALLS"; }
t "phase_packages: cron and sysstat may start (new services), base tools may not"                pk_flags
t "mysql-server (new service on a host with other services) may start"                           my_flag
t "a fresh PostgreSQL cluster may start; an existing cluster's server is never installed"        pgf_flag_apt


# ==== round 5 ====================================================================
# ---- 1. the journal knows whether THIS run started Apache ----
echo "=== journal: started_by_run (an Apache the owner started is never stopped) ==="
# stopped before; the owner (or a boot) starts their Apache while we are mid-run, then we die
sb_owner_started_inprocess() { wb_setup 0 0 8080
  apachectl() { ACTIVE_UNITS="apache2"; return 1; }      # configtest fails; meanwhile the owner's Apache came up
  ( phase_webserver ) >/dev/null 2>&1 && return 1
  rb_ok && no_stop && no_systemctl; }
# SIGKILL before our start; the owner's Apache is up by the time the next installer starts
sb_owner_started_recovery() { wb_killed 0 || return 1
  ACTIVE_UNITS="apache2"; : > "$SVC_LOG"
  ( _apache_journal_recover ) >/dev/null 2>&1 || { echo "recovery failed"; return 1; }
  rb_ok && no_stop && no_systemctl && [ ! -e "$LARANODE_ROLLBACK_DIR" ]; }
# SIGKILL AFTER we started the stopped Apache (marker written): recovery stops what we started
sb_we_started_recovery() { wb_setup 0 0 8080
  ( export LARANODE_INSTALLER_PID=$BASHPID; _configure_firewall() { kill -9 "$BASHPID"; }; phase_webserver ) >/dev/null 2>&1
  [ $? -eq 137 ] || { echo "the subshell was not SIGKILLed"; return 1; }
  [ -f "$LARANODE_ROLLBACK_DIR/started_by_run" ] || { echo "no started_by_run marker after the start"; return 1; }
  grep -qx 'start apache2' "$SVC_LOG" || { echo "premise: we never started apache2"; return 1; }
  ( _apache_journal_recover ) >/dev/null 2>&1 || { echo "recovery failed"; return 1; }
  grep -qx 'stop apache2' "$SVC_LOG" && [ "$(grep -c '^stop' "$SVC_LOG")" = 1 ] && [ ! -e "$LARANODE_ROLLBACK_DIR" ]; }
# a run that only reloads a running Apache never writes the marker
sb_marker_absent_when_running() { wb_setup 0 1 8080; JOUT=$(mktemp)
  _configure_firewall() { [ -f "$LARANODE_ROLLBACK_DIR/started_by_run" ] && echo bad > "$JOUT"; return 0; }
  ( phase_webserver ) >/dev/null 2>&1 || return 1
  [ ! -s "$JOUT" ] && [ ! -e "$LARANODE_ROLLBACK_DIR" ]; }
t "stopped Apache, the owner starts it mid-run, then we die: it is NOT stopped"                     sb_owner_started_inprocess
t "SIGKILL before our start, the owner's Apache is up at the next start: recovery does not stop it" sb_owner_started_recovery
t "SIGKILL after we started the stopped Apache: recovery stops exactly that one (marker present)"   sb_we_started_recovery
t "a running Apache we only reload never gets a started_by_run marker"                              sb_marker_absent_when_running

# ---- 2. the modules record of an earlier run survives a later run's rollback ----
echo "=== journal: modules enabled by an EARLIER run are not disabled by this run's rollback ==="
mo_run1_survive() { wb_setup 0 1 8080; ENABLED_MODS=" proxy proxy_fcgi rewrite "
  printf 'proxy\nproxy_fcgi\nrewrite\n' > "$LARANODE_APACHE_MODS_STATE"
  CONFTEST_FAIL=1; ( phase_webserver ) >/dev/null 2>&1 && return 1
  ! grep -q '^a2dismod' "$WLOG" || { echo "an earlier run's modules were disabled:"; cat "$WLOG"; return 1; }
  [ "$(tr '\n' ' ' < "$LARANODE_APACHE_MODS_STATE")" = "proxy proxy_fcgi rewrite " ]; }
mo_only_new_disabled() { wb_setup 0 1 8080; ENABLED_MODS=" proxy "
  printf 'proxy\n' > "$LARANODE_APACHE_MODS_STATE"
  CONFTEST_FAIL=1; ( phase_webserver ) >/dev/null 2>&1 && return 1
  mods_dismodded rewrite proxy_fcgi && ! grep -qx 'a2dismod proxy' "$WLOG" \
  && [ "$(tr '\n' ' ' < "$LARANODE_APACHE_MODS_STATE")" = "proxy " ]; }
mo_recover_keeps_run1() { wb_setup 0 1 8080; ENABLED_MODS=" proxy proxy_fcgi rewrite "
  printf 'proxy\nproxy_fcgi\nrewrite\n' > "$LARANODE_APACHE_MODS_STATE"
  ( export LARANODE_INSTALLER_PID=$BASHPID; apachectl() { kill -9 "$BASHPID"; }; phase_webserver ) >/dev/null 2>&1
  : > "$WLOG"; ( _apache_journal_recover ) >/dev/null 2>&1 || return 1
  ! grep -q '^a2dismod' "$WLOG" && [ "$(wc -l < "$LARANODE_APACHE_MODS_STATE")" = 3 ]; }
mo_failed_dismod_still_kept() { wb_setup 0 1 8080; ENABLED_MODS=" "
  CONFTEST_FAIL=1; a2dismod() { return 1; }; ( phase_webserver ) >/dev/null 2>&1 && return 1
  [ -f "$LARANODE_APACHE_MODS_STATE" ] && [ "$(wc -l < "$LARANODE_APACHE_MODS_STATE")" = 3 ]; }
t "run 2 fails after run 1 enabled modules: run 1's modules stay enabled and recorded"    mo_run1_survive
t "only the modules enabled since the journal opened are disabled, the rest stay recorded" mo_only_new_disabled
t "a killed run 2 is recovered without disabling run 1's modules"                         mo_recover_keeps_run1
t "a module that cannot be disabled stays recorded (as before)"                           mo_failed_dismod_still_kept

# ---- 3. pid reuse: a pid alone does not identify an installer ----
echo "=== pid + start time identify an installer (a reused pid is not it) ==="
pr_start_stable() { base; command sleep 30 & local p1=$!; command sleep 0.2; command sleep 30 & local p2=$!
  local a b c; a=$(_pid_start "$p1"); b=$(_pid_start "$p1"); c=$(_pid_start "$p2"); kill "$p1" "$p2" 2>/dev/null
  [ -n "$a" ] && [ "$a" = "$b" ] && [ -n "$c" ] && [ "$a" != "$c" ]; }
pr_start_dead_empty() { base; [ -z "$(_pid_start "$(dead_pid)")" ]; }
pr_alive_match() { base; command sleep 30 & local lp=$!; local s; s=$(_pid_start "$lp"); _pid_alive "$lp" "$s"; local rc=$?; kill "$lp" 2>/dev/null; [ $rc -eq 0 ]; }
pr_alive_mismatch() { base; command sleep 30 & local lp=$!; _pid_alive "$lp" "boot.123"; local rc=$?; kill "$lp" 2>/dev/null; [ $rc -ne 0 ]; }
pr_alive_nostart() { base; command sleep 30 & local lp=$!; _pid_alive "$lp" ""; local rc=$?; kill "$lp" 2>/dev/null; [ $rc -eq 0 ]; }
pr_alive_dead() { base; ! _pid_alive "$(dead_pid)" ""; }
t "_pid_start is stable for one process and differs between processes"                    pr_start_stable
t "_pid_start of a dead pid is empty"                                                     pr_start_dead_empty
t "_pid_alive: live pid + its own start token is alive"                                   pr_alive_match
t "_pid_alive: live pid + another start token is NOT alive (pid reused)"                  pr_alive_mismatch
t "_pid_alive: a record without a start token falls back to kill -0 (old guards/journals)" pr_alive_nostart
t "_pid_alive: dead pid is not alive"                                                     pr_alive_dead
# the guard
pg_reuse_answers_0() { pg_setup; command sleep 30 & local lp=$!
  export LARANODE_INSTALLER_PID=$lp LARANODE_INSTALLER_START="boot.reused"; _policy_guard_on; [ -e "$PRC" ] || return 1
  sh "$PRC" start apache2; local rc=$?; kill "$lp" 2>/dev/null; [ $rc -eq 0 ]; }
pg_real_still_101() { pg_setup; command sleep 30 & local lp=$!
  export LARANODE_INSTALLER_PID=$lp; unset LARANODE_INSTALLER_START; _policy_guard_on
  sh "$PRC" start apache2; local rc=$?; kill "$lp" 2>/dev/null; [ $rc -eq 101 ]; }
pg_reuse_cleaned() { pg_setup; command sleep 30 & local lp=$!
  export LARANODE_INSTALLER_PID=$lp LARANODE_INSTALLER_START="boot.reused"; _policy_guard_on; _PRC_ADDED=0
  ( unset LARANODE_INSTALLER_PID LARANODE_INSTALLER_START; _policy_guard_clean_stale 2>/dev/null ); kill "$lp" 2>/dev/null
  [ ! -e "$PRC" ]; }
pg_live_not_cleaned() { pg_setup; command sleep 30 & local lp=$!
  export LARANODE_INSTALLER_PID=$lp; unset LARANODE_INSTALLER_START; _policy_guard_on; _PRC_ADDED=0
  ( unset LARANODE_INSTALLER_PID LARANODE_INSTALLER_START; _policy_guard_clean_stale 2>/dev/null ); kill "$lp" 2>/dev/null
  [ -e "$PRC" ]; }
pg_old_format_live_kept() { pg_setup; command sleep 30 & local lp=$!   # a guard written by an older installer: pid only
  printf '#!/bin/sh\n# %s pid=%s\nkill -0 %s 2>/dev/null && exit 101\nexit 0\n' "$_PG_MARK" "$lp" "$lp" > "$PRC"
  ( _policy_guard_clean_stale 2>/dev/null ); kill "$lp" 2>/dev/null; [ -e "$PRC" ]; }
t "guard whose pid was REUSED by another process answers 0 (starts allowed)"              pg_reuse_answers_0
t "guard of the real live installer still answers 101"                                    pg_real_still_101
t "start cleanup removes a guard whose pid was reused"                                    pg_reuse_cleaned
t "start cleanup keeps the guard of a really running installer"                           pg_live_not_cleaned
t "start cleanup keeps an old-format (pid only) guard of a live pid"                      pg_old_format_live_kept
# the journal
jr_reuse_recovers() { wb_setup 0 1 8080; command sleep 30 & local lp=$!
  ( export LARANODE_INSTALLER_PID=$lp LARANODE_INSTALLER_START="boot.reused"; _apache_journal_open "$AD" "$AD/sites-available/laranode.conf" )
  echo "Listen 9999" >> "$AD/ports.conf"
  ( _apache_journal_recover ) >/dev/null 2>&1; local rc=$?; kill "$lp" 2>/dev/null
  [ $rc -eq 0 ] && rb_ok && [ ! -e "$LARANODE_ROLLBACK_DIR" ]; }
jr_old_journal_live_refused() { wb_setup 0 1 8080; command sleep 30 & local lp=$!
  ( export LARANODE_INSTALLER_PID=$lp; _apache_journal_open "$AD" "$AD/sites-available/laranode.conf" )
  rm -f "$LARANODE_ROLLBACK_DIR/start"            # a journal from an older installer: pid only
  ( _apache_journal_recover ) >/dev/null 2>&1; local rc=$?; kill "$lp" 2>/dev/null
  [ $rc -ne 0 ] && [ -d "$LARANODE_ROLLBACK_DIR" ]; }
t "a journal whose pid was reused by another process is recovered, not refused"           jr_reuse_recovers
t "a journal without a start token and a live pid is still refused (old journals)"        jr_old_journal_live_refused

# ---- 4. the safety seams are not read from the inherited environment ----
echo "=== env sanitising: test seams only with LARANODE_INSTALLER_TEST=1 ==="
SEAMS="APT_ALLOW_SERVICE_START LARANODE_ROLLBACK_DIR LARANODE_INSTALLER_PID LARANODE_INSTALLER_START LARANODE_POLICY_RC_D LARANODE_APACHE_DIR LARANODE_APACHE_MODS_STATE LARANODE_OS_RELEASE_FILE LARANODE_PVE_DIR LARANODE_CLP_DIR LARANODE_CRON_DIR LARANODE_PROC_NET_DIR LARANODE_PROC_DIR"
seam_env() { local v; for v in $SEAMS; do echo "$v=/tmp/inherited-$v"; done; }
env_unset_without_flag() { local out
  out=$(env -u LARANODE_INSTALLER_TEST $(seam_env) bash -c "source '$INSTALLER'; for v in $SEAMS; do [ -z \"\${!v+x}\" ] || echo \"STILL SET: \$v\"; done" 2>&1)
  [ -z "$out" ] || { echo "$out"; return 1; }; }
env_kept_with_flag() { local out
  out=$(env LARANODE_INSTALLER_TEST=1 $(seam_env) bash -c "source '$INSTALLER'; for v in $SEAMS; do [ -n \"\${!v+x}\" ] || echo \"LOST: \$v\"; done" 2>&1)
  [ -z "$out" ] || { echo "$out"; return 1; }; }
env_journal_dir_default() { local d
  d=$(env -u LARANODE_INSTALLER_TEST LARANODE_ROLLBACK_DIR=/tmp/evil-rollback bash -c "source '$INSTALLER'; _journal_dir")
  [ "$d" = /etc/laranode/apache-rollback ]; }
env_apt_flag_ignored() { local o
  o=$(env -u LARANODE_INSTALLER_TEST APT_ALLOW_SERVICE_START=1 bash -c "source '$INSTALLER'; echo \"flag=\${APT_ALLOW_SERVICE_START:-0}\"")
  [ "$o" = "flag=0" ]; }
env_documented_overrides_kept() { local o
  o=$(env -u LARANODE_INSTALLER_TEST LARANODE_MANIFEST_FILE=/x/m.json LARANODE_PROBE_PROC=1 LARANODE_OS=debian bash -c "source '$INSTALLER'; echo \"\${LARANODE_MANIFEST_FILE:-} \${LARANODE_PROBE_PROC:-} \${LARANODE_OS:-}\"")
  [ "$o" = "/x/m.json 1 debian" ]; }
t "every test seam is dropped from the inherited environment (no LARANODE_INSTALLER_TEST)"  env_unset_without_flag
t "LARANODE_INSTALLER_TEST=1 keeps the seams (the unit tests need them)"                    env_kept_with_flag
t "an inherited LARANODE_ROLLBACK_DIR cannot point the rollback's rm -rf elsewhere"         env_journal_dir_default
t "an inherited APT_ALLOW_SERVICE_START=1 cannot unguard the base apt installs"             env_apt_flag_ignored
t "the documented overrides (MANIFEST_FILE, PROBE_PROC, LARANODE_OS) are still honoured"    env_documented_overrides_kept


# ---- root never executes PHP that lives in the panel tree --------------------
# (www-data can write parts of the tree; Laravel `require`s bootstrap/cache/*.php on every
# artisan call, so a root artisan/composer run would execute whatever was planted there)
priv_artisan_via_runuser() { local out
  out=$(bash -c "
    source '$INSTALLER'
    runuser() { printf 'runuser %s\n' \"\$*\"; }
    _artisan migrate --force")
  case "$out" in
    'runuser -u laranode_ln -- env -C '*' HOME=/home/laranode_ln'*' /usr/bin/php8.4 artisan migrate --force') : ;;
    *) echo "unexpected command: $out"; return 1 ;;
  esac; }
priv_no_root_php_lines() { local bad
  # every line that runs artisan or composer must go through the panel-user helpers
  bad=$(grep -nE '(^|[^[:alnum:]_])/usr/bin/php8\.4 +(artisan|/usr/local/bin/composer)' "$INSTALLER" \
        | grep -vE '_as_panel_user|sudo -u laranode_ln' || true)
  [ -z "$bad" ] || { echo "root runs PHP in the panel tree:"; echo "$bad"; return 1; }
  grep -qE '^[[:space:]]+(artisan|php8\.4 artisan|php artisan) ' "$INSTALLER" && return 1
  return 0; }
priv_settle_not_web_writable() { local body
  body=$(bash -c "source '$INSTALLER'; declare -f _settle_permissions")
  [ -n "$body" ] || return 1
  case "$body" in *bootstrap/cache*) echo "settle touches bootstrap/cache"; return 1 ;; esac; }
priv_prepare_wipes_caches() { local body
  body=$(bash -c "source '$INSTALLER'; declare -f _prepare_panel_tree")
  case "$body" in *'chown -R'*laranode_ln*) : ;; *) echo "tree not chowned to the panel user"; return 1 ;; esac
  case "$body" in *bootstrap/cache*-delete*) : ;; *) echo "bootstrap/cache/*.php not deleted"; return 1 ;; esac; }
priv_phase_app_prepares_first() { local body
  body=$(bash -c "source '$INSTALLER'; declare -f phase_app")
  # _prepare_panel_tree must precede the first composer/artisan call
  local pre first
  pre=$(printf '%s\n' "$body" | grep -n '_prepare_panel_tree' | head -1 | cut -d: -f1)
  first=$(printf '%s\n' "$body" | grep -nE '_as_panel_user|_artisan' | head -1 | cut -d: -f1)
  [ -n "$pre" ] && [ -n "$first" ] && [ "$pre" -lt "$first" ]; }
t "artisan runs as laranode_ln (runuser), never as root"                      priv_artisan_via_runuser
t "no composer/artisan line in the installer runs as root"                    priv_no_root_php_lines
t "the permission settle leaves bootstrap/cache out of the web-writable set"  priv_settle_not_web_writable
t "the tree is chowned to the panel user and bootstrap caches wiped"          priv_prepare_wipes_caches
t "phase_app prepares the tree before any composer/artisan call"              priv_phase_app_prepares_first
# a root-created /home/laranode_ln (the scenarios mkdir the panel dir before the installer, and
# `useradd -m` leaves an existing home alone) is 750 root: laranode_ln could not even read
# composer.json. The home itself must be handed to the panel user too, not only the panel tree.
priv_prepare_chowns_home() { local out d
  d=$(mktemp -d); mkdir -p "$d/bootstrap/cache"
  out=$(bash -c "
    source '$INSTALLER'
    PANEL_PATH='$d'
    chown() { printf 'chown %s\n' \"\$*\"; }
    _prepare_panel_tree")
  rm -rf "$d"
  case "$out" in *'chown laranode_ln:laranode_ln /home/laranode_ln'$'\n'*|*'chown laranode_ln:laranode_ln /home/laranode_ln') : ;; *) echo "home not chowned; chown calls: $out"; return 1 ;; esac; }
t "the panel home dir itself is handed to the panel user before composer runs"  priv_prepare_chowns_home

# ---- r3 F2: root-run installer steps never read or execute the panel tree -----------------------
# laranode_ln (the queue worker, compiled views, .env group) can write the checkout. A root step
# that cp/sed/runs something FROM it hands laranode_ln root at the next install: www-data ->
# laranode_ln -> root. Root renders only from the root-owned copy (LN_LIB_DEST, published by the
# sync as a judged copy); node build scripts run as the panel user.
# strip comment-only lines so prose that names a path cannot trip the check
installer_code() { grep -vE '^[[:space:]]*#' "$INSTALLER"; }
priv_no_root_read_of_panel_templates() { local bad
  bad=$(installer_code | grep -nE 'PANEL_PATH}?/laranode-scripts/(templates|etc|lib)' || true)
  [ -z "$bad" ] || { echo "a root step reads the writable panel tree:"; echo "$bad"; return 1; }; }
priv_no_root_exec_of_panel_scripts() { local bad
  # the only root use of a script from the panel tree is the first-install sync (fallback), inside
  # _install_privileged_scripts and its existence check
  bad=$(installer_code | grep -nE 'PANEL_PATH}?/laranode-scripts/bin/' | grep -vE 'laranode-sync-scripts.sh' || true)
  [ -z "$bad" ] || { echo "a root step runs a script from the writable panel tree:"; echo "$bad"; return 1; }; }
priv_npm_runs_as_panel_user() { local bad
  bad=$(installer_code | grep -nE '(^|[;&|[:space:]])npm[[:space:]]+(install|run|ci|exec)' | grep -vE '_as_panel_user' || true)
  [ -z "$bad" ] || { echo "npm runs as root over the panel tree:"; echo "$bad"; return 1; }
  bad=$(installer_code | grep -nE 'find .*node_modules' | grep -vE '_as_panel_user' || true)
  [ -z "$bad" ] || { echo "a root find/chmod walks node_modules:"; echo "$bad"; return 1; }; }
priv_cron_renders_from_root_copy() { local d r out
  d=$(mktemp -d); r=$(mktemp -d); mkdir -p "$d/p/laranode-scripts/templates" "$r/lib/templates" "$r/cron"
  printf '%s\n' '* * * * * root /tmp/EVIL-from-the-writable-tree' > "$d/p/laranode-scripts/templates/laranode-schedule.cron"
  printf '%s\n' '* * * * * __PANEL_USER__ __PHP__ __PANEL_PATH__/artisan schedule:run' > "$r/lib/templates/laranode-schedule.cron"
  bash -c "
    source '$INSTALLER'
    PANEL_PATH='$d/p'; LN_LIB_DEST='$r/lib'; LARANODE_CRON_DIR='$r/cron'
    log() { :; }
    _install_scheduler_cron" >/dev/null 2>&1
  out=$(cat "$r/cron/laranode-schedule" 2>/dev/null)
  rm -rf "$d" "$r"
  case "$out" in *EVIL*) echo "cron rendered from the writable panel tree: $out"; return 1 ;; esac
  case "$out" in *'laranode_ln /usr/bin/php8.4 '*'artisan schedule:run'*) : ;; *) echo "cron not rendered from the root copy: $out"; return 1 ;; esac; }
priv_units_and_vhost_from_root_copy() { local body
  body=$(bash -c "source '$INSTALLER'; declare -f phase_services phase_webserver")
  case "$body" in *'LN_LIB_DEST'*'templates/laranode-queue-worker.service'*) : ;; *) echo "queue unit not copied from the root-owned templates"; return 1 ;; esac
  case "$body" in *'LN_LIB_DEST'*'templates/laranode-reverb.service'*) : ;; *) echo "reverb unit not copied from the root-owned templates"; return 1 ;; esac
  case "$body" in *'LN_LIB_DEST'*'templates/apache-panel.template'*) : ;; *) echo "panel vhost not rendered from the root-owned templates"; return 1 ;; esac; }
priv_root_copy_exists_before_root_templates() { local body
  # phase_webserver (panel vhost) runs before phase_app: the root-owned copy must be published
  # in phase_fetch_panel, right after the tree is handed to the panel user
  body=$(bash -c "source '$INSTALLER'; declare -f phase_fetch_panel")
  case "$body" in *'_prepare_panel_tree'*'_install_privileged_scripts'*) : ;; *) echo "phase_fetch_panel does not publish the root-owned copy"; return 1 ;; esac; }
priv_sync_runs_from_root_copy_when_present() { local r out
  r=$(mktemp -d); mkdir -p "$r/lib/bin"; : > "$r/lib/bin/laranode-sync-scripts.sh"
  out=$(bash -c "
    source '$INSTALLER'
    PANEL_PATH='/nonexistent-panel'; LN_LIB_DEST='$r/lib'
    mkdir() { :; }; chown() { :; }; chmod() { :; }
    bash() { printf 'bash %s\n' \"\$*\"; }
    _install_privileged_scripts")
  rm -rf "$r"
  case "$out" in "bash $r/lib/bin/laranode-sync-scripts.sh /nonexistent-panel") : ;; *) echo "sync not run from the root-owned copy: $out"; return 1 ;; esac; }
t "no root step reads templates/etc/lib out of the writable panel tree"          priv_no_root_read_of_panel_templates
t "no root step runs a panel-tree script other than the first-install sync"      priv_no_root_exec_of_panel_scripts
t "npm install/build (and the node_modules chmod) run as the panel user"         priv_npm_runs_as_panel_user
t "the scheduler cron line is rendered from the root-owned template copy"        priv_cron_renders_from_root_copy
t "systemd units and the panel vhost come from the root-owned template copy"     priv_units_and_vhost_from_root_copy
t "the root-owned copy is published before the web server phase needs it"        priv_root_copy_exists_before_root_templates
t "a re-run syncs with the ROOT-OWNED sync script, not the one in the checkout"  priv_sync_runs_from_root_copy_when_present

# every mode change over the panel tree runs as the panel user: a root `find -exec chmod <path>`
# follows a symlink swapped in after find looked
priv_settle_chmod_as_panel_user() { local body bad
  body=$(bash -c "source '$INSTALLER'; declare -f _settle_permissions _prepare_panel_tree" | grep -vE '^[[:space:]]*#')
  bad=$(printf '%s\n' "$body" | grep -E '(^|[^[:alnum:]_])(find|chmod)[[:space:]]' | grep -vE '_as_panel_user|LN_LIB_DEST|^[[:space:]]*(chmod 755|chown)' | grep -vE '^[[:space:]]*find .*-delete' || true)
  [ -z "$bad" ] || { echo "root find/chmod over the panel tree:"; echo "$bad"; return 1; }; }
t "the permission settle changes modes as the panel user, never as root"         priv_settle_chmod_as_panel_user

# ---- r3 F3: fs.protected_hardlinks must be 1 --------------------------------------------------
# `laranode-create-directory.sh` runs chown -R -h as root over a tenant tree; only the kernel
# stops a tenant hard-linking a root-owned file into it. Not only a CI-container assert: the
# installer itself refuses a host where it is off.
phl_fixture() { local d; d=$(mktemp -d); mkdir -p "$d/sys/fs"; [ -z "${1:-}" ] || printf '%s\n' "$1" > "$d/sys/fs/protected_hardlinks"; echo "$d"; }
phl_check() { local d rc; d=$(phl_fixture "$1")
  bash -c "source '$INSTALLER'; LARANODE_PROC_DIR='$d'; _require_protected_hardlinks"; rc=$?; rm -rf "$d"; return $rc; }
t  "protected_hardlinks=1: the installer goes on"                                phl_check 1
tf "protected_hardlinks=0: the installer refuses"                                phl_check 0
tf "protected_hardlinks=2 (not exactly 1): refused"                              phl_check 2
tf "protected_hardlinks unreadable (file missing): refused"                      phl_check ""
priv_main_requires_hardlinks() { local body a b
  body=$(bash -c "source '$INSTALLER'; declare -f main")
  a=$(printf '%s\n' "$body" | grep -n '_require_protected_hardlinks' | head -1 | cut -d: -f1)
  b=$(printf '%s\n' "$body" | grep -nE '^[[:space:]]+(phase_packages|preflight);?$' | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }
t "main checks protected_hardlinks before preflight/any package work"            priv_main_requires_hardlinks
# every script that root starts through sudo resolves its own directory (dirname) BEFORE validate.sh
# sets a safe PATH: it must set PATH first (the container harness proves the same by running them)
priv_scripts_reset_path_first() { local f bad="" l1 l2
  for f in "$SCRIPT_DIR"/../../../laranode-scripts/bin/laranode-*.sh; do
    case "${f##*/}" in laranode-installer.sh|laranode-sync-scripts.sh) continue ;; esac
    l1=$(grep -nE '^[[:space:]]*(export )?PATH=' "$f" | head -1 | cut -d: -f1)
    l2=$(grep -nE '^[^#]*dirname' "$f" | head -1 | cut -d: -f1)
    # no dirname at all (managed-register): PATH must still be set, before the first `id`/command
    [ -n "$l2" ] || l2=$(grep -nE '^\[ "\$\(id -u\)"' "$f" | head -1 | cut -d: -f1)
    { [ -n "$l1" ] && [ -n "$l2" ] && [ "$l1" -le "$l2" ]; } || bad="$bad ${f##*/}"
  done
  [ -z "$bad" ] || { echo "PATH not reset before dirname in:$bad"; return 1; }; }
t "every sudo-able script resets PATH before its first dirname"                   priv_scripts_reset_path_first

# ---- r4: no root-run mutation/exec of ANY path derived from PANEL_PATH ---------------------------
# r3 only grepped the literal `PANEL_PATH}/laranode-scripts/...`; `$p/...`, `.env`, `.env.example`
# and `$sync` slipped past (a root `cp .env.example .env` followed a symlink laranode_ln planted).
# Now: any root-run cp/mv/sed/chown/chmod/chgrp/install/tee/ln/rm/touch/mkdir/bash/source/find or
# `>`/`>>` redirect on a PANEL_PATH-derived variable ($PANEL_PATH $p $h $env $sync $f $src) must run
# through _as_panel_user, or be on the short allowlist below, each entry with its reason.
# The bodies that run ONLY as the panel user (_env_set_inner, _seed_env_inner: reached only through
# `_as_panel_user bash -c "$(declare -f ...)"`) are not root code and are removed before scanning.
PANEL_USER_BODIES='_env_set_inner|_seed_env_inner'
installer_root_code() { installer_code | awk -v re="^(${PANEL_USER_BODIES})[(][)] [{]" '$0 ~ re {skip=1} !skip {print} skip && /^}/ {skip=0}'; }
# line fragments that may stay root-run on a panel-derived path, and why:
ROOT_PANEL_ALLOW=(
  'chown -R -h laranode_ln:laranode_ln "$p"'                 # -R never follows a link met while walking, -h hits the link itself
  'chown -R laranode_ln:laranode_ln "$h"'                    # same; $h is /home/laranode_ln, which laranode_ln cannot replace
  "find \"\$p/bootstrap/cache\" -maxdepth 1 -type f -name '*.php' -delete"   # -delete unlinks by name, follows nothing
  'cp -P --no-preserve=all "$src" "${LN_SYNC_STASH}/sync.sh"'  # first-install stash into a root-only dir; -P copies a link as a link, then checked regular
  'bash "$sync" "${PANEL_PATH}"'                             # $sync = root-owned copy or the private stash (priv_sync_* tests); PANEL_PATH is only an argument
  '-e "s#__PANEL_PATH__#${PANEL_PATH}#g"'                    # the cron sed: PANEL_PATH is the replacement TEXT; it reads the root-owned template
  'echo "    cd ${PANEL_PATH} '                              # printed hint in the summary, not a command
)
# PR B (r4 review): a purely line-by-line grep missed a `cp \` continued on the next line, an alias
# variable (q="$p/.env"; cp x "$q"), a `cd "$p"` then a relative path, a root command after
# `_as_panel_user x;` on the same line, and tar/rsync/git. So the scan now (1) joins continuation
# lines, (2) splits every line into its ; && || commands (each judged alone), (3) treats any
# variable assigned from a panel-derived one as panel-derived (fixpoint), (4) also flags
# cd/tar/rsync/git/cat/grep and `<` reads. arch_catches (below) injects each bypass and must see red.
priv_no_root_touch_of_panel_paths() { local tv cm rd bad a fixed=() names prev code
  names='PANEL_PATH|p|h|env|sync|f|src'
  # (1) + (2): one judged command per output line, prefixed with the source line number
  code=$(installer_root_code | awk '
    { if (c != "") { $0 = c " " $0; c = "" } }
    /\\$/ { c = substr($0, 1, length($0) - 1); next }
    { line = $0; gsub(/\\;/, "\001", line); k = split(line, parts, /;|&&|\|\|/)
      for (i = 1; i <= k; i++) print NR ": " parts[i] }')
  # (3) aliases: X="$p/..." / X=${PANEL_PATH} / local X="$env" ... until nothing new
  while :; do
    prev=$names
    for a in $(printf '%s\n' "$code" | grep -oE "(^|[^[:alnum:]_])[A-Za-z_][A-Za-z0-9_]*=\"?\\$\\{?(${names})\\}?([^[:alnum:]_]|\$)" \
                 | sed -E 's/^[^A-Za-z_]//; s/=.*//' | sort -u); do
      case "|${names}|" in *"|${a}|"*) : ;; *) names="${names}|${a}" ;; esac
    done
    [ "$names" = "$prev" ] && break
  done
  tv="\\\$\\{?(${names})\\}?([^[:alnum:]_]|\$)"
  cm='(^|[;&|(`[:space:]])(cp|mv|sed|chown|chgrp|chmod|install|tee|ln|rm|touch|mkdir|truncate|dd|bash|source|find|cd|tar|rsync|git|cat|grep)[[:space:]]'
  rd="[<>]>?[[:space:]]*\"?\\\$\\{?(${names})\\}?([^[:alnum:]_]|\$)"
  for a in "${ROOT_PANEL_ALLOW[@]}"; do fixed+=(-e "$a"); done
  bad=$({ printf '%s\n' "$code" | grep -E "$cm" | grep -E "$tv"; printf '%s\n' "$code" | grep -E "$rd"; } \
          | grep -vE '_as_panel_user|runuser' | grep -vF "${fixed[@]}" || true)
  [ -z "$bad" ] || { echo "root-run command on a panel-derived path (symlink-followable):"; echo "$bad"; return 1; }; }
t 'no root-run cp/sed/chown/chmod/>/>>/bash on ANY PANEL_PATH-derived path ($p $env $sync ...)' priv_no_root_touch_of_panel_paths
# the panel-user bodies must only ever be reached through _as_panel_user
priv_panel_bodies_only_via_panel_user() { local bad
  bad=$(installer_root_code | grep -nE '(_env_set_inner|_seed_env_inner)' | grep -vE '_as_panel_user' || true)
  [ -z "$bad" ] || { echo "a panel-user-only body is called outside _as_panel_user:"; echo "$bad"; return 1; }; }
t "_env_set_inner/_seed_env_inner run only through _as_panel_user"               priv_panel_bodies_only_via_panel_user

# behaviour: with the panel-user hop stubbed to LOG, root itself runs no cp/chmod/chown/chgrp/sed
priv_seed_env_runs_as_panel_user() { local d out
  d=$(mktemp -d); printf 'A=1\n' > "$d/.env.example"
  out=$(bash -c "
    source '$INSTALLER'
    PANEL_PATH='$d'
    for c in cp chmod chown chgrp sed; do eval \"\$c() { echo ROOT-\$c \\\"\\\$*\\\"; }\"; done
    _as_panel_user() { echo \"PANEL \$1 \$2\"; }
    _seed_env")
  rm -rf "$d"
  case "$out" in *ROOT-*) echo "root ran: $out"; return 1 ;; esac
  case "$out" in 'PANEL bash -c') : ;; *) echo "_seed_env did not hop to the panel user: $out"; return 1 ;; esac; }
t "_seed_env copies AS the panel user; root runs no cp/chmod/chown/chgrp"         priv_seed_env_runs_as_panel_user
priv_seed_env_result() { local d
  d=$(mktemp -d); printf 'APP_KEY=\n' > "$d/.env.example"
  bash -c "
    source '$INSTALLER'
    PANEL_PATH='$d'
    _as_panel_user() { \"\$@\"; }
    _seed_env" || { rm -rf "$d"; return 1; }
  [ "$(stat -c %a "$d/.env")" = 640 ] && grep -qx 'APP_KEY=' "$d/.env"; local rc=$?; rm -rf "$d"; return $rc; }
t "_seed_env still produces a 0640 .env from .env.example"                       priv_seed_env_result
priv_seed_env_leaves_existing_link() { local d
  d=$(mktemp -d); printf 'KEEP\n' > "$d/t"; ln -s "$d/t" "$d/.env"; : > "$d/.env.example"
  bash -c "
    source '$INSTALLER'
    PANEL_PATH='$d'
    _as_panel_user() { echo HOP; }
    _seed_env" | grep -q HOP && { rm -rf "$d"; return 1; }
  rm -rf "$d"; return 0; }
t "_seed_env never reseeds over an existing .env, a symlink included"            priv_seed_env_leaves_existing_link
priv_env_set_runs_as_panel_user() { local d out
  d=$(mktemp -d); : > "$d/.env"
  out=$(bash -c "
    source '$INSTALLER'
    for c in sed grep; do eval \"\$c() { echo ROOT-\$c; }\"; done
    _as_panel_user() { echo \"PANEL \$* STDIN=\$(cat)\"; }
    env_set DB_PASSWORD s3cr3t-pw '$d/.env'")
  rm -rf "$d"
  case "$out" in *ROOT-*) echo "root ran sed/grep on .env: $out"; return 1 ;; esac
  case "$out" in 'PANEL bash -c '*' _ DB_PASSWORD '*'.env STDIN=s3cr3t-pw') : ;; *) echo "env_set did not hop with the value on stdin: $out"; return 1 ;; esac
  case "${out%%STDIN=*}" in *s3cr3t-pw*) echo "the secret is in the argv: $out"; return 1 ;; esac; }
t "env_set edits AS the panel user, value on stdin (never in argv)"              priv_env_set_runs_as_panel_user
# first-install fallback: the sync that root runs is a private copy made before the chown, not the
# checkout file laranode_ln could swap in between
priv_sync_fallback_runs_private_copy() { local d r out
  d=$(mktemp -d); r=$(mktemp -d); mkdir -p "$d/laranode-scripts/bin"; printf 'echo ORIGINAL\n' > "$d/laranode-scripts/bin/laranode-sync-scripts.sh"
  out=$(bash -c "
    source '$INSTALLER'
    PANEL_PATH='$d'; LN_LIB_DEST='$r/lib'; LARANODE_STASH_PARENT='$r'
    chown() { :; }; chmod() { :; }
    _stash_sync_script
    printf 'echo SWAPPED\n' > '$d/laranode-scripts/bin/laranode-sync-scripts.sh'
    _install_privileged_scripts" 2>&1)
  rm -rf "$d" "$r"
  case "$out" in *SWAPPED*) echo "root ran the swapped checkout file: $out"; return 1 ;; esac
  case "$out" in *ORIGINAL*) : ;; *) echo "stash copy not run: $out"; return 1 ;; esac; }
t "first install: root runs a private copy of the sync made before the chown"     priv_sync_fallback_runs_private_copy
priv_sync_fallback_refuses_symlink() { local d out
  d=$(mktemp -d); mkdir -p "$d/laranode-scripts/bin" "$d/run"; printf 'echo EVIL\n' > "$d/evil"
  ln -s "$d/evil" "$d/laranode-scripts/bin/laranode-sync-scripts.sh"
  out=$(bash -c "
    source '$INSTALLER'
    PANEL_PATH='$d'; LN_LIB_DEST='$d/nolib'; LARANODE_STASH_PARENT='$d/run'
    die() { echo \"DIED: \$*\"; exit 1; }
    _stash_sync_script; echo SURVIVED" 2>&1)
  rm -rf "$d"
  # the regular-file check must be what refuses (cp -P copies the link as a link)
  case "$out" in *"DIED: laranode-sync-scripts.sh in the panel checkout is not a regular file"*) : ;;
    *) echo "a symlinked sync script was not refused by the regular-file check: $out"; return 1 ;; esac; }
t "first install: a symlinked sync script in the checkout is refused"             priv_sync_fallback_refuses_symlink
priv_fetch_stashes_before_chown() { local body a b
  body=$(bash -c "source '$INSTALLER'; declare -f phase_fetch_panel")
  a=$(printf '%s\n' "$body" | grep -n '_stash_sync_script' | head -1 | cut -d: -f1)
  b=$(printf '%s\n' "$body" | grep -n '_prepare_panel_tree' | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }
t "phase_fetch_panel stashes the sync script before the tree is chowned"          priv_fetch_stashes_before_chown
priv_settle_mkdir_as_panel_user() { local body
  body=$(bash -c "source '$INSTALLER'; declare -f _settle_permissions" | grep -E '(^|[[:space:]])mkdir ' | grep -vE '_as_panel_user' || true)
  [ -z "$body" ] || { echo "root mkdir in _settle_permissions: $body"; return 1; }; }
t "_settle_permissions creates logs/ as the panel user"                          priv_settle_mkdir_as_panel_user

# ==== PR B: Proxmox dedicated web user (G2/G7) ======================================================
# pveproxy/spiceproxy run as www-data on Proxmox: a panel that gives www-data sudo (or group
# laranode_ln) hands the Proxmox UI root, and a panel PHP running as www-data reads /etc/pve keys.
# So on Proxmox the panel's Apache + PHP-FPM run as a dedicated user and www-data gets nothing.
echo "=== PR B: Proxmox web user ==="
wu_run() {  # wu_run <proxmox 0|1> <apache_owned> <fpm_owned> [ufw opt-in]
  base; IS_PROXMOX=$1; APACHE_OWNED=$2; PHPFPM_OWNED=$3
  [ -z "${4:-}" ] || export LARANODE_PVE_UFW="$4"
  _resolve_web_user; }
wu_pve_dedicated()   { wu_run 1 1 1; expect WEB_USER "$WEB_USER" laranode_web && expect UFW_ENABLED "$UFW_ENABLED" 0; }
wu_plain_unchanged() { wu_run 0 1 1; expect WEB_USER "$WEB_USER" www-data && expect UFW_ENABLED "$UFW_ENABLED" 1; }
wu_plain_preapache() { wu_run 0 0 0; expect WEB_USER "$WEB_USER" www-data; }
wu_pve_ufw_optin()   { wu_run 1 1 1 1; expect WEB_USER "$WEB_USER" laranode_web && expect UFW_ENABLED "$UFW_ENABLED" 1; }
t  "Proxmox: panel web user is the dedicated laranode_web, ufw gated off"          wu_pve_dedicated
t  "plain host: web user stays www-data, ufw sudoers kept (behaviour unchanged)"   wu_plain_unchanged
t  "plain host with a pre-existing Apache/php-fpm: still www-data"                 wu_plain_preapache
t  "Proxmox + LARANODE_PVE_UFW=1: ufw sudoers opted back in"                       wu_pve_ufw_optin
tf "Proxmox + pre-existing Apache: refused (its User cannot be changed)"           wu_run 1 0 1
tf "Proxmox + pre-existing php8.4-fpm: refused (no dedicated pool on it)"          wu_run 1 1 0
wu_preflight_order() { local body a b
  body=$(bash -c "source '$INSTALLER'; declare -f preflight")
  a=$(printf '%s\n' "$body" | grep -n 'capture_preexisting' | head -1 | cut -d: -f1)
  b=$(printf '%s\n' "$body" | grep -n '_resolve_web_user' | head -1 | cut -d: -f1)
  c=$(printf '%s\n' "$body" | grep -n 'confirm "Proceed' | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]; }
t  "preflight resolves the web user after ownership is known, before the confirm"  wu_preflight_order

# _ensure_web_user: account calls recorded through stubs (never real useradd in a unit test)
ewu_run() {  # ewu_run <web user> <id -u answer|missing> <groups of www-data> [useradd rc]
  base; WEB_USER=$1; CALLS=$(mktemp)
  local idu="$2" grp="$3" urc="${4:-0}"
  # a successful useradd makes the account exist for the id lookups after it
  eval "useradd() { echo \"useradd \$*\" >> '$CALLS'; [ $urc = 0 ] && : > '$CALLS.created'; return $urc; }"
  usermod() { echo "usermod $*" >> "$CALLS"; }
  gpasswd() { echo "gpasswd $*" >> "$CALLS"; }
  eval "id() { case \"\$*\" in '-u laranode_web') if [ '$idu' = missing ]; then [ -e '$CALLS.created' ] || return 1; echo 998; else echo '$idu'; fi ;; '-nG www-data') echo '$grp' ;; '-nG laranode_web') echo 'laranode_web laranode_ln' ;; *) command id \"\$@\" ;; esac; }"
  _ensure_web_user; }
ewu_pve_ok() { ewu_run laranode_web 998 "www-data laranode_ln"
  grep -q '^usermod -aG laranode_ln laranode_web$' "$CALLS" || { echo "laranode_web not grouped:"; cat "$CALLS"; return 1; }
  grep -q 'usermod -aG laranode_ln www-data' "$CALLS" && { echo "www-data grouped with laranode_ln"; return 1; }
  grep -q '^gpasswd -d www-data laranode_ln$' "$CALLS" || { echo "www-data not removed from laranode_ln:"; cat "$CALLS"; return 1; }; }
ewu_pve_creates() { ewu_run laranode_web missing "www-data" 0; grep -q '^useradd .*laranode_web' "$CALLS"; }
ewu_plain() { ewu_run www-data 33 "www-data"; grep -q '^usermod -aG laranode_ln www-data$' "$CALLS"; }
t  "Proxmox: laranode_web grouped with laranode_ln, www-data removed, never added" ewu_pve_ok
t  "Proxmox: a missing laranode_web is created"                                    ewu_pve_creates
t  "plain host: www-data grouped with laranode_ln as before"                       ewu_plain
tf "Proxmox: refused when laranode_web cannot be created"                          ewu_run laranode_web missing "www-data" 1
tf "Proxmox: refused when laranode_web is uid 0"                                   ewu_run laranode_web 0 "www-data"

# r1 review (important): upgrade of an earlier (www-data) Proxmox install. laranode-user-manager.sh
# put www-data in every hosted user's group (homes 0770, pool sockets 0660 user:user); the switch
# to laranode_web must move each LARANODE tenant group over: + laranode_web, - www-data. A tenant
# group = <x>_ln (not laranode_ln) whose same-name account is a regular user with home /home/<x>_ln.
mtg_run() {  # mtg_run <web user>: stubbed getent group/passwd, usermod/gpasswd recorded
  base; WEB_USER=$1; CALLS=$(mktemp)
  getent() {
    case "$1 ${2:-}" in
      "group ")  printf '%s\n' 'root:x:0:' 'www-data:x:33:' 'laranode_ln:x:999:www-data' \
                   'alice_ln:x:1001:www-data' 'bob_ln:x:1002:' 'carol_ln:x:1003:www-data,laranode_web' \
                   'sys_ln:x:998:www-data' 'odd_ln:x:1004:www-data' 'ghost_ln:x:1005:www-data' \
                   'notatenant:x:1006:www-data' 'Bad_ln:x:1007:www-data' ;;
      "passwd alice_ln") echo 'alice_ln:x:1001:1001::/home/alice_ln:/usr/sbin/nologin' ;;
      "passwd bob_ln")   echo 'bob_ln:x:1002:1002::/home/bob_ln:/bin/bash' ;;
      "passwd carol_ln") echo 'carol_ln:x:1003:1003::/home/carol_ln:/usr/sbin/nologin' ;;
      "passwd sys_ln")   echo 'sys_ln:x:998:998::/home/sys_ln:/usr/sbin/nologin' ;;
      "passwd odd_ln")   echo 'odd_ln:x:1004:1004::/srv/odd:/usr/sbin/nologin' ;;
      "passwd notatenant") echo 'notatenant:x:1006:1006::/home/notatenant:/bin/sh' ;;
      "passwd Bad_ln")   echo 'Bad_ln:x:1007:1007::/home/Bad_ln:/bin/sh' ;;
      *) return 2 ;;
    esac; }
  usermod() { echo "usermod $*" >> "$CALLS"; }
  gpasswd() { echo "gpasswd $*" >> "$CALLS"; }
  _migrate_tenant_groups; }
mtg_pve() { mtg_run laranode_web
  local want got
  want=$(printf '%s\n' 'usermod -aG alice_ln laranode_web' 'gpasswd -d www-data alice_ln' \
    'usermod -aG bob_ln laranode_web' 'usermod -aG carol_ln laranode_web' 'gpasswd -d www-data carol_ln')
  got=$(cat "$CALLS")
  [ "$got" = "$want" ] || { echo "want:"; echo "$want"; echo "got:"; echo "$got"; return 1; }; }
t  "upgrade to laranode_web: every tenant group gains laranode_web and loses www-data" mtg_pve
mtg_plain() { mtg_run www-data; [ ! -s "$CALLS" ] || { echo "plain host touched groups:"; cat "$CALLS"; return 1; }; }
t  "plain host (www-data): no tenant group is touched"                             mtg_plain
mtg_called() { bash -c "source '$INSTALLER'; declare -f _ensure_web_user" | grep -q '_migrate_tenant_groups'; }
t  "_ensure_web_user migrates the tenant groups on the dedicated web user"         mtg_called
mtg_fail() { mtg_run laranode_web; gpasswd() { return 1; }; _migrate_tenant_groups; }
tfm "a tenant group that cannot be migrated stops the install" "could not remove www-data from tenant group" mtg_fail
tf "Proxmox: refused when laranode_web is a regular (uid >= 1000) account"         ewu_run laranode_web 1001 "www-data"
ewu_in_wwwdata() { base; WEB_USER=laranode_web
  useradd() { :; }; usermod() { :; }; gpasswd() { :; }
  id() { case "$*" in '-u laranode_web') echo 998 ;; '-nG laranode_web') echo 'laranode_web www-data' ;; *) echo www-data ;; esac; }
  _ensure_web_user; }
tf "Proxmox: refused when laranode_web is in group www-data (/etc/pve keys)"       ewu_in_wwwdata

# host.conf: the root-owned record the sync script and validate.sh read
hc_run() { base; d=$(mktemp -d); export LARANODE_HOST_CONF="$d/host.conf"; WEB_USER=$1; UFW_ENABLED=$2; _write_host_conf; }
hc_pve() { hc_run laranode_web 0; grep -qx 'web_user=laranode_web' "$LARANODE_HOST_CONF" && grep -qx 'ufw=0' "$LARANODE_HOST_CONF" \
  && [ "$(stat -c %a "$LARANODE_HOST_CONF")" = 644 ]; }
hc_plain() { hc_run www-data 1; grep -qx 'web_user=www-data' "$LARANODE_HOST_CONF" && grep -qx 'ufw=1' "$LARANODE_HOST_CONF"; }
t  "host.conf records web_user=laranode_web ufw=0 on Proxmox (0644)"              hc_pve
t  "host.conf records web_user=www-data ufw=1 on a plain host"                    hc_plain
hc_fetch_order() { local body a b c
  body=$(bash -c "source '$INSTALLER'; declare -f phase_fetch_panel")
  a=$(printf '%s\n' "$body" | grep -n '_ensure_web_user' | head -1 | cut -d: -f1)
  b=$(printf '%s\n' "$body" | grep -n '_write_host_conf' | head -1 | cut -d: -f1)
  c=$(printf '%s\n' "$body" | grep -n '_install_privileged_scripts' | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$b" -lt "$c" ] && [ "$a" -lt "$c" ]; }
t  "phase_fetch_panel sets the web user + host.conf before the sync renders sudoers" hc_fetch_order
hc_no_literal_usermod() { ! bash -c "source '$INSTALLER'; declare -f phase_fetch_panel" | grep -q 'usermod -aG laranode_ln www-data'; }
t  "phase_fetch_panel no longer hard-codes 'usermod -aG laranode_ln www-data'"    hc_no_literal_usermod

# Apache + PHP-FPM run as the web user
vh_render() { base; d=$(mktemp -d); WEB_USER=$1; APACHE_OWNED=$2
  printf '<VirtualHost *:__PORT__>\n    DocumentRoot __DOCROOT__\n</VirtualHost>\n' > "$d/t"
  _vhost_render "$d/t" "$d/out" 80 /x/public; cat "$d/out"; }
vh_pve_socket()   { vh_render laranode_web 1 | grep -q 'SetHandler "proxy:unix:/run/php/laranode-panel.sock|fcgi://localhost"'; }
vh_plain_nohdl()  { ! vh_render www-data 1 | grep -q SetHandler; }
vh_preapache()    { vh_render www-data 0 | grep -q 'proxy:unix:/run/php/php8.4-fpm.sock'; }
t  "Proxmox: panel vhost hands PHP to the dedicated laranode-panel.sock"         vh_pve_socket
t  "plain host, our Apache: no handler in the vhost (global conf, unchanged)"     vh_plain_nohdl
t  "pre-existing Apache: vhost handler still the stock php8.4-fpm socket"         vh_preapache
pool_pve() { base; d=$(mktemp -d); export LARANODE_PHP_POOL_DIR="$d"; WEB_USER=laranode_web; _write_panel_pool; f="$d/laranode-panel.conf"
  grep -qx 'user = laranode_web' "$f" && grep -qx 'group = laranode_web' "$f" && grep -qx 'listen = /run/php/laranode-panel.sock' "$f" \
  && grep -qx 'listen.owner = laranode_web' "$f" && grep -qx 'listen.group = laranode_web' "$f" && grep -qx 'listen.mode = 0660' "$f" \
  && ! grep -q 'www-data' "$f"; }
pool_plain() { base; d=$(mktemp -d); export LARANODE_PHP_POOL_DIR="$d"; WEB_USER=www-data; _write_panel_pool; [ ! -e "$d/laranode-panel.conf" ]; }
t  "Proxmox: dedicated php-fpm pool runs as laranode_web, socket 0660 to it only" pool_pve
t  "plain host: no extra pool (stock www pool, unchanged)"                       pool_plain
ah_run() { base; d=$(mktemp -d); export LARANODE_APACHE_DIR="$d"; mkdir -p "$d/conf-available"; WEB_USER=$1; APACHE_OWNED=1; CALLS=$(mktemp)
  a2enconf() { echo "a2enconf $*" >> "$CALLS"; }; _php_apache_handler; }
ah_pve()   { ah_run laranode_web; ! grep -q 'a2enconf php8.4-fpm' "$CALLS"; }
ah_plain() { ah_run www-data; touch "$LARANODE_APACHE_DIR/conf-available/php8.4-fpm.conf"; _php_apache_handler; grep -q 'a2enconf php8.4-fpm' "$CALLS"; }
t  "Proxmox: no global a2enconf php8.4-fpm (www-data pool never routed to)"        ah_pve
t  "plain host: global a2enconf php8.4-fpm as before"                             ah_plain
au_run() { base; d=$(mktemp -d); export LARANODE_APACHE_DIR="$d"; mkdir -p "$d/conf-available"; WEB_USER=$1; CALLS=$(mktemp)
  a2enconf() { echo "a2enconf $*" >> "$CALLS"; }; _apache_web_user; }
au_pve()   { au_run laranode_web; f="$LARANODE_APACHE_DIR/conf-available/laranode-web-user.conf"
  grep -qx 'User laranode_web' "$f" && grep -qx 'Group laranode_web' "$f" && grep -qx 'a2enconf laranode-web-user' "$CALLS"; }
au_plain() { au_run www-data; [ ! -e "$LARANODE_APACHE_DIR/conf-available/laranode-web-user.conf" ] && [ ! -s "$CALLS" ]; }
t  "Proxmox: Apache workers switched to laranode_web (conf snippet, no envvars edit)" au_pve
t  "plain host: Apache user untouched"                                            au_plain
au_order() { local body a b
  body=$(bash -c "source '$INSTALLER'; declare -f phase_webserver")
  a=$(printf '%s\n' "$body" | grep -n '_apache_web_user' | head -1 | cut -d: -f1)
  b=$(printf '%s\n' "$body" | grep -n 'apachectl configtest' | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }
t  "phase_webserver sets the Apache user before the configtest"                    au_order
pp_order() { local body
  body=$(bash -c "source '$INSTALLER'; declare -f phase_php_node")
  printf '%s\n' "$body" | grep -q '_write_panel_pool' && printf '%s\n' "$body" | grep -q '_php_apache_handler' \
    && [ "$(printf '%s\n' "$body" | grep -n '_write_panel_pool' | cut -d: -f1)" -lt "$(printf '%s\n' "$body" | grep -n '_php_fpm_up' | cut -d: -f1)" ]; }
t  "phase_php_node writes the panel pool before php-fpm is brought up"            pp_order

# sudoers: ufw drop-in only with UFW_ENABLED=1; the check names the web user
su_run() { base; d=$(mktemp -d); export LARANODE_SUDOERS_DIR="$d"; UFW_ENABLED=$1
  for x in laranode-panel laranode-cron laranode-runtimes; do : > "$d/$x"; done
  [ "$1" = 1 ] && : > "$d/laranode-ufw"; [ "$1" = 0 ] && : > "$d/laranode-ufw"   # a previous run's drop-in
  [ "${2:-}" = noufw ] && rm -f "$d/laranode-ufw"
  visudo() { return 0; }; _install_sudoers; }
su_pve()   { su_run 0; [ ! -e "$LARANODE_SUDOERS_DIR/laranode-ufw" ]; }
su_plain() { su_run 1; [ -e "$LARANODE_SUDOERS_DIR/laranode-ufw" ]; }
t  "ufw gated off: a previous laranode-ufw drop-in is removed"                     su_pve
t  "ufw on (plain host): laranode-ufw drop-in kept"                                su_plain
tf "ufw on but laranode-ufw missing: refused as before"                            su_run 1 noufw
# PR #11 r2: an upgrade from a www-data install must not leave pveproxy's user a root grant
su_www() { base; d=$(mktemp -d); export LARANODE_SUDOERS_DIR="$d"; UFW_ENABLED=0; WEB_USER=$1
  for x in laranode-panel laranode-cron laranode-runtimes; do echo "$1 ALL=(root) NOPASSWD: /usr/local/lib/laranode/bin/x.sh" > "$d/$x"; done
  echo 'www-data ALL=(root) NOPASSWD: /usr/local/lib/laranode/bin/laranode-sleep.sh' > "$d/laranode-sleep"
  visudo() { return 0; }; _install_sudoers; }
tfm "dedicated web user: a drop-in still granting www-data stops the install"  "still granted www-data" su_www laranode_web
su_www_gone() { local d; d=$(mktemp -d); ( base; export LARANODE_SUDOERS_DIR="$d"; UFW_ENABLED=0; WEB_USER=laranode_web
    for x in laranode-panel laranode-cron laranode-runtimes; do : > "$d/$x"; done
    echo 'www-data ALL=(root) NOPASSWD: /bin/true' > "$d/laranode-sleep"
    visudo() { return 0; }; _install_sudoers ) >/dev/null 2>&1
  [ ! -e "$d/laranode-sleep" ] && [ -e "$d/laranode-panel" ]; }
t  "dedicated web user: the www-data drop-in is removed before the install stops" su_www_gone
t  "plain host (www-data): www-data grants are the expected ones, kept"         su_www www-data
# an upgrade runs the previously installed sync; when that run replaced it, the new root-owned
# copy runs once more (it renders the grants for host.conf's web user)
priv_sync_rerun_when_updated() { local r out
  r=$(mktemp -d); mkdir -p "$r/lib/bin"; echo old > "$r/lib/bin/laranode-sync-scripts.sh"
  out=$(bash -c "
    source '$INSTALLER'
    PANEL_PATH='/nonexistent-panel'; LN_LIB_DEST='$r/lib'
    mkdir() { :; }; chown() { :; }; chmod() { :; }; log() { :; }
    bash() { printf 'bash %s\n' \"\$*\"; echo new > '$r/lib/bin/laranode-sync-scripts.sh'; }
    _install_privileged_scripts")
  rm -rf "$r"
  [ "$(printf '%s\n' "$out" | grep -c "^bash $r/lib/bin/laranode-sync-scripts.sh /nonexistent-panel$")" = 2 ] \
    || { echo "updated sync not run a second time: $out"; return 1; }; }
t  "upgrade: a sync run that replaced the installed sync runs the new copy once more" priv_sync_rerun_when_updated
fw_env() { base; CALLS=$(mktemp); env_set() { echo "$1=$2" >> "$CALLS"; }; UFW_ENABLED=$1; _panel_feature_env; cat "$CALLS"; }
fw_env_pve()   { fw_env 0 | grep -qx 'LARANODE_FIREWALL_ENABLED=false'; }
fw_env_plain() { fw_env 1 | grep -qx 'LARANODE_FIREWALL_ENABLED=true'; }
t  "ufw gated off: panel .env LARANODE_FIREWALL_ENABLED=false (Firewall page off)" fw_env_pve
t  "ufw on: LARANODE_FIREWALL_ENABLED=true"                                        fw_env_plain
fw_env_called() { bash -c "source '$INSTALLER'; declare -f phase_app" | grep -q '_panel_feature_env'; }
t  "phase_app writes the panel feature env"                                       fw_env_called
seam_hostconf() { grep -qE 'unset .*LARANODE_HOST_CONF' <(installer_code | sed -n '1,30p' | tr '\n' ' '); }
t  "LARANODE_HOST_CONF / pool / sudoers / stash seams dropped from the inherited env" bash -c "
  sed -n '1,30p' '$INSTALLER' | tr '\n' ' ' | grep -qE 'LARANODE_HOST_CONF' &&
  sed -n '1,30p' '$INSTALLER' | tr '\n' ' ' | grep -qE 'LARANODE_PHP_POOL_DIR' &&
  sed -n '1,30p' '$INSTALLER' | tr '\n' ' ' | grep -qE 'LARANODE_SUDOERS_DIR' &&
  sed -n '1,30p' '$INSTALLER' | tr '\n' ' ' | grep -qE 'LARANODE_STASH_PARENT'"

# ==== PR B: G1 clone pinned to a ref ================================================================
echo "=== PR B: clone ref pin ==="
# a local origin: main = A -> B, tag v1 = A, branch feat = B -> C
ref_repo() { local r; r=$(mktemp -d); git -C "$r" init -q -b main
  git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m A; git -C "$r" tag v1
  git -C "$r" tag fedcba9876543210fedcba9876543210fedcba98   # a 40-hex TAG name on A, not that commit
  git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m B
  git -C "$r" checkout -q -b feat; git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m C
  git -C "$r" checkout -q main; echo "$r"; }
REF_REPO=$(ref_repo)
REF_A=$(git -C "$REF_REPO" rev-parse v1); REF_C=$(git -C "$REF_REPO" rev-parse feat)
clone_to() { base; d=$(mktemp -d); PANEL_PATH="$d/panel"; LARANODE_REPO="$REF_REPO"; export LARANODE_REF="$1"; _resolve_ref; _clone_panel; git -C "$PANEL_PATH" rev-parse HEAD; }
clone_tag()    { [ "$(clone_to v1 | tail -1)" = "$REF_A" ]; }
clone_sha()    { [ "$(clone_to "$REF_C" | tail -1)" = "$REF_C" ]; }
t  "LARANODE_REF=<tag> clones the tag"                                              clone_tag
t  "LARANODE_REF=<full 40-hex commit id> clones exactly that commit"                clone_sha
# r1 review: only a tag or a full commit id pins; a branch, HEAD or a short id is a moving or
# ambiguous name, refused (agent pick, PR #11 r1 nit 4)
tfm "LARANODE_REF=<branch> refused (a branch moves)"            "is not a tag"            clone_to feat
tfm "LARANODE_REF=main (the default branch) refused"            "is not a tag"            clone_to main
tfm "LARANODE_REF=HEAD refused (the remote's moving default)"   "is a moving reference"   clone_to HEAD
tfm "LARANODE_REF=FETCH_HEAD refused"                           "is a moving reference"   clone_to FETCH_HEAD
tfm "LARANODE_REF=origin/main refused"                          "is a moving reference"   clone_to origin/main
tfm "LARANODE_REF=refs/heads/main refused"                      "is a moving reference"   clone_to refs/heads/main
tfm "LARANODE_REF=<short sha> refused (ambiguous)"              "short commit id"         clone_to "${REF_A:0:10}"
tfm "LARANODE_REF=<40-hex naming no commit> refused"            "is not a tag"            clone_to 0123456789abcdef0123456789abcdef01234567
tfm "LARANODE_REF=<40-hex that is only a tag name> refused"   "is not a tag"            clone_to fedcba9876543210fedcba9876543210fedcba98
tfm "LARANODE_REF naming nothing in the repo: refused"          "is not a tag"            clone_to no-such-ref
# the clone must also be CLEAN: git status --porcelain empty (as laranode_ln)
clone_dirty() { base; d=$(mktemp -d); PANEL_PATH="$d/panel"; LARANODE_REPO="$REF_REPO"; export LARANODE_REF=v1; _resolve_ref
  git() { command git "$@"; local rc=$?; case " $* " in *" checkout "*) echo planted > "$PANEL_PATH/planted.php" ;; esac; return $rc; }
  _clone_panel; }
tfm "clone at the ref but with a file planted in the tree: refused (status --porcelain)" "is not clean" clone_dirty
clone_clean_as_panel_user() { bash -c "source '$INSTALLER'; declare -f _checkout_clean" | grep -qE '_as_panel_user git -C "\$1" status --porcelain'; }
t  "the clean-tree check runs git status --porcelain AS the panel user"             clone_clean_as_panel_user
ref_none() { base; unset LARANODE_REF; LARANODE_PINNED_REF=""; _resolve_ref; }
tfm "no LARANODE_REF and no pinned ref: refused (never the silent default branch)"  "No ref to install" ref_none
ref_pinned() { base; unset LARANODE_REF; LARANODE_PINNED_REF=v1; _resolve_ref; expect REF "$PANEL_REF" v1; }
t  "no LARANODE_REF: the installer's pinned ref is used"                            ref_pinned
tfm "LARANODE_REF starting with '-' refused (option injection)"  "is not a plain tag" clone_to --upload-pack=x
tfm "LARANODE_REF with '..' refused"                             "is not a plain tag" clone_to 'a..b'
tfm "LARANODE_REF with a shell metacharacter refused"            "is not a plain tag" clone_to 'v1;id'
tfm "LARANODE_REF with a space refused"                          "is not a plain tag" clone_to 'v1 x'
clone_mismatch() { base; d=$(mktemp -d); PANEL_PATH="$d/panel"; LARANODE_REPO="$REF_REPO"; export LARANODE_REF=v1; _resolve_ref
  git() { if [ "${3:-}" = checkout ] || [ "${5:-}" = checkout ]; then return 0; fi; command git "$@"; }   # checkout silently does nothing
  _clone_panel; }
tf "HEAD after the checkout differs from the ref: refused (rev-parse verify)"        clone_mismatch
clone_symlink() { base; d=$(mktemp -d); mkdir "$d/elsewhere"; ln -s "$d/elsewhere" "$d/panel"; PANEL_PATH="$d/panel"
  LARANODE_REPO="$REF_REPO"; export LARANODE_REF=v1; _resolve_ref; _clone_panel; }
tf "PANEL_PATH is a symlink: refused before the root git clone (r4 nit 4)"           clone_symlink
verify_rerun() { base; d=$(mktemp -d); PANEL_PATH="$d/panel"; git clone -q "$REF_REPO" "$PANEL_PATH"; git -C "$PANEL_PATH" checkout -q --detach "$REF_C"
  export LARANODE_REF="$1"; _verify_checkout_ref; }
t  "re-run: an existing checkout at LARANODE_REF (full commit id) is accepted"       verify_rerun "$REF_C"
tf "re-run: an existing checkout NOT at LARANODE_REF is refused"                     verify_rerun v1
tfm "re-run: LARANODE_REF=<branch> refused even when HEAD is its tip"   "is not a tag" verify_rerun feat
verify_rerun_dirty() { base; d=$(mktemp -d); PANEL_PATH="$d/panel"; git clone -q "$REF_REPO" "$PANEL_PATH"; git -C "$PANEL_PATH" checkout -q --detach "$REF_C"
  echo planted > "$PANEL_PATH/planted.php"; export LARANODE_REF="$REF_C"; _verify_checkout_ref; }
tfm "re-run: checkout at the ref but with local changes refused"        "is not clean" verify_rerun_dirty
verify_rerun_unset() { base; d=$(mktemp -d); PANEL_PATH="$d/panel"; mkdir -p "$PANEL_PATH"; unset LARANODE_REF; _verify_checkout_ref; }
t  "re-run without LARANODE_REF: the existing checkout is kept as it is"             verify_rerun_unset
verify_as_panel_user() { bash -c "source '$INSTALLER'; declare -f _verify_checkout_ref" | grep -E '(^|[^_[:alnum:]])git ' | grep -vq '_as_panel_user' && return 1; return 0; }
t  "re-run verify runs git AS the panel user (never root git in its checkout)"      verify_as_panel_user
fetch_uses_clone() { bash -c "source '$INSTALLER'; declare -f phase_fetch_panel" | grep -q '_clone_panel' \
  && ! bash -c "source '$INSTALLER'; declare -f phase_fetch_panel" | grep -qE 'git clone "\$\{LARANODE_REPO\}"'; }
t  "phase_fetch_panel clones through _clone_panel (ref + verify)"                    fetch_uses_clone
pre_resolves_ref() { bash -c "source '$INSTALLER'; declare -f preflight" | grep -q '_resolve_ref'; }
t  "preflight resolves the ref before the confirm (refuses before any change)"       pre_resolves_ref

# ==== PR B: G3 production env ==========================================================================
echo "=== PR B: APP_ENV / APP_DEBUG ==="
g3_body() { bash -c "source '$INSTALLER'; declare -f phase_app"; }
g3_env() { g3_body | grep -qE 'env_set APP_ENV "?production"?' && g3_body | grep -qE 'env_set APP_DEBUG "?false"?'; }
g3_after_install() { local a b
  a=$(g3_body | grep -n 'reverb:install' | head -1 | cut -d: -f1); b=$(g3_body | grep -n 'env_set APP_ENV' | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ]; }
t  "phase_app writes APP_ENV=production and APP_DEBUG=false"                         g3_env
t  "... after the one-time artisan installs (their behaviour unchanged)"            g3_after_install

# ==== PR B: PR A review r4 nits ========================================================================
echo "=== PR B: r4 nits ==="
envset_val() { base; d=$(mktemp -d); : > "$d/.env"; env_set K "$1" "$d/.env"; }
t  "env_set accepts a plain value"                                                   envset_val 'http://1.2.3.4:8080'
tf "env_set refuses a value with a newline (no second KEY= line, no truncation)"    envset_val $'a\nAPP_DEBUG=true'
tf "env_set refuses a value with a double quote"                                    envset_val 'a"b'
tf "env_set refuses a value with a carriage return"                                 envset_val $'a\rb'
stash_parent() { local d p s out
  d=$(mktemp -d); p=$(mktemp -d); mkdir -p "$d/laranode-scripts/bin"; printf 'echo X\n' > "$d/laranode-scripts/bin/laranode-sync-scripts.sh"
  out=$(bash -c "
    source '$INSTALLER'
    PANEL_PATH='$d'; LN_LIB_DEST='$d/nolib'; LARANODE_STASH_PARENT='$p'; TMPDIR=/nonexistent-tmp
    _stash_sync_script; ls -d \"\$LN_SYNC_STASH\"; die 'boom'" 2>&1)
  s=$(ls -A "$p"); rm -rf "$d" "$p"
  case "$out" in "$p"/*) : ;; *) echo "stash not under the root-only parent: $out"; return 1 ;; esac
  [ -z "$s" ] || { echo "stash leaked after a die: $s"; return 1; }; }
t  "sync stash lives under a root-only parent (not \$TMPDIR) and is removed on die"  stash_parent
# root never reads the panel .env itself (a symlinked .env -> root file would leak lines)
envread_as_panel() { local bad
  bad=$(installer_root_code | grep -nE '(grep|cat|cut|head|sed -n)[^|]*(\.env"|\.env$|\.env |/\.env)' | grep -vE '_as_panel_user|\.env\.example' || true)
  [ -z "$bad" ] || { echo "root reads the panel .env:"; echo "$bad"; return 1; }; }
t  "root never greps/reads the panel .env (reads go through _env_get as laranode_ln)" envread_as_panel
envget_missing_user() { base; d=$(mktemp -d); PANEL_PATH="$d"; _as_panel_user() { return 1; }; [ -z "$(_env_get APP_URL)" ]; }
t  "_env_get on a first install (no .env, no panel user yet) yields nothing, no error" envget_missing_user
envget_value() { base; d=$(mktemp -d); PANEL_PATH="$d"; printf 'APP_URL="http://x"\nAPP_URLX=no\n' > "$d/.env"; expect v "$(_env_get APP_URL)" 'http://x'; }
t  "_env_get returns the unquoted value of exactly that key"                         envget_value

# the arch test itself must catch the bypasses the r4 reviewer reproduced (each would slip a root
# write past a purely line-by-line grep). Inject each into a copy of the installer, run the arch test.
ARCH_BYPASSES=(
  'multi-line cp|  cp /x \\\n    "$p/.env"'
  'alias variable|  q="$p/.env"; cp /x "$q"'
  'cd + relative path|  cd "$p" \&\& chmod 777 .env'
  'same line after _as_panel_user|  _as_panel_user true; cp /x "$p/.env"'
  'tar into the tree|  tar -C "$p" -xf /x'
  'rsync into the tree|  rsync -a /x/ "$p/"'
  'root git in the tree|  git -C "$p" pull'
)
arch_catches() { local m name ins w rc out
  w=$(mktemp -d)
  for m in "${ARCH_BYPASSES[@]}"; do
    name="${m%%|*}"; ins="${m#*|}"
    cp "$INSTALLER" "$w/i.sh"
    sed -i "/^_settle_permissions() {$/,/^}/ s#^  local h=/home/laranode_ln p=\"\${PANEL_PATH}\"\$#&\n${ins}#" "$w/i.sh"
    cmp -s "$INSTALLER" "$w/i.sh" && { echo "injection failed: $name"; rm -rf "$w"; return 1; }
    out=$(INSTALLER="$w/i.sh" bash -c "$(declare -f installer_code installer_root_code priv_no_root_touch_of_panel_paths); PANEL_USER_BODIES='$PANEL_USER_BODIES'; $(declare -p ROOT_PANEL_ALLOW); priv_no_root_touch_of_panel_paths" 2>&1); rc=$?
    [ "$rc" -ne 0 ] || { echo "arch test MISSED: $name"; rm -rf "$w"; return 1; }
  done
  rm -rf "$w"; }
t  "arch test catches multi-line, alias, cd+relative, same-line, tar/rsync/git bypasses" arch_catches
echo ""
echo "Results: passed=$PASS  failed=$FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL PASS" && exit 0
echo "FAILURES: $FAIL"
exit 1
