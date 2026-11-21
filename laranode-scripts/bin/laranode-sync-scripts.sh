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
n=0
for f in "$SRC"/bin/laranode-*.sh; do
    b=${f##*/}
    [ "$b" = laranode-installer.sh ] && continue
    [[ $b =~ ^laranode-[a-z0-9-]+\.sh$ ]] || die "unexpected script name: $b"
    bash -n "$f" || die "syntax error in $b"
    install -o root -g root -m 755 -- "$f" "$STAGE/bin/$b"
    n=$((n + 1))
done
[ "$n" -gt 0 ] || die "no scripts found in $SRC/bin"
# the postgres sudoers snippet is data, kept for the pgsql branch
[ -f "$SRC/bin/laranode-postgres-sudoers" ] && install -o root -g root -m 644 -- "$SRC/bin/laranode-postgres-sudoers" "$STAGE/bin/laranode-postgres-sudoers"

for f in "$SRC"/lib/*.sh; do
    bash -n "$f" || die "syntax error in lib/${f##*/}"
    install -o root -g root -m 644 -- "$f" "$STAGE/lib/${f##*/}"
done
for f in "$SRC"/templates/*; do
    [ -f "$f" ] || continue
    install -o root -g root -m 644 -- "$f" "$STAGE/templates/${f##*/}"
done
for f in "$SRC"/etc/sudoers.d/*; do
    [ -f "$f" ] || continue
    visudo -c -f "$f" >/dev/null || die "sudoers drop-in ${f##*/} failed syntax check"
    # every granted path must point into the root-owned copy, nowhere else
    if grep -E '^[^#]*NOPASSWD' "$f" | grep -Ev "NOPASSWD: ($DEST/bin/|/usr/sbin/ufw|ALL$)" | grep -q .; then
        die "sudoers drop-in ${f##*/} grants a path outside $DEST/bin"
    fi
    install -o root -g root -m 644 -- "$f" "$STAGE/etc/sudoers.d/${f##*/}"
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
