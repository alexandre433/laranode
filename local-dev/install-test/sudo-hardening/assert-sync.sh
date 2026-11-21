#!/usr/bin/env bash
# laranode-sync-scripts.sh publishes sudoers drop-ins from the panel checkout (which the
# panel account can write) into /etc/sudoers.d. It must refuse ANY drop-in that grants more
# than "www-data may run one exact script inside the root-owned copy": a strict allowlist,
# not a blacklist. Runs inside a container, as root, against the tree under test.
#
# Pass = the sync exits non-zero, publishes nothing (no copy, no sudoers file) for every
# hostile drop-in, and succeeds, installing exactly the repo drop-ins, for the clean tree.
set -uo pipefail
PANEL=${PANEL:-/home/laranode_ln/panel}
SYNC="$PANEL/laranode-scripts/bin/laranode-sync-scripts.sh"
fail=0; n=0
bad() { echo "FAIL: $*" >&2; fail=1; }
ok()  { echo "  ok: $*"; }
[ -f "$SYNC" ] || { echo "FAIL: $SYNC missing" >&2; exit 1; }

W=$(mktemp -d); chmod 755 "$W"
trap 'rm -rf "$W"' EXIT
NL=$'\n'

fresh() {   # fresh <name>: a private copy of the scripts tree + empty dest/sudoers dir
    T="$W/$1"; mkdir -p "$T/panel" "$T/sudoers.d"; chmod 755 "$T"
    cp -a "$PANEL/laranode-scripts" "$T/panel/laranode-scripts"
    D="$T/lib"                       # DEST (does not exist yet); its parent $T is root 755
    # the repo drop-ins name /usr/local/lib/laranode; point them at this case's dest
    sed -i "s|/usr/local/lib/laranode|$D|g" "$T"/panel/laranode-scripts/etc/sudoers.d/*
}
run_sync() { LARANODE_LIB_DEST="$D" LARANODE_SUDOERS_DIR="$T/sudoers.d" bash "$SYNC" "$T/panel" 2>&1; }

echo "== sync-scripts: clean tree publishes =="
fresh clean
out=$(run_sync); rc=$?
n=$((n + 1))
if [ "$rc" -ne 0 ]; then bad "clean tree refused (rc=$rc): ${out:0:300}"
elif [ ! -x "$D/bin/laranode-cron.sh" ] || [ "$(stat -c %U "$D/bin/laranode-cron.sh")" != root ]; then bad "clean tree: no root-owned copy in $D/bin"
elif ! [ -f "$T/sudoers.d/laranode-panel" ] || ! grep -q "NOPASSWD: $D/bin/laranode-cron.sh" "$T/sudoers.d/laranode-cron" 2>/dev/null; then bad "clean tree: sudoers drop-ins not published with the dest path"
else ok "clean tree published to $D"; fi

# hostile <label> <drop-in text>: the drop-in is the repo's valid one plus the hostile text
hostile() {
    local label="$1" text="$2" name="${3:-laranode-evil}" out rc
    fresh "h$n"
    text=${text//@D@/$D}             # @D@ = this case's copy of /usr/local/lib/laranode
    printf '%s\n' "www-data ALL=(www-data) NOPASSWD: $D/bin/laranode-cron.sh" > "$T/panel/laranode-scripts/etc/sudoers.d/$name"
    printf '%s' "$text" >> "$T/panel/laranode-scripts/etc/sudoers.d/$name"
    out=$(run_sync); rc=$?
    n=$((n + 1))
    if [ "$rc" -eq 0 ]; then bad "sync ACCEPTED a hostile drop-in: $label"; echo "      $(printf '%q' "$text")" >&2
    elif [ -e "$D" ] || [ -e "$T/sudoers.d/$name" ] || ls "$T/sudoers.d" 2>/dev/null | grep -q .; then
        bad "sync refused ($label) but had already published something: $(ls "$T/sudoers.d" "$D" 2>/dev/null | tr '\n' ' ')"
    else ok "refused: $label"; fi
}

echo "== sync-scripts: hostile sudoers drop-ins are refused =="
hostile 'NOPASSWD: ALL'                         "www-data ALL=(ALL) NOPASSWD: ALL${NL}"
hostile 'NOPASSWD:ALL (no space)'               "www-data ALL=(ALL) NOPASSWD:ALL${NL}"
hostile 'NOPASSWD: ALL extra spaces'            "www-data  ALL=(ALL)  NOPASSWD:  ALL${NL}"
hostile 'comma list with /bin/sh'               "www-data ALL=(ALL) NOPASSWD: @D@/bin/laranode-cron.sh, /bin/sh${NL}"
hostile 'comma list without space'              "www-data ALL=(ALL) NOPASSWD: @D@/bin/laranode-cron.sh,/bin/sh${NL}"
hostile 'comma list then ALL'                   "www-data ALL=(ALL) NOPASSWD: @D@/bin/laranode-cron.sh, ALL${NL}"
hostile 'another user'                          "evil ALL=(ALL) NOPASSWD: @D@/bin/laranode-cron.sh${NL}"
hostile 'group principal'                       "%sudo ALL=(ALL) NOPASSWD: @D@/bin/laranode-cron.sh${NL}"
hostile 'path traversal out of the dest'        "www-data ALL=(ALL) NOPASSWD: @D@/bin/../../../../bin/sh${NL}"
hostile 'non-laranode file in the dest'         "www-data ALL=(ALL) NOPASSWD: @D@/bin/sh${NL}"
hostile 'wildcard argument'                     "www-data ALL=(ALL) NOPASSWD: @D@/bin/laranode-cron.sh *${NL}"
hostile 'fixed extra argument'                  "www-data ALL=(ALL) NOPASSWD: @D@/bin/laranode-cron.sh --evil${NL}"
hostile 'SETENV tag'                            "www-data ALL=(ALL) NOPASSWD:SETENV: @D@/bin/laranode-cron.sh${NL}"
hostile 'PASSWD-less ALL commands, no NOPASSWD' "www-data ALL=(ALL) ALL${NL}"
hostile 'runas ALL:ALL'                         "www-data ALL=(ALL:ALL) NOPASSWD: @D@/bin/laranode-cron.sh${NL}"
hostile 'Defaults !authenticate'                "Defaults !authenticate${NL}"
hostile 'Defaults:www-data !authenticate'       "Defaults:www-data !authenticate${NL}"
hostile 'Defaults env_keep LD_PRELOAD'          "Defaults env_keep+=LD_PRELOAD${NL}"
hostile 'Defaults on a path with extra option'  "Defaults!@D@/bin/laranode-cron.sh !requiretty, setenv${NL}"
hostile 'Cmnd_Alias ALL'                        "Cmnd_Alias EVIL = ALL${NL}"
hostile '#includedir'                           "#includedir /tmp/evil.d${NL}"
hostile '#include'                              "#include /tmp/evil${NL}"
hostile '@includedir'                           "@includedir /tmp/evil.d${NL}"
hostile 'backslash continuation joins a grant'  "www-data ALL=(ALL) NOPASSWD: @D@/bin/laranode-cron.sh, \\${NL}    ALL${NL}"
hostile 'comment ending in a backslash'         "# harmless \\${NL}www-data ALL=(ALL) NOPASSWD: ALL${NL}"
hostile 'carriage return in a line'             "www-data ALL=(ALL) NOPASSWD: @D@/bin/laranode-cron.sh"$'\r'"${NL}"
hostile 'grant with no trailing newline'        "www-data ALL=(ALL) NOPASSWD: ALL"
hostile 'drop-in with a foreign file name'      "" evil-dropin
hostile 'drop-in name with a dot'               "" laranode.evil

echo "sync-scripts cases run: $n"
if [ "$fail" = 0 ]; then echo "SYNC: PASS"; else echo "SYNC: FAIL" >&2; fi
exit "$fail"
