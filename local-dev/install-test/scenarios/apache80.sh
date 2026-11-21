#!/usr/bin/env bash
# Scenario: a pre-existing Apache already serves a live site on :80.
#
# The installer must treat that Apache as someone else's production service:
#   - the live site keeps answering on :80 (same content, same Apache process:
#     MainPID unchanged = never restarted, only gracefully reloaded);
#   - its 'Listen 80' line is never deleted and 000-default stays enabled;
#   - mod_ssl is not switched on (that would open a brand-new :443);
#   - the panel gets its own vhost + 'Listen 8080' and answers there;
#   - the manifest lists apache2.service as managed:false.
set -euo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCENARIO_DIR}/../lib.sh"

export SCENARIO="apache80"

export PRESETUP='
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q >/dev/null 2>&1
    apt-get install -y --quiet apache2 >/dev/null 2>&1
    echo "LIVE_SITE_80" > /var/www/html/index.html
    rm -f /var/www/html/index.html.bak
    systemctl enable --now apache2
    for _ in $(seq 1 15); do
        [ "$(curl -s --max-time 2 http://127.0.0.1:80/)" = "LIVE_SITE_80" ] && break
        sleep 1
    done
    [ "$(curl -s --max-time 2 http://127.0.0.1:80/)" = "LIVE_SITE_80" ] \
        || { echo "PRESETUP: live site not answering on :80" >&2; exit 1; }
    systemctl show -p MainPID --value apache2 > /root/apache.pid.before
    cp /etc/apache2/ports.conf /root/ports.conf.before
    ls /etc/apache2/sites-enabled > /root/sites-enabled.before
    a2query -m ssl >/dev/null 2>&1 && echo yes > /root/ssl.before || echo no > /root/ssl.before
    echo "PRESETUP: apache2 live site on :80 (pid $(cat /root/apache.pid.before), ssl module: $(cat /root/ssl.before))"
'

# Defaults on purpose: preflight has to see Apache holding :80 and pick :8080.
export INSTALLER_ENV="LARANODE_UNATTENDED=1"
export EXPECT_PORT=8080
export EXPECT_ENGINE=mysql

export POST_ASSERTS_CMD='
    # live site still answers, unchanged
    [ "$(curl -s --max-time 5 http://127.0.0.1:80/)" = "LIVE_SITE_80" ] \
        || { echo "FAIL: live site on :80 changed or is gone" >&2; exit 1; }
    echo "PASS: live site still answers on :80"
    # same Apache process: never restarted
    pid=$(systemctl show -p MainPID --value apache2)
    [ "$pid" = "$(cat /root/apache.pid.before)" ] \
        || { echo "FAIL: apache2 was restarted (MainPID $(cat /root/apache.pid.before) -> $pid)" >&2; exit 1; }
    echo "PASS: apache2 MainPID unchanged ($pid) — reloaded, not restarted"
    # its own Listen 80 is intact, 000-default still enabled
    grep -qxE "Listen 80" /etc/apache2/ports.conf \
        || { echo "FAIL: the existing Apache Listen 80 was removed" >&2; cat /etc/apache2/ports.conf >&2; exit 1; }
    [ -e /etc/apache2/sites-enabled/000-default.conf ] \
        || { echo "FAIL: 000-default site was disabled" >&2; exit 1; }
    echo "PASS: Listen 80 and 000-default.conf intact"
    # panel added beside it, on its own port
    grep -qxE "Listen 8080" /etc/apache2/ports.conf \
        || { echo "FAIL: panel Listen 8080 not added" >&2; exit 1; }
    [ -e /etc/apache2/sites-enabled/laranode.conf ] \
        || { echo "FAIL: panel vhost not enabled" >&2; exit 1; }
    echo "PASS: panel vhost + Listen 8080 added beside it"
    # no new :443 (mod_ssl stays as it was)
    after=no; a2query -m ssl >/dev/null 2>&1 && after=yes
    [ "$after" = "$(cat /root/ssl.before)" ] \
        || { echo "FAIL: mod_ssl state changed ($(cat /root/ssl.before) -> $after)" >&2; exit 1; }
    ss -tlnH "( sport = :443 )" | grep -q . \
        && { echo "FAIL: something now listens on :443" >&2; ss -tlnH >&2; exit 1; }
    echo "PASS: no new :443 listener (mod_ssl state unchanged: $after)"
    # the existing PHP handler config is not globally switched to php8.4-fpm
    [ ! -e /etc/apache2/conf-enabled/php8.4-fpm.conf ] \
        || { echo "FAIL: global php8.4-fpm conf enabled on a pre-existing Apache" >&2; exit 1; }
    echo "PASS: no global php8.4-fpm handler (panel vhost carries its own)"
    # manifest
    grep -q "\"unit\":\"apache2.service\",\"managed\":false" /etc/laranode/service-manifest.json \
        || { echo "FAIL: manifest should list apache2.service as managed:false" >&2; cat /etc/laranode/service-manifest.json >&2; exit 1; }
    echo "PASS: manifest marks apache2.service managed:false"
'

run_scenario
