#!/usr/bin/env bash
# Scenario: upgrade a Proxmox install made by the www-data installer (PR A, before the dedicated
# web user) that already hosts a tenant site (PR #11 r1 item 3).
#   PRESETUP: Debian 13 + /etc/pve + a pveproxy stand-in (as pve-webuser); install the OLD tree
#   (UPGRADE_FROM_TAR = git archive of UPGRADE_FROM_REF), create tenant upgr_ln (not alice_ln: the
#   post sudo-hardening harness creates and deletes its own alice_ln) with a PHP-FPM
#   pool and a vhost (the old user-manager puts www-data in group upgr_ln), prove the site
#   serves; then lay the current tree over the checkout as laranode_ln.
#   Main run: the current installer (the upgrade).
# Asserts: web_user=laranode_web, laranode_web is in upgr_ln, www-data is in NO *_ln group and
# cannot list the tenant home, the tenant site still serves through PHP-FPM, www-data holds no
# laranode sudo grant.
set -euo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCENARIO_DIR}/../lib.sh"

# the PR A merge on development: the last installer that ran the panel as www-data on Proxmox
UPGRADE_FROM_REF="${UPGRADE_FROM_REF:-bee405f}"
_tar="$(mktemp "${TMPDIR:-/tmp}/laranode-upgrade-from.XXXXXX")"
trap 'rm -f "$_tar"' EXIT
# cd, not git -C: a Windows git under MSYS_NO_PATHCONV cannot resolve a /c/... argument
( cd "${SCENARIO_DIR}/../../.." && git archive --format=tar -o "$_tar" "$UPGRADE_FROM_REF" ) \
    || { echo "FAIL: git archive ${UPGRADE_FROM_REF} (CI needs fetch-depth: 0)" >&2; exit 1; }
export UPGRADE_FROM_TAR="$_tar"

