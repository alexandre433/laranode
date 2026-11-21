#!/bin/bash

# Check if at least two arguments are provided (system user and php version)
if [ $# -lt 3 ]; then
  echo "Usage: $0 {system user} {php version} {template_file_path}"
  exit 1
fi

SYSTEM_USER=$1
PHP_VERSION=$2
TEMPLATE_FILE_PATH=$3

# Automatically append _ln to $USERNAME if not already present
if echo "$SYSTEM_USER" | grep -qv '_ln$'; then
    SYSTEM_USER+="_ln"
fi

# read template file
TEMPLATE_FILE=$(cat "$TEMPLATE_FILE_PATH")

# replace {user} and {version} in template file
TEMPLATE_FILE=$(echo "$TEMPLATE_FILE" | sed "s#{user}#$SYSTEM_USER#g")
TEMPLATE_FILE=$(echo "$TEMPLATE_FILE" | sed "s#{version}#$PHP_VERSION#g")


# write template file to /etc/php/{version}/fpm/pool.d/pool-{systemUser}.conf
echo "$TEMPLATE_FILE" > "/etc/php/$PHP_VERSION/fpm/pool.d/$SYSTEM_USER.conf"

# Sleep mode (optional): new pools must follow the on-demand setting too.
SLEEP_FPM_STATE=/etc/laranode/sleep/fpm.state
if grep -qx 'enabled=1' "$SLEEP_FPM_STATE" 2>/dev/null; then
    SLEEP_IDLE=$(sed -n 's/^idle_minutes=//p' "$SLEEP_FPM_STATE" | head -1)
    if [[ $SLEEP_IDLE =~ ^[1-9][0-9]{0,3}$ ]]; then
        bash "$(dirname "$0")/laranode-sleep.sh" fpm enable "$SLEEP_IDLE" || echo "WARNING: could not apply FPM sleep mode to the new pool" >&2
    fi
fi

# Get the PID of PHP-FPM based on PHP version
PID_FILE="/var/run/php/php${PHP_VERSION}-fpm.pid"

# reload php{version}-fpm
echo "Reloading php$PHP_VERSION-fpm..."

# restart in bg to avoid current request issues in the browser
(sleep 2 && systemctl reload "php${PHP_VERSION}-fpm") >/dev/null 2>&1 &
