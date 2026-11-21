#!/usr/bin/env bash
# Scenario: nginx listens on :80 on BOTH stacks (0.0.0.0:80 in /proc/net/tcp and [::]:80 in
# /proc/net/tcp6, the stock Ubuntu site), and the busy-port probe has to work without ss:
# LARANODE_PROBE_PROC=1 forces the /proc/net/tcp{,6} fallback (a host without iproute2).
#
# With a listener in BOTH tables the probe read :80 as FREE (SIGPIPE under pipefail made
# `inodes | grep -q .` fail), the installer picked :80 and Apache collided with nginx. It
# must see :80 busy and take :8080, leaving nginx alone:
#   - nginx is the same process (MainPID unchanged) and still answers on :80;
#   - the panel answers on :8080;
#   - cron (a new service, installed beside nginx) is running: the marked
#     policy-rc.d guard that holds service starts back must not keep THEM from starting;
#   - no policy-rc.d guard is left behind. The image ships its own policy-rc.d (it masks
#     every postinst start); like a real host, PRESETUP removes it so the guard is real.
set -euo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCENARIO_DIR}/../lib.sh"

export SCENARIO="nginx-dualstack"

export PRESETUP='
    export DEBIAN_FRONTEND=noninteractive
    rm -f /usr/sbin/policy-rc.d
    apt-get update -q >/dev/null 2>&1
    apt-get install -y --quiet nginx curl >/dev/null 2>&1
    systemctl enable --now nginx
    for _ in $(seq 1 15); do
        ss -tlnH "( sport = :80 )" | grep -q . && break
        sleep 1
    done
    # a listener in BOTH tables (state 0A = LISTEN, 0050 = port 80)
    awk "NR>1 && \$4==\"0A\" && \$2 ~ /:0050\$/" /proc/net/tcp  | grep -q . \
        || { echo "PRESETUP: no v4 listener on :80 in /proc/net/tcp" >&2; exit 1; }
    awk "NR>1 && \$4==\"0A\" && \$2 ~ /:0050\$/" /proc/net/tcp6 | grep -q . \
        || { echo "PRESETUP: no v6 listener on :80 in /proc/net/tcp6" >&2; exit 1; }
    systemctl show -p MainPID --value nginx > /root/nginx.pid.before
    [ "$(cat /root/nginx.pid.before)" != 0 ] || { echo "PRESETUP: no nginx pid" >&2; exit 1; }
    [ ! -e /usr/sbin/policy-rc.d ] || { echo "PRESETUP: policy-rc.d still present" >&2; exit 1; }
    echo "PRESETUP: nginx on :80 (v4 + v6, pid $(cat /root/nginx.pid.before)), no policy-rc.d on the host"
'

# LARANODE_HTTP_PORT deliberately omitted: preflight has to find :80 busy by itself.
export INSTALLER_ENV="LARANODE_UNATTENDED=1 LARANODE_PROBE_PROC=1"
export EXPECT_PORT=8080
export EXPECT_ENGINE=mysql

export POST_ASSERTS_CMD='
    [ "$(systemctl show -p MainPID --value nginx)" = "$(cat /root/nginx.pid.before)" ] \
        || { echo "FAIL: nginx was restarted (pid $(cat /root/nginx.pid.before) -> $(systemctl show -p MainPID --value nginx))" >&2; exit 1; }
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:80/ 2>/dev/null || echo 000)
    [ "$code" = 200 ] || { echo "FAIL: nginx on :80 answers $code" >&2; exit 1; }
    echo "PASS: nginx is the same process and still answers on :80"
    grep -qxE "Listen 8080" /etc/apache2/ports.conf \
        || { echo "FAIL: the panel did not take :8080" >&2; exit 1; }
    echo "PASS: panel on :8080 (the dual-stack :80 listener was seen)"
    for u in cron; do
        [ "$(systemctl is-active $u || true)" = active ] \
            || { echo "FAIL: $u is not running (held back by the start guard?)" >&2; exit 1; }
    done
    echo "PASS: cron (a new service) is running"
    [ ! -e /usr/sbin/policy-rc.d ] \
        || { echo "FAIL: installer left a policy-rc.d behind" >&2; cat /usr/sbin/policy-rc.d >&2; exit 1; }
    echo "PASS: no policy-rc.d left behind"
'

run_scenario
