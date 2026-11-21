#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Usage: laranode-remove-php-fpm-pool-for-user.sh {system user} {php version}
ln_argc 2 2 "$0 {system user} {php version}"
# syntax only: the account may already be gone when its pools are cleaned up
ln_sysuser "$1" SYSTEM_USER syntax
ln_phpver "$2" PHP_VERSION

POOL_FILE="/etc/php/$PHP_VERSION/fpm/pool.d/$SYSTEM_USER.conf"
if [ -f "$POOL_FILE" ] && [ ! -L "$POOL_FILE" ]; then
    echo "Removing pool file..."
    rm -f -- "$POOL_FILE"
fi

# reload php{version}-fpm
echo "Reloading php$PHP_VERSION-fpm..."

(sleep 2 && systemctl restart "php${PHP_VERSION}-fpm") >/dev/null 2>&1 &
