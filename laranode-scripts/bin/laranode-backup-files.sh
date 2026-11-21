#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Usage: laranode-backup-files.sh <siteRoot> <outFile> <sysUser>
# The archive is read AS the site user and written AS www-data: root never opens a path
# either of them controls (no symlink swap, no /etc/shadow into a www-data readable tar).
ln_argc 3 3 "$0 <siteRoot> <outFile> <sysUser>"
ln_sysuser "$3" SYS_USER
ln_tmpfile "$2" OUT_FILE backup
SITE_ROOT=$1
case "$SITE_ROOT" in "/home/$SYS_USER/domains/"*) : ;; *) ln_die "site root must be /home/$SYS_USER/domains/<domain>" ;; esac
ln_domain "${SITE_ROOT#"/home/$SYS_USER/domains/"}" DOMAIN
ln_siteroot "$SYS_USER" "$DOMAIN" SITE_ROOT

ln_as "$SYS_USER" tar -czf - -C "$SITE_ROOT" . | ln_as "$LN_WEB_USER" tee -- "$OUT_FILE" >/dev/null
