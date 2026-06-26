#!/bin/bash
set -euo pipefail

# Usage: laranode-restore-db.sh <cnfFile> <dumpFile> <dbName>
CNF_FILE="$1"
DUMP_FILE="$2"
DB_NAME="$3"

zcat "$DUMP_FILE" | mysql --defaults-extra-file="$CNF_FILE" "$DB_NAME"