export SCENARIO="pve-upgrade"
export IMAGE="jrei/systemd-debian:13"
export PRESETUP='
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    mkdir -p /etc/pve/priv /usr/local/sbin
    printf "PVE-SECRET-KEY\n" > /etc/pve/priv/authkey.key
    chown root:www-data /etc/pve/priv/authkey.key; chmod 640 /etc/pve/priv/authkey.key
    chown root:www-data /etc/pve/priv; chmod 750 /etc/pve/priv
    printf "#!/bin/sh\nexec sleep infinity\n" > /usr/local/sbin/pveproxy; chmod 755 /usr/local/sbin/pveproxy
    printf "[Unit]\nDescription=stand-in PVE API Proxy Server\n[Service]\nUser=www-data\nGroup=www-data\nExecStart=/usr/local/sbin/pveproxy\n[Install]\nWantedBy=multi-user.target\n" \
        > /etc/systemd/system/pveproxy.service
    systemctl daemon-reload
    systemctl enable --now pveproxy.service >/dev/null 2>&1

    echo "[pve-upgrade] === install the OLD tree (www-data web user) ==="
    mv /home/laranode_ln/panel /tmp/new-panel
    mkdir -p /home/laranode_ln/panel
    tar -C /home/laranode_ln/panel -xf /root/upgrade-from.tar
    LARANODE_UNATTENDED=1 COMPOSER_CACHE_DIR=/composer-cache \
        bash /home/laranode_ln/panel/laranode-scripts/bin/laranode-installer.sh > /tmp/upgrade-from-install.log 2>&1 \
        || { tail -40 /tmp/upgrade-from-install.log >&2; fail "old installer failed"; }

    echo "[pve-upgrade] === tenant upgr_ln: user, pool, vhost (old scripts) ==="
    B=/usr/local/lib/laranode/bin; T=/usr/local/lib/laranode/templates
    [ -x "$B/laranode-user-manager.sh" ] || fail "old install has no $B/laranode-user-manager.sh"
    "$B/laranode-user-manager.sh" create upgr_ln no
    install -d -o upgr_ln -g upgr_ln -m 750 /home/upgr_ln/domains/tenant.test /home/upgr_ln/domains/tenant.test/public
    printf "<?php echo \"TENANT-OK \" . get_current_user();\n" > /home/upgr_ln/domains/tenant.test/public/index.php
    chown upgr_ln:upgr_ln /home/upgr_ln/domains/tenant.test/public/index.php
    "$B/laranode-add-php-fpm-pool.sh" upgr_ln 8.4 "$T/php-fpm-pool.template"
    # tenant.test sorts after the panel vhost: a request by IP (the harness GET :80/login) keeps hitting the panel
    "$B/laranode-add-vhost.sh" upgr_ln tenant.test /public 8.4 "$T/apache-vhost.template"
    sleep 2
    id -nG www-data | tr " " "\n" | grep -qx upgr_ln || fail "old user-manager did not put www-data in upgr_ln (not a PR A state)"
    out=$(curl -s -H "Host: tenant.test" http://127.0.0.1/index.php)
    case "$out" in "TENANT-OK upgr_ln"*) : ;; *) fail "tenant site before the upgrade answered: ${out:0:200}" ;; esac
    echo "PASS: old install serves the tenant site as www-data (www-data in upgr_ln)"

    echo "[pve-upgrade] === lay the current tree over the checkout as laranode_ln ==="
    tar -C /tmp/new-panel -cf - . | runuser -u laranode_ln -- tar -C /home/laranode_ln/panel --no-same-owner -xf -
    rm -rf /tmp/new-panel
    rm -f /home/laranode_ln/panel/bootstrap/cache/*.php

    echo "[pve-upgrade] === a re-run that dies on a bad LARANODE_REF must leave the old setup serving (PR #11 r2) ==="
    # the injected checkout has no .git: with LARANODE_REF set the ref check dies. Before PR #11 r2 the
    # tenant-group migration ran BEFORE that check: www-data left upgr_ln while Apache still ran as www-data.
    if LARANODE_UNATTENDED=1 LARANODE_HTTP_PORT=80 LARANODE_REF=v0.0.0-no-such-tag COMPOSER_CACHE_DIR=/composer-cache \
        bash /home/laranode_ln/panel/laranode-scripts/bin/laranode-installer.sh > /tmp/badref-run.log 2>&1; then
        fail "the re-run with a bad LARANODE_REF succeeded"
    fi
    grep -qE "LARANODE_REF is set but .* has no .git|is not a tag" /tmp/badref-run.log \
        || { tail -15 /tmp/badref-run.log >&2; fail "the re-run died, but not on the ref check"; }
    id -nG www-data | tr " " "\n" | grep -qx upgr_ln \
        || fail "bad-ref re-run stripped www-data from upgr_ln while Apache still runs as www-data"
    out=$(curl -s -H "Host: tenant.test" http://127.0.0.1/index.php)
    case "$out" in "TENANT-OK upgr_ln"*) : ;; *) fail "tenant site down after the failed bad-ref re-run: ${out:0:200}" ;; esac
    echo "PASS: bad-ref re-run died on the ref check; www-data still in upgr_ln, tenant site still serves"
'
# the re-run keeps the panel where the first run put it (unset, it would see its own :80 and fall back)
export INSTALLER_ENV="LARANODE_UNATTENDED=1 LARANODE_HTTP_PORT=80"
export EXPECT_PORT=80
export EXPECT_ENGINE=pgsql

export POST_ASSERTS_CMD='
    fail() { echo "FAIL: $*" >&2; exit 1; }
    grep -qx "web_user=laranode_web" /etc/laranode/host.conf || fail "host.conf does not record web_user=laranode_web"
    id -nG laranode_web | tr " " "\n" | grep -qx upgr_ln || fail "laranode_web not in tenant group upgr_ln"
    for g in $(id -nG www-data); do case "$g" in *_ln) fail "www-data still in group $g after the upgrade" ;; esac; done
    getent group | awk -F: "\$1 ~ /_ln\$/ && (\",\" \$4 \",\") ~ /,www-data,/ {print \$1}" | grep -q . \
        && fail "a *_ln group still lists www-data: $(getent group | grep _ln: | grep www-data)"
    echo "PASS: tenant group moved: laranode_web in upgr_ln, www-data in no *_ln group"
    runuser -u www-data -- ls /home/upgr_ln >/dev/null 2>&1 && fail "www-data can still list /home/upgr_ln"
    echo "PASS: www-data cannot read the tenant home"
    systemctl reload php8.4-fpm 2>/dev/null || true
    sleep 1
    out=$(curl -s -H "Host: tenant.test" http://127.0.0.1/index.php)
    case "$out" in "TENANT-OK upgr_ln"*) : ;; *)
        { curl -s -o /dev/null -w "HTTP %{http_code}\n" -H "Host: tenant.test" http://127.0.0.1/index.php
          echo "$out" | grep -iE "<title>|<p>" | head -3
          tail -5 /home/upgr_ln/logs/apache-error.log 2>/dev/null; tail -5 /var/log/apache2/error.log 2>/dev/null
          ls -l /run/php/ | grep upgr_ln; ps -o user:20,group:20,supgrp:60 -C apache2 | head -4; } >&2
        fail "tenant site after the upgrade answered: ${out:0:120}" ;; esac
    echo "PASS: tenant site still serves through its PHP-FPM pool after the upgrade"
    apache2ctl -t -D DUMP_RUN_CFG 2>/dev/null | grep -q "^User: name=\"laranode_web\"" || fail "Apache User is not laranode_web"
    sudo -n -l -U www-data 2>/dev/null | grep -q laranode && fail "www-data holds a laranode sudo grant"
    id -nG www-data | tr " " "\n" | grep -qx laranode_ln && fail "www-data is in group laranode_ln"
    echo "PASS: Apache runs as laranode_web; www-data has no laranode sudo and no panel group"
'

run_scenario
