#!/usr/bin/env bash
# Scenario: Proxmox VE host where www-data is pveproxy's user (G2/G7).
# Debian 13 + /etc/pve marker + a stand-in pveproxy running as www-data, and a fake
# /etc/pve/priv key readable by group www-data (as on a real Proxmox node).
# The panel's Apache and PHP-FPM must run as the dedicated laranode_web; www-data gets no
# sudo grant and no laranode group; laranode_web cannot read the Proxmox key; no ufw
# sudoers and no Firewall page (LARANODE_PVE_UFW unset); the panel still serves and logs in.
set -euo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCENARIO_DIR}/../lib.sh"

export SCENARIO="pve-webuser"
export IMAGE="jrei/systemd-debian:13"
export PRESETUP='
    set -e
    mkdir -p /etc/pve/priv /usr/local/sbin
    # the key pveproxy reads: root:www-data 0640 (the real /etc/pve/priv/authkey.key mode)
    printf "PVE-SECRET-KEY\n" > /etc/pve/priv/authkey.key
    chown root:www-data /etc/pve/priv/authkey.key; chmod 640 /etc/pve/priv/authkey.key
    chown root:www-data /etc/pve/priv; chmod 750 /etc/pve/priv
    # stand-in pveproxy: a long-running process as www-data, like the real daemon
    cat > /usr/local/sbin/pveproxy <<SH
#!/bin/sh
exec sleep infinity
SH
    chmod 755 /usr/local/sbin/pveproxy
    cat > /etc/systemd/system/pveproxy.service <<UNIT
[Unit]
Description=stand-in PVE API Proxy Server
[Service]
User=www-data
Group=www-data
ExecStart=/usr/local/sbin/pveproxy
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now pveproxy.service >/dev/null 2>&1
    systemctl is-active pveproxy.service
'
export INSTALLER_ENV="LARANODE_UNATTENDED=1"
export EXPECT_PORT=80
export EXPECT_ENGINE=pgsql

