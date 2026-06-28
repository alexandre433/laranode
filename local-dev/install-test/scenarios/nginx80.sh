#!/usr/bin/env bash
# Scenario: nginx already holds :80  → installer must auto-select :8080.
#
# Standard gate (via run_scenario + EXPECT_PORT=8080):
#   panel serves http://localhost:8080/login  →  200
#   all required systemd units active
#   admin login works
#
# Extra gate (POST_ASSERTS_CMD, in-container):
#   nginx STILL answers http://localhost:80/  →  2xx/3xx
set -euo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCENARIO_DIR}/../lib.sh"

export SCENARIO="nginx80"

# Install + start nginx BEFORE the installer.  The brief readiness loop ensures
# nginx has bound :80 before the installer's preflight port-check runs.
export PRESETUP='
    apt-get update -q >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y --quiet nginx >/dev/null 2>&1
    systemctl start nginx
    for _ in $(seq 1 15); do
        ss -tlnH "( sport = :80 )" | grep -q . && break
        sleep 1
    done
    ss -tlnH "( sport = :80 )" | grep -q . \
        || { echo "PRESETUP: nginx did not bind :80 in time" >&2; exit 1; }
    echo "PRESETUP: nginx is listening on :80"
'

# LARANODE_HTTP_PORT deliberately omitted — preflight must auto-detect :80 busy
# and set HTTP_PORT=8080 via the choose() logic.
export INSTALLER_ENV="LARANODE_UNATTENDED=1"

export EXPECT_PORT=8080
export EXPECT_ENGINE=mysql

# After the installer finishes, verify the pre-existing nginx is untouched.
export POST_ASSERTS_CMD='
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:80/ \
           2>/dev/null || echo 000)
    case "$code" in
        200|301|302)
            echo "PASS: nginx still answers :80  (HTTP $code)"
            ;;
        *)
            echo "FAIL: nginx on :80 is gone or broken after installer (got $code)" >&2
            exit 1
            ;;
    esac
'

run_scenario
