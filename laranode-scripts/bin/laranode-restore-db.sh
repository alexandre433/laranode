#!/bin/bash
set -euo pipefail

# Usage: laranode-restore-db.sh <cnfFile> <dumpFile> <dbName> <dbUser>
CNF_FILE="$1"
DUMP_FILE="$2"
DB_NAME="$3"
DB_USER="$4"

# Reject any value that could be smuggled as a CLI flag to zcat/mysql.
for v in "$CNF_FILE" "$DUMP_FILE" "$DB_NAME" "$DB_USER"; do
    case "$v" in -*) echo "Argument may not start with '-': $v" >&2; exit 1 ;; esac
done

[[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || { echo "Invalid db name: $DB_NAME" >&2; exit 1; }
[[ "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || { echo "Invalid db user: $DB_USER" >&2; exit 1; }

zcat -- "$DUMP_FILE" | mysql --defaults-extra-file="$CNF_FILE" --user="$DB_USER" -- "$DB_NAME"