export POST_ASSERTS_CMD='
    fail() { echo "FAIL: $*" >&2; exit 1; }
    # the stand-in pveproxy still runs as www-data, untouched
    systemctl is-active -q pveproxy.service || fail "pveproxy stand-in stopped"
    pp=$(systemctl show -p MainPID --value pveproxy.service)
    [ "$(ps -o user= -p "$pp" | tr -d " ")" = www-data ] || fail "pveproxy stand-in not running as www-data"
    echo "PASS: pveproxy stand-in still runs as www-data"
    # www-data: no sudo, no laranode group
    sudo -n -l -U www-data 2>/dev/null | grep -q laranode && { sudo -l -U www-data >&2; fail "www-data holds a laranode sudo grant"; }
    grep -rl "^www-data" /etc/sudoers.d/ 2>/dev/null | grep -q . && fail "a sudoers drop-in names www-data: $(grep -rl "^www-data" /etc/sudoers.d/)"
    id -nG www-data | tr " " "\n" | grep -qx laranode_ln && fail "www-data is in group laranode_ln"
    for g in $(id -nG www-data); do case "$g" in *_ln) fail "www-data is in hosted-user group $g" ;; esac; done
    echo "PASS: www-data has no laranode sudo grant and no laranode group"
    # laranode_web: system account, the grants, the panel group, NOT group www-data
    uid=$(id -u laranode_web) || fail "laranode_web missing"
    [ "$uid" -gt 0 ] && [ "$uid" -lt 1000 ] || fail "laranode_web uid $uid is not a system uid"
    id -nG laranode_web | tr " " "\n" | grep -qx laranode_ln || fail "laranode_web not in group laranode_ln"
    id -nG laranode_web | tr " " "\n" | grep -qx www-data && fail "laranode_web is in group www-data"
    sudo -n -l -U laranode_web | grep -q "/usr/local/lib/laranode/bin/laranode-" || fail "laranode_web holds no laranode sudo grant"
    grep -qx "web_user=laranode_web" /etc/laranode/host.conf || fail "host.conf does not record web_user=laranode_web"
    echo "PASS: laranode_web is a system user with the grants and the panel group"
    # laranode_web cannot read the Proxmox key; www-data still can (Proxmox untouched)
    runuser -u laranode_web -- cat /etc/pve/priv/authkey.key >/dev/null 2>&1 && fail "laranode_web can read /etc/pve/priv/authkey.key"
    runuser -u www-data -- cat /etc/pve/priv/authkey.key >/dev/null 2>&1 || fail "www-data lost read access to the Proxmox key (host changed)"
    echo "PASS: laranode_web cannot read /etc/pve/priv"
    # Apache + PHP-FPM workers run as laranode_web
    apache2ctl -t -D DUMP_RUN_CFG 2>/dev/null | grep -q "^User: name=\"laranode_web\"" || { apache2ctl -t -D DUMP_RUN_CFG >&2; fail "Apache User is not laranode_web"; }
    curl -s -o /dev/null http://127.0.0.1/login || true
    wa=$(ps -o user= -C apache2 | sort | uniq -c | tr "\n" ";")
    ps -o user= -C apache2 | grep -vx root | grep -vqx laranode_web && fail "apache2 worker not running as laranode_web: $wa"
    ps -o user= -C apache2 | grep -qx laranode_web || fail "no apache2 worker as laranode_web: $wa"
    grep -q "^user = laranode_web" /etc/php/8.4/fpm/pool.d/laranode-panel.conf || fail "panel pool does not run as laranode_web"
    pf=$(ps -o user=,args= -C php-fpm8.4 | grep "pool laranode-panel" | awk "{print \$1}" | sort -u | tr "\n" " ")
    [ -z "$pf" ] || [ "$pf" = "laranode_web " ] || fail "laranode-panel pool workers run as: $pf"
    echo "PASS: Apache workers and the panel PHP-FPM pool run as laranode_web"
    # ufw gated off: no drop-in, Firewall page 404, .env flag false
    [ -e /etc/sudoers.d/laranode-ufw ] && fail "laranode-ufw sudoers drop-in installed on Proxmox"
    grep -q "^LARANODE_FIREWALL_ENABLED=false" /home/laranode_ln/panel/.env || fail ".env lacks LARANODE_FIREWALL_ENABLED=false"
    echo "PASS: no laranode-ufw drop-in, firewall flag off"
    # production env, .env 640
    grep -q "^APP_ENV=production" /home/laranode_ln/panel/.env || fail "APP_ENV is not production"
    grep -q "^APP_DEBUG=false" /home/laranode_ln/panel/.env || fail "APP_DEBUG is not false"
    [ "$(stat -c %a /home/laranode_ln/panel/.env)" = 640 ] || fail ".env mode $(stat -c %a /home/laranode_ln/panel/.env)"
    echo "PASS: APP_ENV=production, APP_DEBUG=false, .env 640"
    # the panel works AS laranode_web: login page 200, an admin session reaches /dashboard,
    # and /admin/firewall is 404 for that admin
    j=$(mktemp); trap "rm -f $j" EXIT
    curl -s -o /dev/null -c "$j" -b "$j" http://127.0.0.1/login
    tok=$(awk "\$6==\"XSRF-TOKEN\"{print \$7}" "$j" | sed "s/%3D/=/g; s/%2B/+/g; s/%2F/\//g")
    [ -n "$tok" ] || fail "no XSRF-TOKEN cookie from /login"
    code=$(curl -s -o /dev/null -w "%{http_code}" -c "$j" -b "$j" -H "X-XSRF-TOKEN: $tok" \
        --data-urlencode "email=admin@laranode.test" --data-urlencode "password=password" http://127.0.0.1/login)
    case "$code" in 302|303) : ;; *) fail "POST /login answered $code" ;; esac
    code=$(curl -s -o /dev/null -w "%{http_code}" -c "$j" -b "$j" http://127.0.0.1/dashboard)
    [ "$code" = 200 ] || fail "GET /dashboard as admin answered $code"
    code=$(curl -s -o /dev/null -w "%{http_code}" -c "$j" -b "$j" http://127.0.0.1/admin/firewall)
    [ "$code" = 404 ] || fail "GET /admin/firewall as admin answered $code (want 404 on Proxmox)"
    echo "PASS: admin logs in over HTTP, dashboard 200, /admin/firewall 404"
'

run_scenario
