#!/usr/bin/env bash
# Host-side unit tests for the installer.
# No container, no root, no network — runs in seconds.
#
# Usage: bash local-dev/install-test/unit/test-helpers.sh
#
# Task 1: file-existence + syntax checks only.
# Task 3 will extend with: source installer (via source-guard), then assert
# env_set add+replace, version_ge true/false, choose precedence (env>default
# when not a TTY).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
INSTALLER="$REPO_ROOT/laranode-scripts/bin/laranode-installer.sh"

PASS=0
FAIL=0

_ok() {
    echo "  PASS: $*"
    PASS=$((PASS + 1))
}

_fail() {
    echo "  FAIL: $*"
    FAIL=$((FAIL + 1))
}

echo "=== laranode installer unit tests ==="
echo ""

# T1 — installer file exists
if [ -f "$INSTALLER" ]; then
    _ok "installer file exists"
else
    _fail "installer file not found: $INSTALLER"
fi

# T2 — installer passes bash syntax check (bash -n)
# NOTE: we do NOT source the file here because the source-guard (BASH_SOURCE[0]
# check) is added in Task 3. Until then, sourcing would execute the full install.
if bash -n "$INSTALLER" 2>/dev/null; then
    _ok "installer bash -n syntax OK"
else
    _fail "installer failed bash -n syntax check"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]
