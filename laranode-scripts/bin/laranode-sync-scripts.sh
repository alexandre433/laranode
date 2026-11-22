#!/bin/bash
#
# laranode-sync-scripts.sh — install the privileged scripts as a ROOT-OWNED copy.
#
# Why: www-data may run the scripts in /usr/local/lib/laranode/bin through sudo, so
# nothing that www-data (or the laranode_ln panel account) can write may ever be on
# that path. The panel's git checkout is writable by laranode_ln by design (that is how
# the panel is updated), so the scripts are COPIED out of it into a tree owned by root.
#
# Run by an administrator, as root, NEVER through sudo by the panel and never granted
# in sudoers:
#
#   sudo -u laranode_ln git -C /home/laranode_ln/panel pull     # update the panel (never git as root)
#   sudo /usr/local/lib/laranode/bin/laranode-sync-scripts.sh   # review the diff, then publish it
#
# Usage: laranode-sync-scripts.sh [panel_path]     (default /home/laranode_ln/panel)
#
# The copy is built in a root-only staging directory, every shell file is syntax-checked,
# then swapped in with a rename. Sudoers drop-ins that are already installed (and the
# base set) are refreshed from the copy after `visudo -c`. A failure leaves the previous
# copy and sudoers untouched.
set -euo pipefail
umask 022
export LC_ALL=C PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

DEST=${LARANODE_LIB_DEST:-/usr/local/lib/laranode}
SUDOERS_DIR=${LARANODE_SUDOERS_DIR:-/etc/sudoers.d}
PANEL=${1:-${PANEL_PATH:-/home/laranode_ln/panel}}
SRC="$PANEL/laranode-scripts"
BASE_DROPINS="laranode-panel laranode-cron laranode-runtimes laranode-ufw"
PANEL_USER=laranode_ln
HOST_CONF=${LARANODE_HOST_CONF:-/etc/laranode/host.conf}
PVE_DIR=${LARANODE_PVE_DIR:-/etc/pve}

die() { echo "laranode-sync-scripts: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
id -u "$PANEL_USER" >/dev/null 2>&1 || die "no $PANEL_USER account to read the checkout as"

# ---- which account the sudoers grants go to (host.conf, written by the installer) ----------
# The drop-ins in the checkout name www-data. On a Proxmox host www-data is pveproxy's user:
# granting it sudo hands the Proxmox UI root. There the installer records web_user=laranode_web
# (the panel's own Apache/PHP-FPM user) and the STAGED, allowlisted drop-ins are rendered for it.
# ufw=0: the laranode-ufw drop-in is not installed (and one already installed is removed).
WEB_USER=www-data; UFW=1
if [ -e "$HOST_CONF" ] || [ -L "$HOST_CONF" ]; then
    { [ ! -L "$HOST_CONF" ] && [ -f "$HOST_CONF" ] && [ "$(stat -c %u "$HOST_CONF")" = 0 ] \
        && [ $(( 0$(stat -c %a "$HOST_CONF") & 022 )) -eq 0 ]; } \
        || die "$HOST_CONF must be a regular root-owned file, not group/world writable"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            web_user=www-data|web_user=laranode_web) WEB_USER=${line#web_user=} ;;
            ufw=0|ufw=1) UFW=${line#ufw=} ;;
            ''|'#'*) : ;;
            *) die "unexpected line in $HOST_CONF: $line" ;;
        esac
    done < "$HOST_CONF"
fi
if [ -d "$PVE_DIR" ] || command -v pveversion >/dev/null 2>&1; then
    [ "$WEB_USER" != www-data ] \
        || die "Proxmox host: refusing to grant www-data (pveproxy's user) sudo. Run the installer: it sets web_user=laranode_web in $HOST_CONF"
fi
[ "$WEB_USER" = www-data ] || id -u "$WEB_USER" >/dev/null 2>&1 || die "panel web user $WEB_USER does not exist"
[ -d "$SRC/bin" ] && [ -d "$SRC/lib" ] && [ -d "$SRC/templates" ] && [ -d "$SRC/etc/sudoers.d" ] \
    || die "no laranode-scripts tree at $SRC"
# the destination's parent must be root-owned and not writable by others
parent=$(dirname "$DEST")
[ "$(stat -c '%u' "$parent")" = 0 ] && [ $(( 0$(stat -c '%a' "$parent") & 022 )) -eq 0 ] \
    || die "$parent must be owned by root and not group/world writable"
