#!/usr/bin/env bash
# Unit test: template content assertions — runs on the HOST, no container needed.
# Asserts apache-panel.template has the required placeholders and both systemd unit
# templates pin ExecStart to /usr/bin/php8.4 (not the system-default /usr/bin/php).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEMPLATES="$REPO/laranode-scripts/templates"

pass=0
fail=0

check() {
    local desc="$1" rc="$2"
    if [ "$rc" = "0" ]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    fi
}

echo "=== template content assertions ==="

grep -q '__PORT__'   "$TEMPLATES/apache-panel.template" 2>/dev/null; check "__PORT__ placeholder in apache-panel.template"   $?
grep -q '__DOCROOT__' "$TEMPLATES/apache-panel.template" 2>/dev/null; check "__DOCROOT__ placeholder in apache-panel.template" $?
grep -q '/usr/bin/php8\.4' "$TEMPLATES/laranode-reverb.service"       2>/dev/null; check "/usr/bin/php8.4 in laranode-reverb.service"       $?
grep -q '/usr/bin/php8\.4' "$TEMPLATES/laranode-queue-worker.service" 2>/dev/null; check "/usr/bin/php8.4 in laranode-queue-worker.service" $?

echo ""
echo "Results: $pass passed, $fail failed."
[ "$fail" = 0 ] && exit 0 || exit 1
