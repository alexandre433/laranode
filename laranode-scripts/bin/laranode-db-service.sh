#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root

# Manage a database engine service (start / stop / restart)
# Usage: laranode-db-service.sh <action> <engine>
# Example: laranode-db-service.sh restart mysql

if [ $# -ne 2 ]; then
    echo "Usage: $0 {start|stop|restart} {mysql|mariadb|postgres}" >&2
    exit 1
fi

ACTION=$1
ENGINE=$2

# Leading-dash guard — prevents flag injection
if [[ "$ACTION" == -* ]]; then
    echo "ERROR: invalid action (leading dash not allowed): $ACTION" >&2
    exit 1
fi

if [[ "$ENGINE" == -* ]]; then
    echo "ERROR: invalid engine (leading dash not allowed): $ENGINE" >&2
    exit 1
fi

# Validate action
case "$ACTION" in
    start|stop|restart)
        ;;
    *)
        echo "ERROR: invalid action '$ACTION'. Allowed: start, stop, restart" >&2
        exit 1
        ;;
esac

# Validate engine and resolve service name.
# Keep in sync with EngineManager::$extraCandidates in app/Databases/EngineManager.php
case "$ENGINE" in
    mysql)
        SERVICE=mysql
        ;;
    mariadb)
        SERVICE=mariadb
        ;;
    postgres)
        SERVICE=postgresql
        ;;
    *)
        echo "ERROR: unknown engine '$ENGINE'. Allowed: mysql, mariadb, postgres" >&2
        exit 1
        ;;
esac

# Sleep mode owns the hosting database lifecycle (socket-activated, StopWhenUnneeded).
# A manual start/stop here would fight it, so refuse; use the Power page instead.
# Test overrides are honoured only outside sudo (same rule as laranode-sleep.sh).
SLEEP_STATE_DIR=/etc/laranode/sleep
if [ "${LARANODE_SLEEP_TEST:-}" = 1 ] && [ -z "${SUDO_UID:-}" ] && [ -n "${LARANODE_MANAGED_DIR:-}" ]; then
    SLEEP_STATE_DIR="$LARANODE_MANAGED_DIR/sleep"
fi
if [ "$ENGINE" != "postgres" ] && grep -qx 'enabled=1' "$SLEEP_STATE_DIR/hostdb.state" 2>/dev/null; then
    echo "ERROR: database sleep mode is on; it manages start/stop. Use the Power page to wake or sleep it." >&2
    exit 3
fi

echo "Running: systemctl $ACTION $ENGINE"

if [ "$ENGINE" = "postgres" ]; then
    # Try the generic alias first; fall back to versioned unit on Ubuntu.
    # Keep in sync with EngineManager::$extraCandidates in app/Databases/EngineManager.php
    if ! systemctl "$ACTION" "$SERVICE" 2>/dev/null; then
        if ! systemctl "$ACTION" "postgresql@16-main"; then
            echo "ERROR: systemctl $ACTION postgresql@16-main also failed" >&2
            exit 1
        fi
    fi
else
    systemctl "$ACTION" "$SERVICE"
fi

echo "Done: systemctl $ACTION $ENGINE"
