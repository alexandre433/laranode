#!/bin/bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # before ANY command runs: dirname below must not come from the caller's PATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Usage: laranode-update-sh-access.sh {systemUser} {shell_access = yes|no}
ln_argc 2 2 "$0 {systemUser} {shell_access = yes|no}"
ln_sysuser "$1" SYSTEM_USER
ln_enum "$2" SHELL_ACCESS yes no

# Function to grant SSH access
grant_ssh_access() {
    local user="$1" current_shell
    current_shell=$(getent passwd "$user" | cut -d: -f7)

    if [ "$current_shell" == "/bin/false" ] || [ "$current_shell" == "/usr/sbin/nologin" ]; then
        usermod -s /bin/bash -- "$user"
        echo "SSH access granted for user '$user'."
    else
        echo "User '$user' already has SSH access."
    fi
}

# Function to remove SSH access
remove_ssh_access() {
    usermod -s /bin/false -- "$1"
    echo "SSH access removed for user '$1'."
}

if [ "$SHELL_ACCESS" == "yes" ]; then
    grant_ssh_access "$SYSTEM_USER"
else
    remove_ssh_access "$SYSTEM_USER"
fi
