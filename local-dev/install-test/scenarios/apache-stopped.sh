#!/usr/bin/env bash
# Scenario: apache2 is installed but STOPPED and disabled (a standby / maintenance /
# on-demand service that is not ours).
#
# Ownership is "the package was absent before this run", not "it is running":
#   1. Without LARANODE_START_STOPPED=1 the installer refuses in preflight and
#      changes nothing (checked in PRESETUP: stays stopped + disabled, ports.conf
#      and sites identical, no panel vhost, no PHP 8.4).
#   2. With LARANODE_START_STOPPED=1 (and the panel on :8080) it adds the panel vhost
#      and ONE Listen line, starts apache2 (never enables it at boot), leaves
#      000-default and the module set (apart from what the panel vhost needs) alone,
#      and records the unit as managed:false plus the modules it enabled.
set -euo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCENARIO_DIR}/../lib.sh"

export SCENARIO="apache-stopped"

export PRESETUP='
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q >/dev/null 2>&1
    apt-get install -y --quiet apache2 curl >/dev/null 2>&1
    systemctl disable --now apache2 >/dev/null 2>&1
    [ "$(systemctl is-active apache2 || true)" != active ] || { echo "PRESETUP: apache2 still active" >&2; exit 1; }
    [ "$(systemctl is-enabled apache2 2>/dev/null || true)" = disabled ] || { echo "PRESETUP: apache2 not disabled" >&2; exit 1; }
    cp /etc/apache2/ports.conf /root/ports.conf.before
    ls /etc/apache2/sites-enabled > /root/sites-enabled.before
    ls /etc/apache2/mods-enabled > /root/mods-enabled.before
    a2query -m ssl >/dev/null 2>&1 && echo yes > /root/ssl.before || echo no > /root/ssl.before

    echo "PRESETUP: apache2 installed, stopped, disabled; running the installer WITHOUT the opt-in (must refuse)..."
    rc=0
    out=$(LARANODE_UNATTENDED=1 bash /home/laranode_ln/panel/laranode-scripts/bin/laranode-installer.sh 2>&1) || rc=$?
    printf "%s\n" "$out" | tail -5
    [ "$rc" -ne 0 ] || { echo "PRESETUP FAIL: installer accepted a stopped pre-existing apache2 without LARANODE_START_STOPPED=1" >&2; exit 1; }
    printf "%s" "$out" | grep -q LARANODE_START_STOPPED || { echo "PRESETUP FAIL: refusal does not name LARANODE_START_STOPPED" >&2; exit 1; }
    [ "$(systemctl is-active apache2 || true)" != active ] || { echo "PRESETUP FAIL: refused run started apache2" >&2; exit 1; }
    [ "$(systemctl is-enabled apache2 2>/dev/null || true)" = disabled ] || { echo "PRESETUP FAIL: refused run enabled apache2" >&2; exit 1; }
    cmp -s /etc/apache2/ports.conf /root/ports.conf.before || { echo "PRESETUP FAIL: ports.conf changed by a refused run" >&2; exit 1; }
    [ ! -e /etc/apache2/sites-available/laranode.conf ] || { echo "PRESETUP FAIL: panel vhost written by a refused run" >&2; exit 1; }
    ! dpkg -s php8.4-fpm >/dev/null 2>&1 || { echo "PRESETUP FAIL: php8.4 installed by a refused run" >&2; exit 1; }
    echo "PRESETUP PASS: refused, nothing touched"
'

# Port 8080 explicitly: sharing :80 would put the panel vhost (no ServerName) behind the
# owner's 000-default, which answers every request by IP.
export INSTALLER_ENV="LARANODE_UNATTENDED=1 LARANODE_START_STOPPED=1 LARANODE_HTTP_PORT=8080"
export EXPECT_PORT=8080
export EXPECT_ENGINE=mysql

export POST_ASSERTS_CMD='
    [ "$(systemctl is-enabled apache2 2>/dev/null || true)" = disabled ] \
        || { echo "FAIL: apache2 was enabled at boot (it must stay disabled)" >&2; exit 1; }
    echo "PASS: apache2 started but still disabled at boot"
    # the only change to ports.conf is ONE appended panel Listen; the owner lines stay
    diff <(cat /root/ports.conf.before; echo "Listen 8080") /etc/apache2/ports.conf >/dev/null \
        || { echo "FAIL: ports.conf differs from the original + one Listen 8080" >&2; diff /root/ports.conf.before /etc/apache2/ports.conf >&2; exit 1; }
    [ -e /etc/apache2/sites-enabled/000-default.conf ] \
        || { echo "FAIL: 000-default was disabled" >&2; exit 1; }
    [ -e /etc/apache2/sites-enabled/laranode.conf ] \
        || { echo "FAIL: panel vhost not enabled" >&2; exit 1; }
    echo "PASS: ports.conf untouched, 000-default kept, panel vhost added"
    after=no; a2query -m ssl >/dev/null 2>&1 && after=yes
    [ "$after" = "$(cat /root/ssl.before)" ] \
        || { echo "FAIL: mod_ssl state changed" >&2; exit 1; }
    for m in headers setenvif proxy_http; do
        if a2query -m "$m" >/dev/null 2>&1 && ! grep -qx "$m.load" /root/mods-enabled.before; then
            echo "FAIL: unneeded module $m was enabled on a pre-existing Apache" >&2; exit 1
        fi
    done
    echo "PASS: no ssl and none of the extra modules (headers/setenvif/proxy_http) added"
    [ ! -e /etc/apache2/conf-enabled/php8.4-fpm.conf ] \
        || { echo "FAIL: global php8.4-fpm conf enabled on a pre-existing Apache" >&2; exit 1; }
    mf=/etc/laranode/service-manifest.json
    grep -q "\"unit\":\"apache2.service\",\"managed\":false" "$mf" \
        || { echo "FAIL: apache2.service should be managed:false" >&2; cat "$mf" >&2; exit 1; }
    grep -q "\"apache_modules_enabled\":\[[^]]*\"proxy_fcgi\"" "$mf" \
        || { echo "FAIL: manifest does not record the enabled modules" >&2; cat "$mf" >&2; exit 1; }
    echo "PASS: manifest: apache2 managed:false, enabled modules recorded"
'

run_scenario
