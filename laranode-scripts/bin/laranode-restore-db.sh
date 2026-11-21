#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Usage: laranode-restore-db.sh <cnfFile> <dumpFile> <dbName> <dbUser>
# The dump is replayed AS www-data with the database's OWN account (never the server's
# root): a mysql client executes `\!` / `system` lines from its input, and a dump is
# attacker-supplied text.
ln_argc 4 4 "$0 <cnfFile> <dumpFile> <dbName> <dbUser>"
ln_tmpfile "$1" CNF_FILE cnf
ln_tmpfile "$2" DUMP_FILE restore
ln_ident "$3" DB_NAME
ln_dbuser "$4" DB_USER

ln_as "$LN_WEB_USER" bash -c \
    'set -o pipefail; zcat -- "$1" | mysql --defaults-extra-file="$2" --user="$3" -- "$4"' _ \
    "$DUMP_FILE" "$CNF_FILE" "$DB_USER" "$DB_NAME"
