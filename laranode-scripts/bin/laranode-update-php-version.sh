#!/bin/bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # before ANY command runs: dirname below must not come from the caller's PATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Usage: laranode-update-php-version.sh {domain} {currentPhpVersion} {newPhpVersion}
# Rewrites the FPM socket version in the site's vhost (and its -ssl twin when present).
ln_argc 3 3 "$0 {domain} {currentPhpVersion} {newPhpVersion}"
ln_domain "$1" DOMAIN
ln_phpver "$2" CURRENT_PHP_VERSION
ln_phpver "$3" NEW_PHP_VERSION

SITES=/etc/apache2/sites-available
VHOST_FILE="$SITES/$DOMAIN.conf"
[ -f "$VHOST_FILE" ] && [ ! -L "$VHOST_FILE" ] || ln_die "no vhost for $DOMAIN"

echo "Currently on $CURRENT_PHP_VERSION"
echo "Switching to $NEW_PHP_VERSION"

for f in "$VHOST_FILE" "$SITES/$DOMAIN-ssl.conf"; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    content=$(<"$f")
    # only the FPM socket name carries the version: php-fpm-<ver>.<user>.sock
    content=${content//"php-fpm-$CURRENT_PHP_VERSION."/"php-fpm-$NEW_PHP_VERSION."}
    printf '%s\n' "$content" | ln_install_file "$f" 644
    echo "Updated $f"
done

echo "Reload apache"
systemctl reload apache2