# a link inside the source tree is refused outright (the READ below is made as $PANEL_USER, so a
# link swapped in after this scan still cannot hand root anything: see read_src)
if find "$SRC/bin" "$SRC/lib" "$SRC/templates" "$SRC/etc" -type l | grep -q .; then
    die "symlinks inside $SRC are not allowed"
fi

STAGE=$(mktemp -d "$parent/.laranode-stage.XXXXXX")
trap 'rm -rf -- "$STAGE"' EXIT
chmod 755 "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/templates" "$STAGE/etc/sudoers.d"

# ---- reading the checkout --------------------------------------------------------------
# The checkout is writable by $PANEL_USER, which a compromised web process can reach. Root must
# therefore never open a path inside it: a parent directory ($SRC/templates, $SRC itself, $PANEL)
# swapped for a link to /etc after any check would make a root cp publish /etc/shadow, world
# readable, into the script directory (a check on the LAST path component cannot see that).
# So every directory listing and every file read is made AS $PANEL_USER: whatever it can read
# is already its own, anything else fails with "permission denied" and the sync refuses.
# Root only ever WRITES, to fixed names it validated, in a staging directory nobody else can
# reach, and then judges (bash -n, sudoers allowlist, visudo -c) and publishes that copy.
run_as_panel() { timeout 30 runuser -u "$PANEL_USER" -- "$@"; }

# list_src <dir> <find -name glob>: the plain names directly under <dir>, NUL-separated, into SRC_NAMES
list_src() {
    SRC_NAMES=()
    local name list="$STAGE/.list"
    run_as_panel find "$1" -mindepth 1 -maxdepth 1 -name "$2" -printf '%f\0' > "$list" 2>/dev/null \
        || die "cannot list $1 as $PANEL_USER"
    while IFS= read -r -d '' name; do SRC_NAMES+=("$name"); done < "$list"
    rm -f -- "$list"
}
# read_src <src> <dst> <mode>: copy a regular file the panel account can read (at most 2 MiB) into
# the staging directory as a root-owned file. The destination name was validated by the caller.
read_src() {
    run_as_panel test -f "$1" || die "${1##*/} is not a regular file readable by $PANEL_USER"
    run_as_panel cat -- "$1" | head -c 2097152 > "$2" || die "cannot read ${1##*/} as $PANEL_USER (or it is over 2 MiB)"
    [ -f "$2" ] && [ ! -L "$2" ] || die "${1##*/} did not stage as a regular file"
    chown root:root -- "$2"; chmod "$3" -- "$2"
}
safe_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# ---- bin: every laranode-*.sh, except the installer (run by hand from the tree) -------
n=0
list_src "$SRC/bin" 'laranode-*.sh'
for b in "${SRC_NAMES[@]}"; do
    [ "$b" = laranode-installer.sh ] && continue
    [[ $b =~ ^laranode-[a-z0-9-]+\.sh$ ]] || die "unexpected script name: $b"
    read_src "$SRC/bin/$b" "$STAGE/bin/$b" 755
    bash -n "$STAGE/bin/$b" || die "syntax error in $b"
    n=$((n + 1))
done
[ "$n" -gt 0 ] || die "no scripts found in $SRC/bin (or $PANEL_USER cannot read them)"
# the postgres sudoers snippet is data, kept for the pgsql branch
if run_as_panel test -f "$SRC/bin/laranode-postgres-sudoers"; then
    read_src "$SRC/bin/laranode-postgres-sudoers" "$STAGE/bin/laranode-postgres-sudoers" 644
fi

list_src "$SRC/lib" '*.sh'
for b in "${SRC_NAMES[@]}"; do
    safe_name "$b" || die "unexpected lib file name: $b"
    read_src "$SRC/lib/$b" "$STAGE/lib/$b" 644
    bash -n "$STAGE/lib/$b" || die "syntax error in lib/$b"
done
list_src "$SRC/templates" '*'
for b in "${SRC_NAMES[@]}"; do
    safe_name "$b" || die "unexpected template file name: $b"
    run_as_panel test -f "$SRC/templates/$b" || continue
    read_src "$SRC/templates/$b" "$STAGE/templates/$b" 644
