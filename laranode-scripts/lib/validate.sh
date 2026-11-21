# shellcheck shell=bash
# Shared guards for every script www-data may run through sudo.
#
# SOURCE this file (never execute it), first thing, from a root-owned script:
#     . "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
#
# Threat model: www-data (the PHP user) is compromisable and every argument it passes
# is attacker-controlled. So a script must (1) accept only values that match a strict
# allowlist, (2) never let a value reach a shell, sed, eval, a glob or an option
# position, and (3) never open a file that www-data (or a hosted site user) can swap
# for a symlink while running as root: it drops to that user for the open instead.
#
# Bash regex notes: `[[ $v =~ ^...$ ]]` matches the WHOLE value including newlines
# (unlike `echo "$v" | grep -E`, which tests line by line and let "ok\nevil" through).

export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022
shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2: '&' in a replacement means "the match"

LN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LN_ROOT="$(dirname "$LN_LIB_DIR")"       # /usr/local/lib/laranode  or  <panel>/laranode-scripts
LN_TPL_DIR="$LN_ROOT/templates"
LN_WEB_USER=www-data

ln_die() { echo "laranode: $*" >&2; exit 2; }

ln_need_root() { [ "$(id -u)" -eq 0 ] || ln_die "must run as root"; }

# ln_argc <min> <max> <usage>  (uses the caller's "$@" count via LN_ARGC)
ln_argc() {
    local n=$1 max=$2; shift 2
    if [ "${LN_ARGC:-0}" -lt "$n" ] || [ "${LN_ARGC:-0}" -gt "$max" ]; then
        echo "Usage: $*" >&2; exit 1
    fi
}

# --- value validators: ln_<kind> <value> <outvar> -----------------------------------

# System account of a hosted user: <name>_ln, an existing non-system account whose home
# is /home/<name>_ln. The panel's own user is never a valid target.
# mode "existing" (default) demands the account exists; "syntax" only checks the shape
# (account deletion removes pools AFTER the account is gone).
ln_sysuser() {
    local v=$1 out=$2 mode=${3:-existing} entry uid home
    [[ $v =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || ln_die "invalid user name"
    [[ $v == *_ln ]] || v+=_ln
    [ "${#v}" -le 32 ] || ln_die "user name too long"
    [[ $v =~ ^[a-z_][a-z0-9_-]*_ln$ ]] || ln_die "invalid user name"
    [ "$v" != laranode_ln ] || ln_die "refusing to act on the panel user"
    if [ "$mode" = existing ]; then
        entry=$(getent passwd "$v") || ln_die "no such user: $v"
        IFS=: read -r _ _ uid _ _ home _ <<<"$entry"
        [[ $uid =~ ^[0-9]+$ ]] && [ "$uid" -ge 1000 ] || ln_die "refusing a system account"
        [ "$home" = "/home/$v" ] || ln_die "unexpected home directory for $v"
    fi
    printf -v "$out" '%s' "$v"
}

# New hosted-user base name (account creation): what the panel itself accepts.
ln_newuser() {
    local v=$1 out=$2
    [[ $v =~ ^[A-Za-z0-9_-]{1,25}$ ]] || ln_die "invalid user name"
    [[ $v != -* ]] || ln_die "invalid user name"
    local s=${v}; [[ $s == *_ln ]] || s+=_ln
    [[ $s =~ ^[a-z_][a-z0-9_-]*_ln$ ]] || ln_die "invalid user name (lowercase letters, digits, _ and - only)"
    [ "$s" != laranode_ln ] || ln_die "reserved user name"
    printf -v "$out" '%s' "$s"
}

ln_domain() {
    local v=$1 out=$2
    local re='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
    [ "${#v}" -le 253 ] && [[ $v =~ $re ]] || ln_die "invalid domain"
    printf -v "$out" '%s' "$v"
}

ln_phpver() {
    [[ $1 =~ ^[0-9]\.[0-9]{1,2}$ ]] || ln_die "invalid PHP version"
    printf -v "$2" '%s' "$1"
}

# Document root as appended to the site root: "/" or "/public" or "/a/b.c" (no "..", no spaces).
ln_docroot() {
    local v=$1
    [ "${#v}" -le 255 ] && [[ $v =~ ^/[A-Za-z0-9._/-]*$ ]] || ln_die "invalid document root"
    [[ $v =~ (^|/)\.\.(/|$) ]] && ln_die "invalid document root"
    printf -v "$2" '%s' "$v"
}

ln_port() {   # <value> <outvar> [allow_zero]
    local v=$1
    if [ "${3:-}" = allow_zero ] && [ "$v" = 0 ]; then printf -v "$2" '%s' 0; return; fi
    [[ $v =~ ^[0-9]{4}$ ]] && [ "$v" -ge 9100 ] && [ "$v" -le 9499 ] || ln_die "port outside 9100-9499"
    printf -v "$2" '%s' "$v"
}

ln_enum() {   # <value> <outvar> <allowed...>
    local v=$1 out=$2 a; shift 2
    for a in "$@"; do [ "$v" = "$a" ] && { printf -v "$out" '%s' "$v"; return; }; done
    ln_die "invalid value (allowed: $*)"
}

ln_ident() {  # database / db user identifier
    [[ $1 =~ ^[A-Za-z0-9_]{1,64}$ ]] || ln_die "invalid identifier"
    printf -v "$2" '%s' "$1"
}

# A database account the panel may use: never an administrative one.
ln_dbuser() {
    local v=$1
    [[ $v =~ ^[A-Za-z0-9_]{1,32}$ ]] || ln_die "invalid database user"
    case "${v,,}" in
        root|mysql|mariadb|mariadb.sys|debian-sys-maint|postgres|sys|admin) ln_die "refusing an administrative database account" ;;
        mysql_*|pg_*) ln_die "refusing a reserved database account" ;;
    esac
    printf -v "$2" '%s' "$v"
}

