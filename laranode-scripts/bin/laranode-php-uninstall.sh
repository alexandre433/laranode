#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Uninstall a PHP-FPM version
# Usage: laranode-php-uninstall.sh {version}      Example: laranode-php-uninstall.sh 8.4
ln_argc 1 1 "$0 {php version: example 8.4}"
ln_phpver "$1" PHP_VERSION

echo "Uninstalling PHP $PHP_VERSION-FPM..."

systemctl stop "php${PHP_VERSION}-fpm"
systemctl disable "php${PHP_VERSION}-fpm"

# Remove PHP packages. The glob is expanded by apt (quoted here), never by the shell.
apt-get remove -y "php${PHP_VERSION}-*"
apt-get purge -y "php${PHP_VERSION}-*"
apt-get autoremove -y

echo "PHP $PHP_VERSION uninstalled successfully"
