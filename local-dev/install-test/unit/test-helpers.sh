#!/usr/bin/env bash
# local-dev/install-test/unit/test-helpers.sh
# Sources the installer (source-guard keeps main() silent) and asserts the
# three pure-bash helpers that later tasks rely on. No Docker, no root, ~1 s.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/../../../laranode-scripts/bin/laranode-installer.sh"

# Source the installer — source-guard must prevent main() from running
# shellcheck source=/dev/null
source "$INSTALLER"

PASS=0; FAIL=0
pass()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
flunk() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---- env_set ----------------------------------------------------------------
echo "=== env_set ==="

TMP=$(mktemp)
printf 'EXISTING=old\nOTHER=keep\n' > "$TMP"

env_set NEW_KEY myval "$TMP"
grep -q '^NEW_KEY="myval"$' "$TMP" \
  && pass "env_set: adds new key"      || flunk "env_set: adds new key"

env_set EXISTING replaced "$TMP"
grep -q '^EXISTING="replaced"$' "$TMP" \
  && pass "env_set: replaces existing" || flunk "env_set: replaces existing"
grep -q '^EXISTING=old$' "$TMP" \
  && flunk "env_set: stale value gone" || pass  "env_set: stale value gone"
grep -q '^OTHER=keep$' "$TMP" \
  && pass "env_set: untouched sibling" || flunk "env_set: untouched sibling"

rm -f "$TMP"

# ---- version_ge -------------------------------------------------------------
echo "=== version_ge ==="

version_ge 22.3 20  && pass "version_ge 22.3>=20 (true)"  || flunk "version_ge 22.3>=20 (true)"
version_ge 18.0 20  && flunk "version_ge 18.0>=20 (false)" || pass  "version_ge 18.0>=20 (false)"
version_ge 20.0 20  && pass "version_ge 20.0>=20 equal"    || flunk "version_ge 20.0>=20 equal"
version_ge 1.9 1.10 && flunk "version_ge 1.9>=1.10 (false)" || pass "version_ge 1.9>=1.10 (false)"

# ---- choose -----------------------------------------------------------------
echo "=== choose ==="

# env var beats default
MYVAR=from_env
result=$(choose MYVAR default_val "Enter val")
[ "$result" = "from_env" ] \
  && pass "choose: env var beats default" || flunk "choose: env var beats default"
unset MYVAR

# default used when no TTY (stdin is a pipe here)
result=$(echo "" | choose MYVAR default_val "Enter val")
[ "$result" = "default_val" ] \
  && pass "choose: default in non-tty"   || flunk "choose: default in non-tty"

# LARANODE_UNATTENDED=1 also forces default
LARANODE_UNATTENDED=1
result=$(choose MYVAR default_val "Enter val")
[ "$result" = "default_val" ] \
  && pass "choose: default when UNATTENDED=1" || flunk "choose: default when UNATTENDED=1"
unset LARANODE_UNATTENDED

# ---- summary ----------------------------------------------------------------
echo ""
echo "Results: passed=$PASS  failed=$FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL PASS" && exit 0
echo "FAILURES: $FAIL"
exit 1
