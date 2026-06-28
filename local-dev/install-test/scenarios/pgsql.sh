#!/usr/bin/env bash
# Scenario: Postgres-backed panel install.
# INSTALLER_ENV selects pgsql engine; EXPECT_ENGINE drives harness DB assertions.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

SCENARIO="pgsql"
PRESETUP=""
INSTALLER_ENV="LARANODE_DB_ENGINE=pgsql LARANODE_UNATTENDED=1"
EXPECT_PORT=80
EXPECT_ENGINE=pgsql

run_scenario
