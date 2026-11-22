#!/bin/bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # before ANY command runs: dirname below must not come from the caller's PATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Usage: laranode-file-permissions.sh {path relative to the home} {system user}
# Sets 660 (file) / 770 (dir) and the owner, as the site user, on a path inside the home.
ln_argc 2 2 "$0 {path} {system user}"
ln_sysuser "$2" SYSTEM_USER
REL=$1
[ "${#REL}" -le 1024 ] && [[ $REL =~ ^[A-Za-z0-9._/-]+$ ]] || ln_die "invalid path"
[[ $REL =~ (^|/)\.\.(/|$) ]] && ln_die "invalid path"
REL=$(printf '%s' "$REL" | tr -s '/')
REL=${REL#/}
HOME_DIR="/home/$SYSTEM_USER"
TARGET_PATH="$HOME_DIR/$REL"
[ ! -L "$TARGET_PATH" ] || ln_die "refusing a symlink"

echo "Setting permissions for $TARGET_PATH"

# Hold the inode, prove it is inside the home, then act on the held fd only: a tenant
# that swaps a path component for a symlink after this point changes nothing.
ln_open9_under "$TARGET_PATH" "$HOME_DIR"
if [ -f /proc/self/fd/9 ]; then
    echo "$REL is a file. Doing 660"
    chmod 660 /proc/self/fd/9
    chown "$SYSTEM_USER:$SYSTEM_USER" /proc/self/fd/9
elif [ -d /proc/self/fd/9 ]; then
    echo "$REL is a directory. Doing 770"
    chmod 770 /proc/self/fd/9
    chown "$SYSTEM_USER:$SYSTEM_USER" /proc/self/fd/9
else
    ln_die "not a regular file or directory"
fi
