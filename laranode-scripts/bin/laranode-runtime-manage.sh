#!/bin/bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # before ANY command runs: dirname below must not come from the caller's PATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# laranode-runtime-manage.sh <action> <unit-name>
# Manages systemd lifecycle for a Laranode runtime unit.
# Called via sudo by SwitchRuntimeService / DeleteWebsiteService.
ln_argc 2 2 "$0 <action> <unit-name>"
ln_enum "$1" ACTION enable disable start stop restart status remove
UNIT=$2

# laranode-(frankenphp|swoole)-<domain>.service and nothing else
if [[ $UNIT =~ ^laranode-(frankenphp|swoole)-(.+)\.service$ ]]; then
    ln_domain "${BASH_REMATCH[2]}" _unit_domain
else
    ln_die "invalid unit name"
fi

if [ "$ACTION" = "remove" ]; then
    systemctl disable --now "$UNIT" 2>/dev/null || true
    rm -f -- "/etc/systemd/system/$UNIT"
    systemctl daemon-reload
    echo "Removed unit $UNIT"
    exit 0
fi

systemctl "$ACTION" "$UNIT"
