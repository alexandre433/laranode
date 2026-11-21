#!/usr/bin/env bash
# Scenario: a running, pre-existing Apache whose config on disk is already broken (an
# owner's half-finished edit that was never reloaded, so the live Apache is fine).
#
# The installer's `apachectl configtest` fails. The rollback must leave the owner's Apache
# exactly as it was found, and above all must not STOP it: the reload of our config was never
# reached, so there is nothing to put back and nothing to stop (the round-3 rollback stopped
# any Apache that was active). Asserted:
#   - the installer refuses with the configtest message;
#   - apache2 is the same process (MainPID unchanged), active, and the live site answers;
#   - ports.conf, sites-enabled, sites-available and mods-enabled are as before;
#   - no rollback journal and no policy-rc.d guard are left behind. The image ships its own
#     policy-rc.d; like a real host, PRESETUP removes it so the guard is real.
set -euo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCENARIO_DIR}/../lib.sh"

export SCENARIO="apache-badconf"

export PRESETUP='
    export DEBIAN_FRONTEND=noninteractive
    rm -f /usr/sbin/policy-rc.d
    apt-get update -q >/dev/null 2>&1
    apt-get install -y --quiet apache2 curl >/dev/null 2>&1
    echo "LIVE_SITE_80" > /var/www/html/index.html
    systemctl enable --now apache2
    for _ in $(seq 1 15); do
        [ "$(curl -s --max-time 2 http://127.0.0.1:80/)" = "LIVE_SITE_80" ] && break
        sleep 1
    done
    [ "$(curl -s --max-time 2 http://127.0.0.1:80/)" = "LIVE_SITE_80" ] \
        || { echo "PRESETUP: live site not answering on :80" >&2; exit 1; }
    systemctl show -p MainPID --value apache2 > /root/apache.pid.before
    # an unreloaded, broken edit of the owner: the running Apache does not know about it
    echo "LaranodeBogusDirective on" > /etc/apache2/conf-enabled/zz-owner-wip.conf
    if apachectl configtest >/dev/null 2>&1; then echo "PRESETUP: configtest should fail" >&2; exit 1; fi
    [ "$(curl -s --max-time 2 http://127.0.0.1:80/)" = "LIVE_SITE_80" ] \
        || { echo "PRESETUP: live site stopped answering" >&2; exit 1; }
    cp /etc/apache2/ports.conf /root/ports.conf.before
    ls /etc/apache2/sites-enabled   > /root/sites-enabled.before
    ls /etc/apache2/sites-available > /root/sites-available.before
    ls /etc/apache2/mods-enabled    > /root/mods-enabled.before
    [ ! -e /usr/sbin/policy-rc.d ] || { echo "PRESETUP: policy-rc.d still present" >&2; exit 1; }
    echo "PRESETUP: apache2 live (pid $(cat /root/apache.pid.before)) with an invalid config on disk"
'

export INSTALLER_ENV="LARANODE_UNATTENDED=1"
export EXPECT_INSTALLER_FAIL='Apache config test failed'

export POST_ASSERTS_CMD='
    [ "$(systemctl is-active apache2 || true)" = active ] \
        || { echo "FAIL: the failed install STOPPED the running Apache of the owner" >&2; exit 1; }
    pid=$(systemctl show -p MainPID --value apache2)
    [ "$pid" = "$(cat /root/apache.pid.before)" ] \
        || { echo "FAIL: apache2 was restarted (MainPID $(cat /root/apache.pid.before) -> $pid)" >&2; exit 1; }
    [ "$(curl -s --max-time 5 http://127.0.0.1:80/)" = "LIVE_SITE_80" ] \
        || { echo "FAIL: live site on :80 is gone" >&2; exit 1; }
    echo "PASS: apache2 still active, same process ($pid), live site answers"
    cmp -s /etc/apache2/ports.conf /root/ports.conf.before \
        || { echo "FAIL: ports.conf changed" >&2; diff /root/ports.conf.before /etc/apache2/ports.conf >&2; exit 1; }
    [ "$(ls /etc/apache2/sites-enabled)" = "$(cat /root/sites-enabled.before)" ] \
        || { echo "FAIL: sites-enabled changed" >&2; exit 1; }
    [ "$(ls /etc/apache2/sites-available)" = "$(cat /root/sites-available.before)" ] \
        || { echo "FAIL: sites-available changed (panel vhost left behind)" >&2; exit 1; }
    [ "$(ls /etc/apache2/mods-enabled)" = "$(cat /root/mods-enabled.before)" ] \
        || { echo "FAIL: mods-enabled changed (modules not disabled again)" >&2; exit 1; }
    echo "PASS: ports.conf, sites, modules exactly as before"
    [ ! -e /etc/laranode/apache-rollback ] \
        || { echo "FAIL: rollback journal left behind" >&2; ls /etc/laranode/apache-rollback >&2; exit 1; }
    [ ! -e /usr/sbin/policy-rc.d ] \
        || { echo "FAIL: installer left a policy-rc.d behind" >&2; exit 1; }
    echo "PASS: no rollback journal, no policy-rc.d left behind"
'

run_scenario
