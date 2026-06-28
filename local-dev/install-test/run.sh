#!/usr/bin/env bash
# Scenario dispatcher for the clean-room install test.
#
# Usage:
#   bash local-dev/install-test/run.sh              # baseline (default)
#   bash local-dev/install-test/run.sh baseline     # explicit
#   bash local-dev/install-test/run.sh pgsql        # named scenario
#   bash local-dev/install-test/run.sh matrix       # all 5, fail-fast off, summary
#
# Per-run options (env):
#   KEEP=1   keep container after run for inspection
set -uo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/scenarios" && pwd)"
ARG="${1:-baseline}"

ALL_SCENARIOS=(baseline nginx80 mysql-rootpw pgsql rerun)

if [ "$ARG" = matrix ]; then
    declare -a pass=()
    declare -a fail=()
    for s in "${ALL_SCENARIOS[@]}"; do
        echo ""
        echo "====== Running scenario: $s ======"
        if bash "$SCENARIO_DIR/${s}.sh"; then
            pass+=("$s")
        else
            fail+=("$s")
        fi
    done
    echo ""
    echo "===== Matrix summary ====="
    if [ "${#pass[@]}" -gt 0 ]; then
        for s in "${pass[@]}"; do echo "  PASS: $s"; done
    fi
    if [ "${#fail[@]}" -gt 0 ]; then
        for s in "${fail[@]}"; do echo "  FAIL: $s"; done
    fi
    [ "${#fail[@]}" -eq 0 ]
else
    scenario_file="$SCENARIO_DIR/${ARG}.sh"
    if [ ! -f "$scenario_file" ]; then
        echo "ERROR: unknown scenario '${ARG}'. Available: ${ALL_SCENARIOS[*]}" >&2
        exit 1
    fi
    bash "$scenario_file"
fi
