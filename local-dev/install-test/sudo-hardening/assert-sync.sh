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

# a symlink anywhere in the tree must never be followed by the root copy (it would publish
# e.g. /etc/shadow, world-readable, into the script directory)
symlink_case() {   # <label> <path under laranode-scripts> <target>
    local label="$1" rel="$2" target="$3" out rc
    fresh "s$n"
    ln -s "$target" "$T/panel/laranode-scripts/$rel"
    out=$(run_sync); rc=$?
    n=$((n + 1))
    if [ "$rc" -eq 0 ]; then bad "sync FOLLOWED/ignored a symlink: $label"
    elif [ -e "$D" ]; then bad "sync refused ($label) but had already published a copy"
    else ok "refused: $label"; fi
}
echo "== sync-scripts: symlinks in the source tree are refused =="
symlink_case 'script is a symlink'    bin/laranode-evil.sh   /etc/hostname
symlink_case 'lib file is a symlink'  lib/evil.sh            /etc/hostname
symlink_case 'template is a symlink'  templates/evil.template /etc/shadow
symlink_case 'sudoers drop-in is a symlink' etc/sudoers.d/laranode-evil /etc/hostname

# F1 (review r3): the per-file symlink check only sees the LAST path component, and the copy ran
# as root. A racing laranode_ln swaps a parent directory ($SRC/templates -> a root-only dir) after
# the scan and root copies root-only files into the www-data-readable copy. The source must be
# READ AS laranode_ln (it can then only ever hand over what it could read anyway).
CANARY=ROOT-ONLY-CANARY-$$
rootonly_case() {   # <label> <setup fn run in the case's laranode-scripts dir>
    local label="$1" setup="$2" out rc
    fresh "r$n"
    ( cd "$T/panel/laranode-scripts" && $setup ) || { bad "setup failed: $label"; return; }
    out=$(run_sync); rc=$?
    n=$((n + 1))
    if [ "$rc" -eq 0 ] && grep -rq "$CANARY" "$D" 2>/dev/null; then bad "sync COPIED a file the panel account cannot read: $label"
    elif [ "$rc" -eq 0 ]; then bad "sync accepted a source the panel account cannot read: $label"
    elif [ -e "$D" ]; then bad "sync refused ($label) but had already published a copy"
    else ok "refused: $label"; fi
}
setup_rootonly_template() { echo "$CANARY" > templates/evil.template; chown root:root templates/evil.template; chmod 600 templates/evil.template; }
setup_rootonly_dir()      { mkdir templates/sub; echo "$CANARY" > templates/sub/x; chown -R root:root templates/sub; chmod 700 templates/sub; chown root:root templates; chmod 700 templates; }
setup_rootonly_script()   { echo "echo $CANARY" > bin/laranode-evil.sh; chown root:root bin/laranode-evil.sh; chmod 600 bin/laranode-evil.sh; }
echo "== sync-scripts: the source is read as the panel account, never as root =="
rootonly_case 'root-only template in the source'          setup_rootonly_template
rootonly_case 'root-only source directory (templates/)'   setup_rootonly_dir
rootonly_case 'root-only script in the source'            setup_rootonly_script

# names the root copy will not accept (a hostile name must never reach a root path), and a file
# big enough to fill the disk the staging dir lives on
refuse_case() {   # <label> <setup fn run in the case's laranode-scripts dir>
    local label="$1" setup="$2" out rc
    fresh "x$n"
    ( cd "$T/panel/laranode-scripts" && $setup ) || { bad "setup failed: $label"; return; }
    out=$(run_sync); rc=$?
    n=$((n + 1))
    if [ "$rc" -eq 0 ]; then bad "sync ACCEPTED: $label"
    elif [ -e "$D" ]; then bad "sync refused ($label) but had already published a copy"
    else ok "refused: $label"; fi
}
setup_dot_template()   { echo x > templates/.evil; }
setup_space_template() { echo x > 'templates/evil tpl'; }
setup_dash_template()  { echo x > ./-evil.tpl; mv ./-evil.tpl templates/-evil.tpl; }
setup_big_template()   { head -c 3000000 /dev/zero > templates/big.template; }
setup_dir_script()     { mkdir bin/laranode-dir.sh; }
refuse_case 'template with a leading dot'      setup_dot_template
refuse_case 'template name with a space'       setup_space_template
refuse_case 'template name starting with -'    setup_dash_template
refuse_case 'template over 2 MiB'              setup_big_template
refuse_case 'a directory named like a script'  setup_dir_script

# the real race: swap a NON-last component ($SRC/templates) between a real dir and a link to a
# root-only dir while the sync runs. Whatever the timing, no root-only byte may reach the copy.
race_case() {
    local i leaks=0 published=0 stop swapper out reasons=""
    fresh race
    mkdir -p "$T/rootonly"; echo "$CANARY" > "$T/rootonly/leak.template"; chmod 700 "$T/rootonly"; chmod 600 "$T/rootonly/leak.template"
    # many templates: widen the window between the symlink scan and the copy loop
    for i in $(seq 1 300); do echo "x$i" > "$T/panel/laranode-scripts/templates/pad$i.tpl"; done
    stop="$T/stop"
    (
        cd "$T/panel/laranode-scripts" || exit 1
        while [ ! -e "$stop" ]; do
            mv templates templates.hold && ln -s "$T/rootonly" templates
            sleep 0.002
            rm -f templates && mv templates.hold templates
            sleep 0.002
        done
    ) &
    swapper=$!
    for i in $(seq 1 60); do
        rm -rf "$D" "$T"/.laranode-stage.* 2>/dev/null
        if out=$(run_sync); then
            published=$((published + 1))
            grep -rq "$CANARY" "$D" 2>/dev/null && leaks=$((leaks + 1))
        else
            reasons+="${out##*$NL}|"
        fi
        [ -e "$D" ] && grep -rq "$CANARY" "$D" 2>/dev/null && [ "$leaks" -eq 0 ] && leaks=$((leaks + 1))
    done
    : > "$stop"; wait "$swapper" 2>/dev/null
    n=$((n + 1))
    if [ "$leaks" -gt 0 ]; then bad "RACE: root copied root-only files through a swapped parent directory ($leaks of 60 syncs leaked)"
    else ok "race: 60 syncs against a swapping templates/ parent, no root-only byte copied ($published published; refusals: $(printf '%s' "$reasons" | tr '|' '\n' | sort | uniq -c | tr '\n' ';'))"; fi
}
echo "== sync-scripts: a parent directory swapped during the run leaks nothing =="
race_case

echo "sync-scripts cases run: $n"
if [ "$fail" = 0 ]; then echo "SYNC: PASS"; else echo "SYNC: FAIL" >&2; fi
exit "$fail"
