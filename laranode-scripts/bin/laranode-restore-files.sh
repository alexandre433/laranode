#!/bin/bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # before ANY command runs: dirname below must not come from the caller's PATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Usage: laranode-restore-files.sh <tarFile> <destDir> <sysUser>
# The archive is read AS www-data and extracted AS the site user: whatever the archive
# contains (absolute names, links, odd modes) can only land where that user may write.
ln_argc 3 3 "$0 <tarFile> <destDir> <sysUser>"
ln_sysuser "$3" SYS_USER
ln_tmpfile "$1" TAR_FILE restore
DEST_DIR=$2
BASE="/home/$SYS_USER/domains"
case "$DEST_DIR" in "$BASE/"*) : ;; *) ln_die "destination must be directly under $BASE" ;; esac
LEAF=${DEST_DIR#"$BASE/"}
[[ $LEAF =~ ^[A-Za-z0-9._-]{1,253}$ ]] && [ "$LEAF" != . ] && [ "$LEAF" != .. ] || ln_die "invalid destination"
[ -d "$BASE" ] && [ ! -L "$BASE" ] || ln_die "$BASE is not a plain directory"
[ ! -L "$DEST_DIR" ] || ln_die "destination is a symlink"

ln_as "$SYS_USER" mkdir -p -- "$DEST_DIR"
[ -d "$DEST_DIR" ] && [ ! -L "$DEST_DIR" ] || ln_die "destination is not a plain directory"

# GNU tar strips leading '/' and refuses members escaping the destination by default;
# the flags also stop archived ownership/permissions and directory metadata being applied.
ln_as "$LN_WEB_USER" cat -- "$TAR_FILE" \
    | ln_as "$SYS_USER" tar --no-same-owner --no-same-permissions --no-overwrite-dir -xzf - -C "$DEST_DIR"
