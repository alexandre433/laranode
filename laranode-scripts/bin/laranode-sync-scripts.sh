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

die() { echo "laranode-sync-scripts: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -d "$SRC/bin" ] && [ -d "$SRC/lib" ] && [ -d "$SRC/templates" ] && [ -d "$SRC/etc/sudoers.d" ] \
    || die "no laranode-scripts tree at $SRC"
# the destination's parent must be root-owned and not writable by others
parent=$(dirname "$DEST")
[ "$(stat -c '%u' "$parent")" = 0 ] && [ $(( 0$(stat -c '%a' "$parent") & 022 )) -eq 0 ] \
    || die "$parent must be owned by root and not group/world writable"
# never follow a link out of the source tree
if find "$SRC/bin" "$SRC/lib" "$SRC/templates" "$SRC/etc" -type l | grep -q .; then
    die "symlinks inside $SRC are not allowed"
fi

STAGE=$(mktemp -d "$parent/.laranode-stage.XXXXXX")
trap 'rm -rf -- "$STAGE"' EXIT
chmod 755 "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/templates" "$STAGE/etc/sudoers.d"

# ---- bin: every laranode-*.sh, except the installer (run by hand from the tree) -------
# stage_file <src> <dst> <mode>: copy WITHOUT following a symlink (cp -P opens the source
# O_NOFOLLOW), then require a plain regular file. Everything is then checked and published
# from the root-only COPY: the panel account cannot swap the source between check and use,
# and a link swapped in after the symlink scan cannot make root copy /etc/shadow into the tree.
stage_file() {
    cp -P --no-preserve=all -- "$1" "$2" || die "cannot copy ${1##*/}"
    [ -f "$2" ] && [ ! -L "$2" ] || die "${1##*/} is not a regular file"
    chown root:root -- "$2"; chmod "$3" -- "$2"
}

n=0
for f in "$SRC"/bin/laranode-*.sh; do
    b=${f##*/}
    [ "$b" = laranode-installer.sh ] && continue
    [[ $b =~ ^laranode-[a-z0-9-]+\.sh$ ]] || die "unexpected script name: $b"
    stage_file "$f" "$STAGE/bin/$b" 755
    bash -n "$STAGE/bin/$b" || die "syntax error in $b"
    n=$((n + 1))
done
[ "$n" -gt 0 ] || die "no scripts found in $SRC/bin"
# the postgres sudoers snippet is data, kept for the pgsql branch
[ -f "$SRC/bin/laranode-postgres-sudoers" ] && stage_file "$SRC/bin/laranode-postgres-sudoers" "$STAGE/bin/laranode-postgres-sudoers" 644

for f in "$SRC"/lib/*.sh; do
    stage_file "$f" "$STAGE/lib/${f##*/}" 644
    bash -n "$STAGE/lib/${f##*/}" || die "syntax error in lib/${f##*/}"
done
for f in "$SRC"/templates/*; do
    [ -f "$f" ] || continue
    stage_file "$f" "$STAGE/templates/${f##*/}" 644
done
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

for f in "$SRC"/etc/sudoers.d/*; do
    [ -f "$f" ] || continue
    d=${f##*/}
    [[ $d =~ ^laranode-[a-z0-9-]+$ ]] || die "unexpected sudoers drop-in name: $d"
    stage_file "$f" "$STAGE/etc/sudoers.d/$d" 644
    visudo -c -f "$STAGE/etc/sudoers.d/$d" >/dev/null || die "sudoers drop-in $d failed syntax check"
    sudoers_file_ok "$STAGE/etc/sudoers.d/$d" || die "sudoers drop-in $d grants more than a laranode script inside $DEST/bin"
done

# ---- swap (rename keeps the window where the path is missing to two syscalls) ---------
if [ -e "$DEST" ]; then
    mv -T -- "$DEST" "$STAGE.old"
fi
mv -T -- "$STAGE" "$DEST"
trap - EXIT
rm -rf -- "$STAGE.old"
chown root:root "$DEST"; chmod 755 "$DEST"

# ---- sudoers: base set + any drop-in already installed ------------------------------
for f in "$DEST"/etc/sudoers.d/*; do
    d=${f##*/}
    case " $BASE_DROPINS " in
        *" $d "*) : ;;
        *) [ -e "$SUDOERS_DIR/$d" ] || continue ;;
    esac
    visudo -c -f "$f" >/dev/null || die "sudoers drop-in $d failed syntax check (left as it was)"
    install -o root -g root -m 440 -- "$f" "$SUDOERS_DIR/$d"
done

echo "laranode scripts synced to $DEST ($n scripts)"
