#!/usr/bin/env bash
# Scenario: a pre-existing php8.4-fpm already serves live pools.
#
# Installing the php8.4 extension packages runs their postinst, which try-restarts
# php8.4-fpm. On a host whose pool is someone else's production service that is an
# outage, so the installer holds back service starts (a marked policy-rc.d guard)
# while it installs PHP packages, and reloads the pool itself afterwards.
#
# The container image ships its own /usr/sbin/policy-rc.d (exit 101), which would mask
# the restart; real hosts do not have one. PRESETUP moves it aside so the scenario is
# red without the guard, and POST asserts:
#   - the pool is the same process (MainPID unchanged = never restarted);
#   - no policy-rc.d is left behind (the guard cleaned up after itself);
#   - the panel is up on its own port.
set -euo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCENARIO_DIR}/../lib.sh"

export SCENARIO="phpfpm-live"

export PRESETUP='
    export DEBIAN_FRONTEND=noninteractive
    rm -f /usr/sbin/policy-rc.d
    apt-get update -q >/dev/null 2>&1
    apt-get install -y -q software-properties-common curl >/dev/null 2>&1
    add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1
    apt-get update -q >/dev/null 2>&1
    apt-get install -y -q php8.4-fpm php8.4-cli >/dev/null 2>&1
    systemctl enable --now php8.4-fpm
    for _ in $(seq 1 15); do
        [ "$(systemctl is-active php8.4-fpm || true)" = active ] && break
        sleep 1
    done
    [ "$(systemctl is-active php8.4-fpm || true)" = active ] \
        || { echo "PRESETUP: php8.4-fpm not active" >&2; exit 1; }
    systemctl show -p MainPID --value php8.4-fpm > /root/fpm.pid.before
    [ "$(cat /root/fpm.pid.before)" != 0 ] || { echo "PRESETUP: no php8.4-fpm pid" >&2; exit 1; }
    [ ! -e /usr/sbin/policy-rc.d ] || { echo "PRESETUP: policy-rc.d still present" >&2; exit 1; }
    echo "PRESETUP: php8.4-fpm live (pid $(cat /root/fpm.pid.before)), no policy-rc.d on the host"
'

export INSTALLER_ENV="LARANODE_UNATTENDED=1"
export EXPECT_PORT=80
export EXPECT_ENGINE=mysql

export POST_ASSERTS_CMD='
    after=$(systemctl show -p MainPID --value php8.4-fpm)
    before=$(cat /root/fpm.pid.before)
    [ "$after" = "$before" ] \
        || { echo "FAIL: php8.4-fpm was restarted (pid $before -> $after)" >&2; exit 1; }
    echo "PASS: pre-existing php8.4-fpm never restarted (pid $after)"
    [ ! -e /usr/sbin/policy-rc.d ] \
        || { echo "FAIL: installer left a policy-rc.d behind" >&2; cat /usr/sbin/policy-rc.d >&2; exit 1; }
    echo "PASS: no policy-rc.d left behind"
    [ "$(systemctl is-active php8.4-fpm || true)" = active ] \
        || { echo "FAIL: php8.4-fpm not active after install" >&2; exit 1; }
    echo "PASS: php8.4-fpm active"
'

run_scenario
