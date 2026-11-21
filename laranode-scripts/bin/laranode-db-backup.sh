#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Usage: laranode-db-backup.sh <engine> <dbName> <dbUser> <cnfFile> <outFile>
# Runs AS www-data with the database's own account; the dump file is created by www-data.
ln_argc 5 5 "$0 <engine> <dbName> <dbUser> <cnfFile> <outFile>"
ln_enum "$1" ENGINE mysql
ln_ident "$2" DB_NAME
ln_dbuser "$3" DB_USER
ln_tmpfile "$4" CNF_FILE cnf
ln_tmpfile "$5" OUT_FILE dbbackup

ln_as "$LN_WEB_USER" bash -c \
    'set -o pipefail; mysqldump --defaults-extra-file="$1" --user="$2" --single-transaction --quick --lock-tables=false -- "$3" | gzip > "$4"' _ \
    "$CNF_FILE" "$DB_USER" "$DB_NAME" "$OUT_FILE"
