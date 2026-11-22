#!/bin/bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # before ANY command runs: dirname below must not come from the caller's PATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# List all installed PHP-FPM versions with their systemctl status
# Output: JSON array of PHP versions with status
ln_argc 0 0 "$0"

# Get all installed php*-fpm packages
php_versions=$(dpkg -l | grep -E 'php[0-9]+\.[0-9]+-fpm' | awk '{print $2}' | sed 's/php\(.*\)-fpm/\1/' || true)

echo "["
first=true

for version in $php_versions; do
    [[ $version =~ ^[0-9]\.[0-9]{1,2}$ ]] || continue
    if systemctl is-active --quiet "php${version}-fpm"; then
        status="active"
    else
        status="inactive"
    fi

    if systemctl is-enabled --quiet "php${version}-fpm" 2>/dev/null; then
        enabled="true"
    else
        enabled="false"
    fi

    if [ "$first" = true ]; then
        first=false
    else
        echo ","
    fi

    echo -n "  {\"version\": \"$version\", \"status\": \"$status\", \"enabled\": $enabled}"
done

echo ""
echo "]"