done
# ---- the four templates the INSTALLER (root) installs verbatim: exact-line allowlist ------
# Root installs these into systemd (/etc/systemd/system), cron.d and Apache, whose managers parse
# them with root's authority: a unit that says `User=root` / `ExecStartPre=/tmp/x`, a cron line
# for root, or an Apache `LoadModule`/`Include` in a template laranode_ln edited in the checkout
# would be root code execution at the next install. So each staged copy must consist ONLY of lines
# the shipped file has (as anchored patterns); anything else refuses the whole sync.
tpl_ok() {   # <name> <regex>...: every line of the staged templates/<name> matches one regex
    local name=$1 f="$STAGE/templates/$1" line re hit
    shift
    [ -f "$f" ] || { echo "laranode-sync-scripts: template $name is missing" >&2; return 1; }
    [ "$(tr -d '\0\r' <"$f" | wc -c)" -eq "$(wc -c <"$f")" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        hit=0
        for re in "$@"; do [[ $line =~ $re ]] && { hit=1; break; }; done
        [ "$hit" = 1 ] || { echo "laranode-sync-scripts: ${f##*/}: line not allowed: $line" >&2; return 1; }
    done <"$f"
}
UNIT_COMMON=('^$' '^#[^\\]*$' '^\[(Unit|Service|Install)\]$' '^Description=[A-Za-z0-9 ._-]+$'
    '^(After|Wants)=network-online\.target$' '^User=laranode_ln$' '^Group=laranode_ln$'
    '^Restart=on-failure$' '^RestartSec=5s$' '^WantedBy=multi-user\.target$')
tpl_ok laranode-queue-worker.service "${UNIT_COMMON[@]}" \
    '^ExecStart=/usr/bin/php8\.4 /home/laranode_ln/panel/artisan queue:work$' \
    || die "templates/laranode-queue-worker.service grants more than the shipped unit"
tpl_ok laranode-reverb.service "${UNIT_COMMON[@]}" \
    '^ExecStart=/usr/bin/php8\.4 /home/laranode_ln/panel/artisan reverb:start$' \
    || die "templates/laranode-reverb.service grants more than the shipped unit"
tpl_ok laranode-schedule.cron '^$' '^#[^\\]*$' \
    '^\* \* \* \* \* __PANEL_USER__ __PHP__ __PANEL_PATH__/artisan schedule:run >> /dev/null 2>&1$' \
    || die "templates/laranode-schedule.cron runs more than the scheduler"
tpl_ok apache-panel.template '^$' \
    '^<VirtualHost \*:__PORT__>$' '^</VirtualHost>$' \
    '^    ServerAdmin webmaster@localhost$' '^    DocumentRoot __DOCROOT__$' \
    '^    <Directory __DOCROOT__>$' '^    </Directory>$' \
    '^        Options FollowSymLinks$' '^        AllowOverride All$' '^        Require all granted$' \
    '^    ErrorLog \$\{APACHE_LOG_DIR\}/laranode-error\.log$' \
    '^    CustomLog \$\{APACHE_LOG_DIR\}/laranode-access\.log combined$' \
    || die "templates/apache-panel.template holds a directive the shipped vhost does not"

# ---- sudoers drop-ins: a strict ALLOWLIST, checked on the STAGED copy -------------------
# The drop-in comes from the panel checkout (writable by laranode_ln). Copy it first into the
# root-only staging dir, then judge the copy: what is checked is exactly what is published,
# so the source cannot change between the check and the install. Every line must be one of
#   * blank, or a plain comment (never #include / #includedir / @include*, never ending in \)
#   * Defaults!<DEST>/bin/laranode-<name>.sh !requiretty
#   * www-data ALL=(ALL|www-data) NOPASSWD: <DEST>/bin/laranode-<name>.sh   (optionally followed by "")
# Anything else (ALL, a comma list, another user or tag, a wildcard, a path outside DEST/bin,
# an alias, another Defaults, a continuation line, CR/NUL) refuses the whole sync.
sudoers_line_ok() {   # <line>
    local l=$1 p rest
    [[ $l == *$'\r'* || $l == *'\' ]] && return 1
    [[ -z ${l//[[:space:]]/} ]] && return 0
    if [[ $l == '#'* ]]; then
        [[ $l =~ ^#[[:space:]]*(include|includedir)([[:space:]]|$) ]] && return 1
        return 0
    fi
    p="Defaults!$DEST/bin/"
    if [[ $l == "$p"* ]]; then
        rest=${l#"$p"}
        [[ $rest =~ ^laranode-[a-z0-9-]+\.sh\ \!requiretty$ ]] && return 0
        return 1
    fi
    for p in 'www-data ALL=(ALL) NOPASSWD: ' 'www-data ALL=(www-data) NOPASSWD: '; do
        p="$p$DEST/bin/"
        if [[ $l == "$p"* ]]; then
            rest=${l#"$p"}
            [[ $rest =~ ^laranode-[a-z0-9-]+\.sh(\ \"\")?$ ]] && return 0
            return 1
        fi
    done
    return 1
}
# render_for_web_user <staged file>: AFTER the allowlist check, the user column of each grant
# (exactly `www-data ALL=(ALL)` / `www-data ALL=(www-data)`, nothing else can be there) is
# rewritten for WEB_USER. A fixed substitution of two fixed names: no checkout text reaches sed.
render_for_web_user() {
    local f=$1
    [ "$WEB_USER" != www-data ] || return 0
    sed -i -e "s/^www-data ALL=(ALL) NOPASSWD: /$WEB_USER ALL=(ALL) NOPASSWD: /" \
           -e "s/^www-data ALL=(www-data) NOPASSWD: /$WEB_USER ALL=($WEB_USER) NOPASSWD: /" -- "$f"
    ! grep -v '^#' -- "$f" | grep -q 'www-data' || die "${f##*/}: www-data still named after rendering for $WEB_USER"
}
sudoers_file_ok() {   # <file>
    local f=$1 line n=0
    # NUL bytes cannot live in a bash variable: compare byte counts
    [ "$(tr -d '\0' <"$f" | wc -c)" -eq "$(wc -c <"$f")" ] || return 1
    # the last line must end in a newline (read would otherwise drop the check on it)
    [ ! -s "$f" ] || [ -z "$(tail -c1 "$f")" ] || return 1
    while IFS= read -r line; do
        n=$((n + 1))
        sudoers_line_ok "$line" || { echo "laranode-sync-scripts: line $n of ${f##*/} is not allowed: $line" >&2; return 1; }
    done <"$f"
}

list_src "$SRC/etc/sudoers.d" '*'
for d in "${SRC_NAMES[@]}"; do
    run_as_panel test -f "$SRC/etc/sudoers.d/$d" || continue
    [[ $d =~ ^laranode-[a-z0-9-]+$ ]] || die "unexpected sudoers drop-in name: $d"
    read_src "$SRC/etc/sudoers.d/$d" "$STAGE/etc/sudoers.d/$d" 644
    visudo -c -f "$STAGE/etc/sudoers.d/$d" >/dev/null || die "sudoers drop-in $d failed syntax check"
    sudoers_file_ok "$STAGE/etc/sudoers.d/$d" || die "sudoers drop-in $d grants more than a laranode script inside $DEST/bin"
    render_for_web_user "$STAGE/etc/sudoers.d/$d"
    visudo -c -f "$STAGE/etc/sudoers.d/$d" >/dev/null || die "sudoers drop-in $d failed syntax check after rendering for $WEB_USER"
done
if [ -f "$STAGE/bin/laranode-postgres-sudoers" ]; then
    sudoers_file_ok "$STAGE/bin/laranode-postgres-sudoers" || die "laranode-postgres-sudoers grants more than a laranode script inside $DEST/bin"
    render_for_web_user "$STAGE/bin/laranode-postgres-sudoers"
fi

# ---- swap (rename keeps the window where the path is missing to two syscalls) ---------
if [ -e "$DEST" ]; then
    mv -T -- "$DEST" "$STAGE.old"
fi
mv -T -- "$STAGE" "$DEST"
trap - EXIT
rm -rf -- "$STAGE.old"
chown root:root "$DEST"; chmod 755 "$DEST"

# ---- sudoers: base set + any drop-in already installed ------------------------------
if [ "$UFW" = 0 ]; then rm -f -- "$SUDOERS_DIR/laranode-ufw"; fi
for f in "$DEST"/etc/sudoers.d/*; do
    d=${f##*/}
    # ufw gated off (Proxmox, host.conf ufw=0): never installed
    if [ "$UFW" = 0 ] && [ "$d" = laranode-ufw ]; then continue; fi
    case " $BASE_DROPINS " in
        *" $d "*) : ;;
        *) [ -e "$SUDOERS_DIR/$d" ] || continue ;;
    esac
    visudo -c -f "$f" >/dev/null || die "sudoers drop-in $d failed syntax check (left as it was)"
    install -o root -g root -m 440 -- "$f" "$SUDOERS_DIR/$d"
done

echo "laranode scripts synced to $DEST ($n scripts)"
