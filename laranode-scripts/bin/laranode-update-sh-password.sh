#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Usage: laranode-update-sh-password.sh {systemUser} {password}
ln_argc 2 2 "$0 {systemUser} {password}"
ln_sysuser "$1" SYSTEM_USER
ln_secret "$2" NEW_PASSWORD

# One validated line on chpasswd's stdin (never a shell, never a newline).
printf '%s:%s\n' "$SYSTEM_USER" "$NEW_PASSWORD" | chpasswd

echo "Password for user '$SYSTEM_USER' has been updated successfully."
