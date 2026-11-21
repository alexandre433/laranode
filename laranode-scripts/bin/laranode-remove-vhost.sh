#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Usage: laranode-remove-vhost.sh {domain}
# Disables and deletes a site's Apache vhost (and its -ssl twin). Replaces the raw
# `sudo a2dissite` / `sudo rm /etc/apache2/sites-available/*.conf` sudoers grants:
# a glob in sudoers matches '/' and spaces, so it could delete any .conf under /etc.
ln_argc 1 1 "$0 {domain}"
ln_domain "$1" DOMAIN

SITES=/etc/apache2/sites-available
found=0
for name in "$DOMAIN" "$DOMAIN-ssl"; do
    f="$SITES/$name.conf"
    if [ -e "$f" ] || [ -L "$f" ]; then
        found=1
        a2dissite "$name" >/dev/null 2>&1 || true
        rm -f -- "$f"
        echo "Removed vhost $name"
    fi
done
[ "$found" = 1 ] || { echo "No vhost for $DOMAIN" >&2; exit 1; }

systemctl reload apache2
