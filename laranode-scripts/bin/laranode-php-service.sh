#!/bin/bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # before ANY command runs: dirname below must not come from the caller's PATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Manage PHP-FPM service (enable/disable/restart)
# Usage: laranode-php-service.sh {action} {version}      Example: laranode-php-service.sh enable 8.4
ln_argc 2 2 "$0 {action: enable|disable|restart|reload} {php version: example 8.4}"
ln_enum "$1" ACTION enable disable restart reload
ln_phpver "$2" PHP_VERSION

case $ACTION in
  enable)
    echo "Enabling PHP $PHP_VERSION-FPM service..."
    systemctl enable "php${PHP_VERSION}-fpm"
    systemctl start "php${PHP_VERSION}-fpm"
    ;;
  disable)
    echo "Disabling PHP $PHP_VERSION-FPM service..."
    systemctl stop "php${PHP_VERSION}-fpm"
    systemctl disable "php${PHP_VERSION}-fpm"
    ;;
  reload)
    # graceful reload: replaces workers, clears OPcache, keeps in-flight requests
    echo "Reloading PHP $PHP_VERSION-FPM service..."
    systemctl reload "php${PHP_VERSION}-fpm"
    ;;
  restart)
    echo "Restarting PHP $PHP_VERSION-FPM service..."
    systemctl restart "php${PHP_VERSION}-fpm"
    ;;
esac

echo "Action '$ACTION' completed successfully for PHP $PHP_VERSION-FPM"
