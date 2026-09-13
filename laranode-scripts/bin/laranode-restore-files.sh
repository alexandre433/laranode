#!/bin/bash
set -euo pipefail

# Usage: laranode-restore-files.sh <tarFile> <destDir> <sysUser>
TAR_FILE="$1"
DEST_DIR="$2"
SYS_USER="$3"

# Reject any value that could be smuggled as a CLI flag to tar/chown.
for v in "$TAR_FILE" "$DEST_DIR" "$SYS_USER"; do
    case "$v" in -*) echo "Argument may not start with '-': $v" >&2; exit 1 ;; esac
done

# Destination must be a panel-managed website root — never an arbitrary host path
# (this script runs as root and chowns the result, so '/etc' would hand the
# directory to the site user). Same allowlist style as laranode-db-backup.sh.
[[ "$DEST_DIR" =~ ^/home/[A-Za-z0-9_]+_ln/domains/[A-Za-z0-9._-]+$ ]] \
    || { echo "Invalid destination directory: $DEST_DIR" >&2; exit 1; }
[[ "$DEST_DIR" != *..* ]] || { echo "Invalid destination directory: $DEST_DIR: path traversal not allowed" >&2; exit 1; }

# Archive must be a panel-created temp file (tempnam prefix 'laranode-restore-').
TMP_DIR="${TMPDIR:-/tmp}"
TMP_DIR="${TMP_DIR%/}"
case "$TAR_FILE" in
    "$TMP_DIR"/laranode-restore-*) ;;
    *) echo "Invalid archive path: $TAR_FILE" >&2; exit 1 ;;
esac
[[ "$TAR_FILE" != *..* ]] || { echo "Invalid archive path: $TAR_FILE: path traversal not allowed" >&2; exit 1; }

# System user must be a panel account (always '{username}_ln'); this also rejects root.
[[ "$SYS_USER" =~ ^[A-Za-z0-9_]+_ln$ ]] || { echo "Invalid system user: $SYS_USER" >&2; exit 1; }
[ "$SYS_USER" != "root" ] || { echo "Invalid system user: $SYS_USER" >&2; exit 1; }

mkdir -p -- "$DEST_DIR"
# Harden extraction against ownership/permission abuse and path traversal.
# GNU tar strips leading '/' and refuses members escaping the destination by default;
# these flags additionally prevent restoring archived ownership/permissions or
# clobbering existing directory metadata.
tar --no-same-owner --no-same-permissions --no-overwrite-dir \
    -xzf "$TAR_FILE" -C "$DEST_DIR"
chown -R -- "$SYS_USER:$SYS_USER" "$DEST_DIR"
