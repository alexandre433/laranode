#!/usr/bin/env bash
# laranode-postgres.sh — Privileged PostgreSQL management helper.
# Called via sudo from the PHP process (www-data). Never store credentials in argv.
#
# Usage:
#   laranode-postgres.sh create-db <name> <encoding> <locale>
#   laranode-postgres.sh create-user <user>           (password via stdin)
#   laranode-postgres.sh grant <user> <db>
#   laranode-postgres.sh revoke <user> <db>
#   laranode-postgres.sh drop-db <name>
#   laranode-postgres.sh drop-user <user>
#   laranode-postgres.sh update-user-password <user>  (password via stdin)

set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # before ANY command runs: dirname below must not come from the caller's PATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root

# ---- helpers ----------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }

# Validate identifier: only [a-zA-Z0-9_] allowed. (bash regex, not `echo | grep`:
# grep tests line by line and let "ok<newline>evil" through.)
assert_safe() {
    local val="$1"
    if ! [[ $val =~ ^[a-zA-Z0-9_]{1,63}$ ]]; then
        die "Unsafe identifier — only [a-zA-Z0-9_] (max 63) allowed."
    fi
}

# Never touch an administrative role or a template/system database, whatever the caller says.
assert_role() {
    local lc=${1,,}
    case "$lc" in postgres|pg_*|replicator|rdsadmin|root) die "Refusing reserved role." ;; esac
}
assert_dbname() {
    local lc=${1,,}
    case "$lc" in postgres|template0|template1) die "Refusing system database." ;; esac
}

# Validate an encoding name (e.g. UTF8, LATIN1, SQL_ASCII): only [a-zA-Z0-9_].
assert_encoding() {
    local val="$1"
    if ! [[ $val =~ ^[a-zA-Z0-9_]{1,32}$ ]]; then
        die "Unsafe encoding — only [a-zA-Z0-9_] allowed."
    fi
}

# Validate a locale (e.g. en_US.UTF-8, C, POSIX): only [a-zA-Z0-9_.@-].
assert_locale() {
    local val="$1"
    if ! [[ $val =~ ^[a-zA-Z0-9_.@-]{1,64}$ ]]; then
        die "Unsafe locale — only [a-zA-Z0-9_.@-] allowed."
    fi
}

# Generate a random dollar-quote tag (lowercase alpha, 8 chars) to avoid
# dollar-quoting breakout attacks.
random_tag() {
    head -c 64 /dev/urandom | base64 | tr -dc 'a-z' | head -c 8
}

# Read a password from stdin, never from argv; it must not be able to close its own quote.
read_password() {   # <outvar> <tagvar>
    local pw tag
    pw=$(head -c 1024)
    [ -n "$pw" ] || die "Password must not be empty."
    [ "${#pw}" -le 256 ] || die "Password too long."
    tag=$(random_tag)
    [ "${#tag}" -ge 6 ] || die "Could not generate a quoting tag."
    [[ $pw != *"\$${tag}\$"* ]] || die "Password rejected."
    printf -v "$1" '%s' "$pw"
    printf -v "$2" '%s' "$tag"
}

# Run SQL as the postgres superuser via stdin (never as a command argument).
run_as_postgres() {
    sudo -u postgres psql -v ON_ERROR_STOP=1 "$@"
}

# Convert a libc-style locale (e.g. "en_US.UTF-8") to an ICU locale tag
# (e.g. "en-US") for PostgreSQL 16+ on Ubuntu 24.04 which uses ICU by default.
# Returns the ICU tag via stdout. Falls back to "und" (undetermined) if not parseable.
libc_to_icu_locale() {
    local libc_locale="$1"
    # Strip encoding suffix (e.g. .UTF-8, .utf8)
    local lang_part="${libc_locale%%.*}"
    # Convert underscore to hyphen (en_US -> en-US)
    echo "${lang_part//_/-}"
}

# ---- actions ----------------------------------------------------------------

