#!/bin/bash
set -euo pipefail

# Usage: laranode-restore-files.sh <tarFile> <destDir> <sysUser>
TAR_FILE="$1"
DEST_DIR="$2"
SYS_USER="$3"

mkdir -p "$DEST_DIR"
tar xzf "$TAR_FILE" -C "$DEST_DIR"
chown -R "$SYS_USER":"$SYS_USER" "$DEST_DIR"
