#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Usage: laranode-create-directory.sh {fullPathToCreate} {system_user}
# The path must live under /home/<user>/domains. Everything below runs AS the site user,
# so a symlink the tenant plants cannot make root create or chown anything elsewhere.
ln_argc 2 2 "$0 {fullPathToCreate} {system_user}"
ln_sysuser "$2" SYSTEM_USER
DIR_PATH=$1
BASE="/home/$SYSTEM_USER/domains"
[ "${#DIR_PATH}" -le 1024 ] && [[ $DIR_PATH =~ ^/[A-Za-z0-9._/-]+$ ]] || ln_die "invalid path"
[[ $DIR_PATH =~ (^|/)\.\.(/|$) ]] && ln_die "invalid path"
case "$DIR_PATH" in "$BASE"/*) : ;; *) ln_die "path must be inside $BASE" ;; esac
[ -d "$BASE" ] && [ ! -L "$BASE" ] || ln_die "$BASE is not a plain directory"

# every existing ancestor must be a real directory (not a symlink out of the tree)
probe=$DIR_PATH
while [ "$probe" != "$BASE" ]; do
    [ -L "$probe" ] && ln_die "refusing a symlink in the path"
    if [ -e "$probe" ]; then
        real=$(realpath -e -- "$probe") && case "$real" in "$BASE"/*) : ;; *) ln_die "path escapes $BASE" ;; esac
        break
    fi
    probe=$(dirname "$probe")
done

ln_as "$SYSTEM_USER" mkdir -p -- "$DIR_PATH"
# ownership first (coreutils chown -R walks with fd-relative fts and never follows links),
# then the site user, now the owner of everything, sets the modes.
chown -R -h -- "$SYSTEM_USER:$SYSTEM_USER" "$BASE"
ln_as "$SYSTEM_USER" find "$BASE" -xdev -type d -exec chmod 770 {} +
ln_as "$SYSTEM_USER" find "$BASE" -xdev -type f -exec chmod 660 {} +

echo "Directory created successfully."