cmd_create_db() {
    local name="$1" encoding="${2:-UTF8}" locale="${3:-en_US.UTF-8}"
    assert_safe "$name"; assert_dbname "$name"
    assert_encoding "$encoding"
    assert_locale "$locale"

    # Detect whether we should use ICU (PostgreSQL 16+ on Ubuntu 24.04).
    # We try libc locale first; if PostgreSQL reports "invalid LC_COLLATE locale name"
    # we fall back to ICU locale provider.
    local icu_locale
    icu_locale=$(libc_to_icu_locale "$locale")

    # Try ICU locale provider first (works on PostgreSQL 16 + Ubuntu 24.04).
    # Fall back to libc locale if ICU fails.
    if run_as_postgres --dbname=postgres <<SQL 2>/dev/null; then
CREATE DATABASE "$name"
    ENCODING '$encoding'
    LOCALE_PROVIDER icu
    ICU_LOCALE '$icu_locale'
    TEMPLATE template0;
REVOKE CONNECT ON DATABASE "$name" FROM PUBLIC;
SQL
        return 0
    fi

    # Fallback: libc locale (older PostgreSQL or systems with full locale support)
    run_as_postgres --dbname=postgres <<SQL
CREATE DATABASE "$name"
    ENCODING '$encoding'
    LC_COLLATE '$locale'
    LC_CTYPE '$locale'
    TEMPLATE template0;
REVOKE CONNECT ON DATABASE "$name" FROM PUBLIC;
SQL
}

cmd_create_user() {
    local user="$1"
    assert_safe "$user"; assert_role "$user"

    local password tag
    read_password password tag

    # Pass SQL via stdin to psql — password embedded as dollar-quoted literal.
    run_as_postgres --dbname=postgres <<SQL
CREATE ROLE "$user" LOGIN;
ALTER ROLE "$user" PASSWORD \$${tag}\$${password}\$${tag}\$;
SQL
}

cmd_grant() {
    local user="$1" db="$2"
    assert_safe "$user"; assert_role "$user"
    assert_safe "$db"; assert_dbname "$db"

    run_as_postgres --dbname=postgres <<SQL
GRANT CONNECT ON DATABASE "$db" TO "$user";
GRANT ALL PRIVILEGES ON DATABASE "$db" TO "$user";
SQL
}

cmd_revoke() {
    local user="$1" db="$2"
    assert_safe "$user"; assert_role "$user"
    assert_safe "$db"; assert_dbname "$db"

    run_as_postgres --dbname=postgres <<SQL
REVOKE ALL PRIVILEGES ON DATABASE "$db" FROM "$user";
REVOKE CONNECT ON DATABASE "$db" FROM "$user";
SQL
}

cmd_drop_db() {
    local name="$1"
    assert_safe "$name"; assert_dbname "$name"

    run_as_postgres --dbname=postgres <<SQL
DROP DATABASE IF EXISTS "$name";
SQL
}

cmd_drop_user() {
    local user="$1"
    assert_safe "$user"; assert_role "$user"

    run_as_postgres --dbname=postgres <<SQL
DROP ROLE IF EXISTS "$user";
SQL
}

cmd_update_user_password() {
    local user="$1"
    assert_safe "$user"; assert_role "$user"

    local password tag
    read_password password tag

    run_as_postgres --dbname=postgres <<SQL
ALTER ROLE "$user" PASSWORD \$${tag}\$${password}\$${tag}\$;
SQL
}

# ---- dispatch ---------------------------------------------------------------

ACTION="${1:-}"
shift || true

case "$ACTION" in
    create-db)             cmd_create_db "$@" ;;
    create-user)           cmd_create_user "$@" ;;
    grant)                 cmd_grant "$@" ;;
    revoke)                cmd_revoke "$@" ;;
    drop-db)               cmd_drop_db "$@" ;;
    drop-user)             cmd_drop_user "$@" ;;
    update-user-password)  cmd_update_user_password "$@" ;;
    *)                     die "Unknown action. Valid: create-db create-user grant revoke drop-db drop-user update-user-password" ;;
esac
