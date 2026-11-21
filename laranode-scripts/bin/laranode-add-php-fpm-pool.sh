#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Usage: laranode-add-php-fpm-pool.sh {system user} {php version} {template_file_path}
ln_argc 3 3 "$0 {system user} {php version} {template_file_path}"
ln_sysuser "$1" SYSTEM_USER
ln_phpver "$2" PHP_VERSION
ln_template "$3" TEMPLATE_FILE_PATH php-fpm-pool.template

POOL_DIR="/etc/php/$PHP_VERSION/fpm/pool.d"
[ -d "$POOL_DIR" ] && [ ! -L "$POOL_DIR" ] || ln_die "PHP $PHP_VERSION FPM is not installed"

ln_render "$TEMPLATE_FILE_PATH" user "$SYSTEM_USER" version "$PHP_VERSION" \
    | ln_install_file "$POOL_DIR/$SYSTEM_USER.conf" 644

# Sleep mode (optional): new pools must follow the on-demand setting too.
SLEEP_FPM_STATE=/etc/laranode/sleep/fpm.state
if grep -qx 'enabled=1' "$SLEEP_FPM_STATE" 2>/dev/null; then
    SLEEP_IDLE=$(sed -n 's/^idle_minutes=//p' "$SLEEP_FPM_STATE" | head -1)
    if [[ $SLEEP_IDLE =~ ^[1-9][0-9]{0,3}$ ]]; then
        bash "$LN_ROOT/bin/laranode-sleep.sh" fpm enable "$SLEEP_IDLE" || echo "WARNING: could not apply FPM sleep mode to the new pool" >&2
    fi
fi

# reload php{version}-fpm
echo "Reloading php$PHP_VERSION-fpm..."

# restart in bg to avoid current request issues in the browser
(sleep 2 && systemctl reload "php${PHP_VERSION}-fpm") >/dev/null 2>&1 &
