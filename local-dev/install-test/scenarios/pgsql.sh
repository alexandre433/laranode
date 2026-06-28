#!/usr/bin/env bash
# Scenario: Postgres engine — installer installs postgresql only (no mysql).
# Panel must migrate, seed, and serve on Postgres.
# EXPECTED: FAIL until Task 6 (LARANODE_DB_ENGINE=pgsql end-to-end) is implemented.
set -uo pipefail
SCENARIO=pgsql
PRESETUP=""
INSTALLER_ENV="LARANODE_UNATTENDED=1 LARANODE_DB_ENGINE=pgsql"
EXPECT_PORT=80
EXPECT_ENGINE=pgsql
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
run_scenario
