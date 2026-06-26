#!/bin/bash
set -euo pipefail

# Usage: laranode-backup-files.sh <siteRoot> <outFile> <sysUser>
SITE_ROOT="$1"
OUT_FILE="$2"
SYS_USER="$3"

tar czf "$OUT_FILE" -C "$SITE_ROOT" .
chown www-data:www-data "$OUT_FILE"
