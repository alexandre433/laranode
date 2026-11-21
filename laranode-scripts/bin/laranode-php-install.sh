#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Install a PHP-FPM version with common extensions
# Usage: laranode-php-install.sh {version}      Example: laranode-php-install.sh 8.4
ln_argc 1 1 "$0 {php version: example 8.4}"
ln_phpver "$1" PHP_VERSION

echo "Installing PHP $PHP_VERSION-FPM..."

# Update apt cache
apt-get update -qq

# Install PHP-FPM and common extensions
apt-get install -y \
  "php${PHP_VERSION}-fpm" \
  "php${PHP_VERSION}-cli" \
  "php${PHP_VERSION}-common" \
  "php${PHP_VERSION}-mysql" \
  "php${PHP_VERSION}-xml" \
  "php${PHP_VERSION}-curl" \
  "php${PHP_VERSION}-mbstring" \
  "php${PHP_VERSION}-zip" \
  "php${PHP_VERSION}-gd" \
  "php${PHP_VERSION}-bcmath" \
  "php${PHP_VERSION}-intl"

# Enable and start the service
systemctl enable "php${PHP_VERSION}-fpm"
systemctl start "php${PHP_VERSION}-fpm"

echo "PHP $PHP_VERSION installed successfully"
echo "PHP $PHP_VERSION-FPM service enabled and started"
