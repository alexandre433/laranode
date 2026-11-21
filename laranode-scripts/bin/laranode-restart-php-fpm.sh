#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Usage: laranode-restart-php-fpm.sh {php version: example 8.4}
ln_argc 1 1 "$0 {php version: example 8.4}"
ln_phpver "$1" PHP_VERSION

# reload php{version}-fpm
echo "Reloading php$PHP_VERSION-fpm..."

(sleep 2 && systemctl restart "php${PHP_VERSION}-fpm") >/dev/null 2>&1 &
