#!/usr/bin/env bash
# Scenario: vanilla Debian 13 (trixie). No PPA/sury, native php8.4, PostgreSQL 17
# (Debian ships no mysql-server, so the engine defaults to pgsql), panel on :80.
set -euo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCENARIO_DIR}/../lib.sh"

export SCENARIO="debian13"
export IMAGE="jrei/systemd-debian:13"
export PRESETUP=""
# LARANODE_DB_ENGINE deliberately omitted: Debian must default to pgsql.
export INSTALLER_ENV="LARANODE_UNATTENDED=1"
export EXPECT_PORT=80
export EXPECT_ENGINE=pgsql

export POST_ASSERTS_CMD='
    . /etc/os-release
    [ "$ID" = debian ] && [ "$VERSION_ID" = 13 ] || { echo "FAIL: not Debian 13 ($ID $VERSION_ID)" >&2; exit 1; }
    echo "PASS: running on Debian 13"
    if grep -rqsE "ondrej|sury" /etc/apt/sources.list /etc/apt/sources.list.d; then
        echo "FAIL: third-party PHP repo was added on Debian" >&2; exit 1
    fi
    echo "PASS: no ondrej/sury repo configured"
    v=$(dpkg-query -W -f="\${Version}" php8.4-cli)
    case "$v" in *deb13*) echo "PASS: php8.4-cli is Debian-native ($v)";; *) echo "FAIL: php8.4-cli version $v not from Debian" >&2; exit 1;; esac
    pg_lsclusters --no-header | awk "\$1==17 && \$2==\"main\" && \$4==\"online\"" | grep -q . \
        || { echo "FAIL: PostgreSQL 17/main not online" >&2; pg_lsclusters >&2; exit 1; }
    echo "PASS: PostgreSQL 17/main online"
    dpkg -s mysql-server >/dev/null 2>&1 && { echo "FAIL: mysql-server installed on Debian" >&2; exit 1; }
    grep -q "^DB_CONNECTION=.\?pgsql" /home/laranode_ln/panel/.env \
        || { echo "FAIL: panel .env is not pgsql" >&2; exit 1; }
    echo "PASS: panel uses pgsql"
'

run_scenario
