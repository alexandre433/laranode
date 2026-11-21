#!/usr/bin/env bash
# Scenario: a running, pre-existing Apache serves a live site on :80 and ANOTHER
# service already listens on :8080 (the panel's fallback port).
#
# apachectl configtest does not bind, so a 'Listen 8080' appended to ports.conf would
# pass it; the graceful reload that follows could not open the listener and can take
# the whole Apache (and its live sites) down. The installer must therefore refuse in
# preflight, before touching anything:
#   - exit non-zero with a message naming the port and its holder;
#   - the live site keeps answering, same Apache process (MainPID unchanged);
#   - ports.conf, sites-enabled and the module set are byte-for-byte as before;
#   - no panel vhost, no PHP 8.4, no manifest, no new Apache/PHP/DB package.
set -euo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCENARIO_DIR}/../lib.sh"

export SCENARIO="port-busy"

export PRESETUP='
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q >/dev/null 2>&1
    apt-get install -y --quiet apache2 curl python3 iproute2 >/dev/null 2>&1
    echo "LIVE_SITE_80" > /var/www/html/index.html
    systemctl enable --now apache2
    for _ in $(seq 1 15); do
        [ "$(curl -s --max-time 2 http://127.0.0.1:80/)" = "LIVE_SITE_80" ] && break
        sleep 1
    done
    [ "$(curl -s --max-time 2 http://127.0.0.1:80/)" = "LIVE_SITE_80" ] \
        || { echo "PRESETUP: live site not answering on :80" >&2; exit 1; }
    # the "other service" on :8080
    systemd-run --quiet --unit=port-blocker python3 -m http.server 8080 --bind 0.0.0.0
    for _ in $(seq 1 15); do
        ss -tlnH "( sport = :8080 )" | grep -q . && break
        sleep 1
    done
    ss -tlnH "( sport = :8080 )" | grep -q . \
        || { echo "PRESETUP: blocker did not bind :8080" >&2; exit 1; }
    systemctl show -p MainPID --value apache2 > /root/apache.pid.before
    cp /etc/apache2/ports.conf /root/ports.conf.before
    ls /etc/apache2/sites-enabled > /root/sites-enabled.before
    ls /etc/apache2/mods-enabled > /root/mods-enabled.before
    dpkg -l | awk "/^ii/{print \$2}" | sort > /root/pkgs.before
    echo "PRESETUP: apache2 live on :80 (pid $(cat /root/apache.pid.before)), python3 holds :8080"
'

export INSTALLER_ENV="LARANODE_UNATTENDED=1"
export EXPECT_INSTALLER_FAIL='Port 8080 is already in use by python3'

export POST_ASSERTS_CMD='
    [ "$(curl -s --max-time 5 http://127.0.0.1:80/)" = "LIVE_SITE_80" ] \
        || { echo "FAIL: live site on :80 changed or is gone" >&2; exit 1; }
    pid=$(systemctl show -p MainPID --value apache2)
    [ "$pid" = "$(cat /root/apache.pid.before)" ] \
        || { echo "FAIL: apache2 was restarted/reloaded away (MainPID $(cat /root/apache.pid.before) -> $pid)" >&2; exit 1; }
    echo "PASS: live site answers, apache2 MainPID unchanged ($pid)"
    cmp -s /etc/apache2/ports.conf /root/ports.conf.before \
        || { echo "FAIL: ports.conf changed" >&2; diff /root/ports.conf.before /etc/apache2/ports.conf >&2; exit 1; }
    [ "$(ls /etc/apache2/sites-enabled)" = "$(cat /root/sites-enabled.before)" ] \
        || { echo "FAIL: sites-enabled changed" >&2; exit 1; }
    [ "$(ls /etc/apache2/mods-enabled)" = "$(cat /root/mods-enabled.before)" ] \
        || { echo "FAIL: mods-enabled changed" >&2; exit 1; }
    [ ! -e /etc/apache2/sites-available/laranode.conf ] \
        || { echo "FAIL: panel vhost was written" >&2; exit 1; }
    echo "PASS: ports.conf, sites-enabled, mods-enabled and sites-available untouched"
    ss -tlnp "( sport = :8080 )" | grep -q python3 \
        || { echo "FAIL: the other :8080 service is gone" >&2; exit 1; }
    [ ! -e /etc/laranode/service-manifest.json ] \
        || { echo "FAIL: a manifest was written by a refused install" >&2; exit 1; }
    dpkg -l | awk "/^ii/{print \$2}" | sort > /root/pkgs.after
    new=$(comm -13 /root/pkgs.before /root/pkgs.after | tr "\n" " ")
    case "$new" in *php8*|*apache2*|*mysql*|*nodejs*|*certbot*) echo "FAIL: packages installed by a refused run: $new" >&2; exit 1;; esac
    echo "PASS: no PHP/Apache/DB packages installed by the refused run"
'

run_scenario
