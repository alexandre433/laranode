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
apt_plain_upgrade_ok()   { base; apt_run 'Inst nginx-common [1.0] (1.1 Ubuntu)'; apt_passed; }
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
t "plain host: protected-looking upgrade passes (guard is host-scoped)"             apt_plain_upgrade_ok
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
  export LARANODE_PG_CREATECLUSTER_CONF="$conf" LARANODE_PG_DATADIR="$(mktemp -d)/pgdata/"
  ( _pgsql_branch ) >/dev/null 2>&1 || true
  grep -qxF "data_directory = '${LARANODE_PG_DATADIR%/}/%v/%c'" "$conf" \
    && [ "$(grep -c data_directory "$conf")" = 1 ] \
    && [ "$(sed -n 1p "$APT_CALLS")" = postgresql-common ] \
    && grep -q '^postgresql postgresql-client$' "$APT_CALLS"
}
tf "existing cluster, no LARANODE_PG_PORT: refuses to pick one"             pg_existing_needs_port
t  "existing cluster: server package untouched, no psql/sudo executed"      pg_existing_no_server_install
t  "fresh host: postgresql server + client installed"                       pg_fresh_installs_server
t  "LARANODE_PG_DATADIR: createcluster.conf written, common installed first" pg_datadir_config

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

echo ""
echo "Results: passed=$PASS  failed=$FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL PASS" && exit 0
echo "FAILURES: $FAIL"
exit 1
