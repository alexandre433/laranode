#!/usr/bin/env bash
# Scenario: idempotent re-run — installer runs twice on the same container.
# Second run must not error under set -euo pipefail; admin + data preserved.
# EXPECTED: FAIL until Task 2 (set -euo pipefail + idempotency) is implemented.
#
# Strategy: PRESETUP does the FIRST full install; run_scenario then does the SECOND.
# Admin is seeded after the second run; assertions confirm the panel still works.
set -uo pipefail
SCENARIO=rerun
PRESETUP="LARANODE_UNATTENDED=1 bash /home/laranode_ln/panel/laranode-scripts/bin/laranode-installer.sh"
INSTALLER_ENV="LARANODE_UNATTENDED=1"
EXPECT_PORT=80
EXPECT_ENGINE=mysql
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
run_scenario
