#!/bin/bash
set -euo pipefail

# Usage: laranode-db-backup.sh <engine> <dbName> <dbUser> <cnfFile> <outFile>
ENGINE="$1"
DB_NAME="$2"
DB_USER="$3"
CNF_FILE="$4"
OUT_FILE="$5"

case "$ENGINE" in
    mysql)
        mysqldump --defaults-extra-file="$CNF_FILE" --user="$DB_USER" \
            --single-transaction --quick --lock-tables=false "$DB_NAME" | gzip > "$OUT_FILE"
        ;;
    *)
        echo "Unsupported engine: $ENGINE" >&2
        exit 1
        ;;
esac
