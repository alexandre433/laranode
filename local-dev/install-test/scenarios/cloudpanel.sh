#!/usr/bin/env bash
# Scenario: CloudPanel-like production host (the DS box).
#   nginx on :80/:443 (+ a "Varnish backend" stand-in on :8080), /home/clp marker,
#   an existing MySQL-family server (MariaDB stands in for Percona: it conflicts with
#   mysql-server exactly like Percona does), a live PostgreSQL 16 cluster, ufw active
#   with a rule set, and php8.4 already installed from a third-party build.
# The installer must: never remove the DB server, never touch pg_hba/PG16, keep nginx
# and the :8080 backend answering, add no ufw rules, put the panel on 127.0.0.1:8090
# and Reverb on 8081.
set -euo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCENARIO_DIR}/../lib.sh"

export SCENARIO="cloudpanel"
export PRESETUP='
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q >/dev/null 2>&1
    apt-get install -y --quiet nginx openssl ufw mariadb-server postgresql software-properties-common >/dev/null 2>&1
    # CloudPanel ships its own php8.4 build; stand in with the ondrej build.
    add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1
    apt-get update -q >/dev/null 2>&1
    apt-get install -y --quiet php8.4-fpm php8.4-cli >/dev/null 2>&1
    mkdir -p /home/clp
    openssl req -x509 -nodes -newkey rsa:2048 -days 2 -subj /CN=clp.test \
        -keyout /etc/ssl/private/clp.key -out /etc/ssl/certs/clp.crt >/dev/null 2>&1
    cat > /etc/nginx/conf.d/clp-standin.conf <<NGX
server { listen 80 default_server; location / { return 200 "NGINX_80\n"; } }
server { listen 443 ssl default_server; ssl_certificate /etc/ssl/certs/clp.crt; ssl_certificate_key /etc/ssl/private/clp.key;
         location / { return 200 "NGINX_443\n"; } }
server { listen 127.0.0.1:8080; location / { return 200 "VARNISH_BACKEND_8080\n"; } }
NGX
    rm -f /etc/nginx/sites-enabled/default
    systemctl restart nginx
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1 || true
    ufw show added > /root/ufw.before 2>&1
    pg=$(pg_lsclusters --no-header | awk "NR==1{print \$1\"/\"\$2}")
    md5sum /etc/postgresql/${pg}/hba 2>/dev/null >/dev/null || true
    md5sum /etc/postgresql/*/main/pg_hba.conf > /root/hba.before
    pg_lsclusters --no-header > /root/pg.before
    dpkg -s mariadb-server | sed -n "s/^Version: //p" > /root/db.version.before
    for _ in $(seq 1 15); do ss -tlnH "( sport = :80 )" | grep -q . && break; sleep 1; done
    echo "PRESETUP: clp-like host ready (nginx 80/443/8080, mariadb, pg, ufw, php8.4)"
'
# Defaults on purpose: the installer has to work out :80 busy + CloudPanel on its own.
export INSTALLER_ENV="LARANODE_UNATTENDED=1"
export EXPECT_PORT=8090
export EXPECT_ENGINE=mysql

export POST_ASSERTS_CMD='
    # existing DB server still installed, same version, still running
    v=$(dpkg -s mariadb-server | sed -n "s/^Version: //p")
    [ "$v" = "$(cat /root/db.version.before)" ] || { echo "FAIL: mariadb-server changed ($v)" >&2; exit 1; }
    dpkg -s mysql-server >/dev/null 2>&1 && { echo "FAIL: mysql-server was installed over the existing server" >&2; exit 1; }
    systemctl is-active --quiet mariadb || { echo "FAIL: mariadb not running" >&2; exit 1; }
    echo "PASS: existing DB server kept (mariadb-server $v), no mysql-server"
    # nginx + the backend stand-in answer unchanged
    [ "$(curl -s --max-time 5 http://127.0.0.1:80/)" = "NGINX_80" ] || { echo "FAIL: nginx :80 changed" >&2; exit 1; }
    [ "$(curl -sk --max-time 5 https://127.0.0.1:443/)" = "NGINX_443" ] || { echo "FAIL: nginx :443 changed" >&2; exit 1; }
    [ "$(curl -s --max-time 5 http://127.0.0.1:8080/)" = "VARNISH_BACKEND_8080" ] || { echo "FAIL: :8080 backend changed" >&2; exit 1; }
    echo "PASS: nginx :80, :443 and the :8080 backend untouched"
    # PostgreSQL 16 untouched
    pg_lsclusters --no-header | diff -q - /root/pg.before >/dev/null || { echo "FAIL: pg clusters changed" >&2; pg_lsclusters >&2; exit 1; }
    md5sum /etc/postgresql/*/main/pg_hba.conf | diff -q - /root/hba.before >/dev/null || { echo "FAIL: pg_hba.conf changed" >&2; exit 1; }
    echo "PASS: PostgreSQL clusters and pg_hba.conf untouched"
    # ufw: no rule added
    ufw show added | diff -q - /root/ufw.before >/dev/null || { echo "FAIL: ufw rules changed" >&2; ufw show added >&2; exit 1; }
    echo "PASS: ufw rules unchanged"
    # panel loopback only, on 8090; reverb 8081
    ss -tlnH "( sport = :8090 )" | awk "{print \$4}" | grep -qx "127.0.0.1:8090" || { echo "FAIL: panel not on 127.0.0.1:8090" >&2; ss -tlnH >&2; exit 1; }
    ss -tlnH "( sport = :8081 )" | awk "{print \$4}" | grep -qx "127.0.0.1:8081" || { echo "FAIL: reverb not on 127.0.0.1:8081" >&2; ss -tlnH >&2; exit 1; }
    echo "PASS: panel 127.0.0.1:8090, reverb 127.0.0.1:8081"
    # system php alternative untouched by the installer (no PPA re-add logic needed)
    ss -tlnp "( sport = :443 )" | grep -q apache2 && { echo "FAIL: apache took :443" >&2; exit 1; }
    echo "PASS: apache not on :443"
'

run_scenario
