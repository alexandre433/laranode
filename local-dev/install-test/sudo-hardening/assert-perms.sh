#!/usr/bin/env bash
# Asserts the INSTALLED permission layout: nothing www-data (or the panel user) can
# sudo is writable by an unprivileged user. Runs inside a container, as root.
#   1. every sudo-granted path: each component root-owned and not group/other writable
#   2. no wildcard in any granted command spec
#   3. www-data / laranode_ln cannot write the granted scripts, their dir, the templates
#   4. .env is not group-writable and not world-readable
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
ok()  { echo "  ok: $*"; }

mapfile -t RULES < <(ln_sudo_rules)
[ "${#RULES[@]}" -gt 0 ] || { echo "FAIL: sudo -l -U www-data lists no commands" >&2; exit 1; }

# path_ok PATH — every component of the resolved path is root-owned and not g/o-writable
path_ok() {
    local p="$1" acc="" part real
    real=$(readlink -f -- "$p" 2>/dev/null) || real="$p"
    for target in "$p" "$real"; do
        acc=""
        IFS=/ read -ra parts <<<"${target#/}"
        for part in "" "${parts[@]}"; do
            [ -z "$part" ] && acc="/" || acc="${acc%/}/$part"
            [ -e "$acc" ] || continue
            read -r uid mode < <(stat -L -c '%u %a' -- "$acc")
            if [ "$uid" != 0 ]; then bad "$p: component $acc is owned by uid $uid"; return 1; fi
            if [ $(( 0$mode & 0022 )) -ne 0 ]; then bad "$p: component $acc is group/other-writable (mode $mode)"; return 1; fi
        done
    done
    return 0
}

echo "== sudo-granted commands (${#RULES[@]}) =="
for spec in "${RULES[@]}"; do
    exe="${spec%% *}"
    case "$spec" in
        *'*'*|*'?'*|*'['*) bad "wildcard in sudoers command spec: $spec" ;;
    esac
    case "$exe" in /*) : ;; ALL) bad "sudoers grants ALL"; continue ;; *) continue ;; esac
    if path_ok "$exe"; then ok "$exe (every path component root-owned, not g/o-writable)"; fi
done

BIN=$(ln_bin_dir) || { bad "no laranode-*.sh script in the sudo rules"; exit 1; }
TPL=$(ln_tpl_dir)
LIBD="$(cd "$BIN/.." && pwd)/lib"
for u in www-data laranode_ln; do
    id "$u" >/dev/null 2>&1 || continue
    for t in "$BIN" "$TPL" "$LIBD" "$BIN"/laranode-*.sh "$TPL"/* "$LIBD"/*; do
        [ -e "$t" ] || continue
        if runuser -u "$u" -- test -w "$t" 2>/dev/null; then bad "$u can write $t"; fi
    done
    # and cannot create a file next to the scripts (replace-by-unlink needs dir write)
    if runuser -u "$u" -- sh -c ": > '$BIN/.probe-$u'" 2>/dev/null; then
        rm -f "$BIN/.probe-$u"; bad "$u can create files in $BIN"
    fi
done
[ "$fail" = 0 ] && ok "no unprivileged write access to $BIN, $TPL"

ENVF=/home/laranode_ln/panel/.env
if [ -f "$ENVF" ]; then
    m=$(stat -c %a "$ENVF")
    if [ $(( 0$m & 0137 )) -ne 0 ]; then bad ".env mode is $m (must be <= 640: no group write, no world access)"; else ok ".env mode $m"; fi
fi

# The panel checkout: the web user reads it, it must not WRITE it (only storage and the logs
# dir are the web process's scratch space). Group/other-writable anything else lets a
# compromised www-data plant code that the panel user (queue worker, cron) runs, and that an
# installer / upgrade run as root would `require` (bootstrap/cache/{packages,services,config}.php
# are loaded by every artisan call). bootstrap/cache is therefore NOT writable by www-data.
H=/home/laranode_ln
if [ -d "$H/panel" ]; then
    loose=$(find "$H" -xdev ! -type l \( -perm -g+w -o -perm -o+w \) \
        ! -path "$H/panel/storage" ! -path "$H/panel/storage/*" \
        ! -path "$H/logs" ! -path "$H/logs/*" 2>/dev/null | head -5)
    if [ -n "$loose" ]; then bad "group/other-writable under $H outside storage and logs: $(echo $loose)"
    else ok "nothing under $H is group/other-writable except storage and logs"; fi
    if [ -d "$H/panel/bootstrap/cache" ]; then
        if runuser -u www-data -- sh -c ": > '$H/panel/bootstrap/cache/.probe-www'" 2>/dev/null; then
            rm -f "$H/panel/bootstrap/cache/.probe-www"; bad "www-data can create files in $H/panel/bootstrap/cache"
        else ok "www-data cannot write bootstrap/cache"; fi
        for f in "$H"/panel/bootstrap/cache/*.php; do
            [ -e "$f" ] || continue
            if runuser -u www-data -- test -w "$f" 2>/dev/null; then bad "www-data can write $f"; fi
        done
    fi
fi

# create-directory.sh runs `chown -R -h` as root over a tenant tree. A tenant (or www-data,
# which is in every tenant group) could hard-link a file it does not own into that tree and
# have root chown the shared inode. fs.protected_hardlinks=1 (the Debian/Ubuntu default)
# forbids linking a file you cannot read AND write.
ph=$(cat /proc/sys/fs/protected_hardlinks 2>/dev/null || echo missing)
if [ "$ph" = 1 ]; then ok "fs.protected_hardlinks=1"; else bad "fs.protected_hardlinks is '$ph' (must be 1: root chown -R runs over tenant trees)"; fi

if [ "$fail" = 0 ]; then echo "PERMS: PASS"; else echo "PERMS: FAIL" >&2; fi
exit "$fail"