# A secret that ends up on one line of a file or on chpasswd's stdin.
ln_secret() {
    local v=$1
    [ -n "$v" ] && [ "${#v}" -le 256 ] || ln_die "invalid password"
    [[ $v == *$'\n'* || $v == *$'\r'* ]] && ln_die "invalid password"
    printf -v "$2" '%s' "$v"
}

# --- paths ---------------------------------------------------------------------------

# Template file: must be exactly <templates>/<name> next to the script's own lib dir.
# Anything else (another directory, a symlink, a relative/odd spelling) is refused,
# so www-data cannot feed root a template it wrote.
ln_template() {   # <given path> <outvar> <allowed template names...>
    local given=$1 out=$2 real n; shift 2
    [[ $given == /* ]] || ln_die "template path must be absolute"
    real=$(realpath -e -- "$given" 2>/dev/null) || ln_die "template not found"
    for n in "$@"; do
        [ "$real" = "$LN_TPL_DIR/$n" ] && { printf -v "$out" '%s' "$real"; return; }
    done
    ln_die "template not allowed"
}

ln_template_dir() {   # <given dir> <outvar>
    local real
    [[ $1 == /* ]] || ln_die "template directory must be absolute"
    real=$(realpath -e -- "$1" 2>/dev/null) || ln_die "template directory not found"
    [ "$real" = "$LN_TPL_DIR" ] || ln_die "template directory not allowed"
    printf -v "$2" '%s' "$real"
}

# /tmp hand-over file created by the PHP side. <kind> picks the allowed name shape.
ln_tmpfile() {   # <path> <outvar> <kind: backup|dbbackup|restore|cnf|cron>
    local v=$1 re
    case "$3" in
        backup)   re='^/tmp/laranode-backup-[A-Za-z0-9._-]{1,80}$' ;;
        dbbackup) re='^/tmp/laranode-db-backup-[A-Za-z0-9._-]{1,80}$' ;;
        restore)  re='^/tmp/laranode-restore-[A-Za-z0-9._-]{1,80}$' ;;
        cnf)      re='^/tmp/laranode-(db|restore)-[A-Za-z0-9._-]{1,80}\.cnf$' ;;
        cron)     re='^/tmp/laranode_cron_[A-Za-z0-9._-]{1,80}$' ;;
        *) ln_die "internal: unknown tmp kind" ;;
    esac
    [[ $v =~ $re ]] || ln_die "temporary file name not allowed"
    printf -v "$2" '%s' "$v"
}

# Resolve a path to its real location and require it to live under <prefix> (a real dir).
# Used for site roots; the actual file work then runs as the site user (see ln_as).
ln_under() {   # <path> <prefix> <outvar>
    local real
    [[ $1 == /* ]] || ln_die "path must be absolute"
    real=$(realpath -e -- "$1" 2>/dev/null) || ln_die "path not found"
    case "$real" in "$2"/*) : ;; *) ln_die "path outside $2" ;; esac
    printf -v "$3" '%s' "$real"
}

# Site root of a hosted user: /home/<user>/domains/<domain>, resolved, and still there.
ln_siteroot() {   # <sysuser> <domain> <outvar>
    local real
    real=$(realpath -e -- "/home/$1/domains/$2" 2>/dev/null) || ln_die "site root not found"
    [ "$real" = "/home/$1/domains/$2" ] || ln_die "site root is not a plain directory"
    [ -d "$real" ] && [ ! -L "$real" ] || ln_die "site root is not a plain directory"
    printf -v "$3" '%s' "$real"
}

# Run a command as another account (drops root before touching user-controlled paths).
ln_as() {   # <user> <cmd...>
    local u=$1; shift
    runuser -u "$u" -- "$@"
}

# --- rendering / writing ---------------------------------------------------------------

# ln_render <template file> KEY VALUE [KEY VALUE ...]  -> rendered text on stdout.
# Plain parameter expansion: no sed, no eval, no command substitution of values.
ln_render() {
    local file=$1 content k; shift
    content=$(<"$file")
    while [ $# -ge 2 ]; do
        k=$1
        content=${content//"{$k}"/"$2"}
        shift 2
    done
    printf '%s\n' "$content"
}

# ln_install_file <dest> <mode>   (content on stdin). Atomic; refuses a symlinked dest.
ln_install_file() {
    local dest=$1 mode=$2 tmp
    [ ! -L "$dest" ] || ln_die "refusing to write through a symlink: $dest"
    tmp=$(mktemp "$dest.XXXXXX") || ln_die "cannot create temp file next to $dest"
    cat >"$tmp" && chmod "$mode" "$tmp" && mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; ln_die "cannot write $dest"; }
}

# Open <path> on fd 9, then prove the INODE we hold lives under <prefix>. Race-free
# against a tenant swapping a path component for a symlink between check and use: act
# on /proc/self/fd/9 afterwards, never on the path again.
ln_open9_under() {   # <path> <prefix>
    local real
    exec 9<&- 2>/dev/null || true
    # opening a FIFO blocks until a writer shows up: a tenant could park a root script for ever.
    # Only regular files and directories are ever opened here (a swap after this check can only
    # delay the script, not redirect it: the inode we hold is still proven below).
    { [ -f "$1" ] || [ -d "$1" ]; } && [ ! -p "$1" ] || ln_die "not a regular file or directory"
    if ! exec 9<"$1"; then ln_die "cannot open path"; fi
    real=$(readlink -f -- /proc/self/fd/9) || ln_die "cannot resolve path"
    case "$real" in "$2"/*) : ;; *) ln_die "path outside $2" ;; esac
}
