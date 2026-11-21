#!/usr/bin/env bash
# local-dev/install-test/unit/test-host-detection.sh
# Host-only tests (no Docker, no root, ~1 s) for the OS / Proxmox / CloudPanel /
# Percona logic in laranode-installer.sh. Every external fact is stubbed through
# the installer's own helpers or the LARANODE_*_DIR / LARANODE_OS_RELEASE_FILE
# overrides, so the tests run the same on Git Bash, WSL and Linux.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/../../../laranode-scripts/bin/laranode-installer.sh"
FIX="${SCRIPT_DIR}/fixtures"

PASS=0; FAIL=0
pass()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
flunk() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
# t NAME CMD... — run CMD in a subshell, PASS when it exits 0
t() { local n="$1"; shift; if ( "$@" ) >/tmp/laranode-ut.$$ 2>&1; then pass "$n"; else flunk "$n"; sed 's/^/        /' /tmp/laranode-ut.$$; fi; }
# tf NAME CMD... — PASS when CMD exits non-zero (a refusal)
tf() { local n="$1"; shift; if ( "$@" ) >/tmp/laranode-ut.$$ 2>&1; then flunk "$n (expected refusal)"; else pass "$n"; fi; }
trap 'rm -f /tmp/laranode-ut.$$' EXIT

# Common setup for each subshell: fresh installer, plain Ubuntu host, quiet logs.
base() {
  # shellcheck source=/dev/null
  source "$INSTALLER"
  export LARANODE_OS_RELEASE_FILE="${FIX}/os-release.ubuntu-24.04"
  export LARANODE_PVE_DIR=/nonexistent-pve LARANODE_CLP_DIR=/nonexistent-clp
  export LARANODE_UNATTENDED=1
  unset LARANODE_DB_ENGINE LARANODE_HTTP_PORT LARANODE_BIND LARANODE_PG_PORT
  have_cmd()    { return 1; }
  port_in_use() { return 1; }
  pkg_installed() { return 1; }
  pg_cluster_count() { echo 0; }
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
cron_setup() { base; PANEL_PATH=$(mktemp -d); mkdir -p "$PANEL_PATH/laranode-scripts/templates"; cp "$TPL_SRC" "$PANEL_PATH/laranode-scripts/templates/"; export LARANODE_CRON_DIR=$(mktemp -d); }
cron_renders() {
  cron_setup; _install_scheduler_cron
  line=$(grep -v '^#' "$LARANODE_CRON_DIR/laranode-schedule")
  [ "$line" = "* * * * * laranode_ln /usr/bin/php8.4 ${PANEL_PATH}/artisan schedule:run >> /dev/null 2>&1" ] \
    || { echo "got: $line"; return 1; }
  ! grep -q '__' "$LARANODE_CRON_DIR/laranode-schedule"
}
cron_missing_tpl() { cron_setup; rm "$PANEL_PATH/laranode-scripts/templates/laranode-schedule.cron"; _install_scheduler_cron; }
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
npm_legacy_peers() { grep -qE '^[[:space:]]+npm install --legacy-peer-deps$' "$INSTALLER"; }
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
pf_pre_apache_inactive() { pre_env; svc_active() { return 1; }; preflight; expect APACHE_OWNED "$APACHE_OWNED" 1; }
t  "apache2 installed but STOPPED (dependency of another pkg): owned, configured as before" pf_pre_apache_inactive
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
  base; PANEL_PATH=$(mktemp -d); printf 'APP_KEY=\n' > "$PANEL_PATH/.env.example"
  MLOG=$(mktemp); chmod() { echo "chmod $*" >> "$MLOG"; command chmod "$@"; }; chgrp() { echo "chgrp $*" >> "$MLOG"; }
  getent() { return 0; }
  _seed_env
  [ -f "$PANEL_PATH/.env" ] && grep -qx "chmod 640 $PANEL_PATH/.env" "$MLOG" && grep -qx "chgrp laranode_ln $PANEL_PATH/.env" "$MLOG"
}
seed_env_keeps_existing() { base; PANEL_PATH=$(mktemp -d); echo 'KEEP=1' > "$PANEL_PATH/.env"; : > "$PANEL_PATH/.env.example"; _seed_env; grep -qx 'KEEP=1' "$PANEL_PATH/.env"; }
no_plain_env_cp() { base; ! declare -f _mysql_branch _pgsql_branch phase_app | grep -E 'cp .*\.env\.example'; }
home_750() {
  base; PANEL_PATH=$(mktemp -d); mkdir "$PANEL_PATH/laranode-scripts"; MLOG=$(mktemp)
  useradd() { :; }; usermod() { :; }; chmod() { echo "chmod $*" >> "$MLOG"; }; id() { return 0; }
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

echo ""
echo "Results: passed=$PASS  failed=$FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL PASS" && exit 0
echo "FAILURES: $FAIL"
exit 1
