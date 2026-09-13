#!/bin/bash
set -euo pipefail

# Usage: laranode-backup-files.sh <siteRoot> <outFile> <sysUser>
SITE_ROOT="$1"
OUT_FILE="$2"
SYS_USER="$3"

# Reject any value that could be smuggled as a CLI flag to tar/chown.
for v in "$SITE_ROOT" "$OUT_FILE" "$SYS_USER"; do
    case "$v" in -*) echo "Argument may not start with '-': $v" >&2; exit 1 ;; esac
done

# Site root must be a panel-managed website root — never an arbitrary host path
# (this script runs as root, so '/' would archive /etc/shadow). Same allowlist
# style as laranode-db-backup.sh.
[[ "$SITE_ROOT" =~ ^/home/[A-Za-z0-9_]+_ln/domains/[A-Za-z0-9._-]+$ ]] \
    || { echo "Invalid site root: $SITE_ROOT" >&2; exit 1; }
[[ "$SITE_ROOT" != *..* ]] || { echo "Invalid site root: $SITE_ROOT: path traversal not allowed" >&2; exit 1; }

# Archive must be a panel-created temp file (tempnam prefix 'laranode-backup-'),
# so a caller cannot redirect the archive onto an arbitrary host path.
TMP_DIR="${TMPDIR:-/tmp}"
TMP_DIR="${TMP_DIR%/}"
case "$OUT_FILE" in
    "$TMP_DIR"/laranode-backup-*) ;;
    *) echo "Invalid archive path: $OUT_FILE" >&2; exit 1 ;;
esac
[[ "$OUT_FILE" != *..* ]] || { echo "Invalid archive path: $OUT_FILE: path traversal not allowed" >&2; exit 1; }

# System user must be a panel account (always '{username}_ln'); this also rejects root.
[[ "$SYS_USER" =~ ^[A-Za-z0-9_]+_ln$ ]] || { echo "Invalid system user: $SYS_USER" >&2; exit 1; }
[ "$SYS_USER" != "root" ] || { echo "Invalid system user: $SYS_USER" >&2; exit 1; }

tar -czf "$OUT_FILE" -C "$SITE_ROOT" .
chown www-data:www-data -- "$OUT_FILE"
