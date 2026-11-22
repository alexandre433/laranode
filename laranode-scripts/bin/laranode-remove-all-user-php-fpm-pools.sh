#!/bin/bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # before ANY command runs: dirname below must not come from the caller's PATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Usage: laranode-remove-all-user-php-fpm-pools.sh {system user}
ln_argc 1 1 "$0 SYSTEM_USER"
# syntax only: account deletion removes the account first, then its pools
ln_sysuser "$1" SYSTEM_USER syntax

count=0
affected_versions=()

# Find and process pool configs (SYSTEM_USER is validated: no glob characters)
for file in /etc/php/*/fpm/pool.d/"$SYSTEM_USER".conf; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    [[ $file =~ ^/etc/php/([0-9]+\.[0-9]+)/fpm/pool\.d/ ]] || continue
    echo "Removing $file"
    rm -v -- "$file"
    affected_versions+=("${BASH_REMATCH[1]}")
    count=$((count + 1))
done

echo "Removed $count pool configuration(s)"

# Restart only affected PHP-FPM versions
for version in "${affected_versions[@]}"; do
    echo "Restarting php${version}-fpm"
    (sleep 2 && systemctl reload "php${version}-fpm") >/dev/null 2>&1 &
done

if [ "$count" -eq 0 ]; then
    echo "No pool configurations found for $SYSTEM_USER"
fi
