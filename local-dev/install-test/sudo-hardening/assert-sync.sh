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
    sed -i "s|/usr/local/lib/laranode|$D|g" "$T"/panel/laranode-scripts/etc/sudoers.d/* "$T"/panel/laranode-scripts/bin/laranode-postgres-sudoers
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

# F2 (review r3): the installer installs four templates verbatim as root (systemd units, the
# scheduler cron line, the panel vhost). A tampered copy in the checkout must not reach the root copy.
setup_unit_root()   { sed -i 's/^User=laranode_ln$/User=root/' templates/laranode-queue-worker.service; }
setup_unit_pre()    { echo 'ExecStartPre=/bin/sh -c "id > /tmp/pwned"' >> templates/laranode-reverb.service; }
setup_unit_exec()   { sed -i 's#^ExecStart=.*#ExecStart=/tmp/evil#' templates/laranode-reverb.service; }
setup_qunit_exec()  { sed -i 's#^ExecStart=.*#ExecStart=/tmp/evil#' templates/laranode-queue-worker.service; }
setup_qunit_pre()   { echo 'ExecStartPre=/bin/sh -c "id > /tmp/pwned"' >> templates/laranode-queue-worker.service; }
setup_cron_root()   { echo '* * * * * root /tmp/evil' >> templates/laranode-schedule.cron; }
setup_cron_user()   { sed -i 's/__PANEL_USER__/root/' templates/laranode-schedule.cron; }
setup_vhost_mod()   { echo 'LoadModule evil_module /tmp/evil.so' >> templates/apache-panel.template; }
setup_vhost_inc()   { echo '    Include /tmp/evil.conf' >> templates/apache-panel.template; }
setup_unit_cont()   { printf '%s\n' '# harmless \' 'ExecStartPre=/tmp/x' >> templates/laranode-queue-worker.service; }
setup_tpl_missing() { rm templates/laranode-reverb.service; }
refuse_case 'queue unit: User=root'                      setup_unit_root
refuse_case 'reverb unit: ExecStartPre injected'         setup_unit_pre
refuse_case 'reverb unit: ExecStart replaced'            setup_unit_exec
refuse_case 'queue unit: ExecStart replaced'             setup_qunit_exec
refuse_case 'queue unit: ExecStartPre injected'          setup_qunit_pre
refuse_case 'cron: extra root line appended'             setup_cron_root
refuse_case 'cron: scheduler line runs as root'          setup_cron_user
refuse_case 'panel vhost: LoadModule injected'           setup_vhost_mod
refuse_case 'panel vhost: Include injected'              setup_vhost_inc
refuse_case 'unit: backslash-continued comment smuggles a directive' setup_unit_cont
refuse_case 'a required installer template is missing'   setup_tpl_missing

# ---- host.conf: which account the grants go to (Proxmox: laranode_web, never www-data) -------
# run_sync_hc <host.conf text or -> [pve]: '-' = no host.conf; pve = a fake /etc/pve exists
run_sync_hc() {
    local text="$1" pve="${2:-}" hc="$T/host.conf" pd="$T/no-pve"
    rm -f "$hc"
    [ "$text" = - ] || { printf '%s' "$text" > "$hc"; chown root:root "$hc"; chmod 644 "$hc"; }
    [ -n "$HC_MODE" ] && chmod "$HC_MODE" "$hc"
    [ -n "$HC_OWNER" ] && chown "$HC_OWNER" "$hc"
    [ -n "$HC_LINK" ] && { mv "$hc" "$hc.real"; ln -s "$hc.real" "$hc"; }
    [ "$pve" = pve ] && { pd="$T/pve"; mkdir -p "$pd"; }
    LARANODE_HOST_CONF="$hc" LARANODE_PVE_DIR="$pd" LARANODE_LIB_DEST="$D" LARANODE_SUDOERS_DIR="$T/sudoers.d" \
        bash "$SYNC" "$T/panel" 2>&1
}
HC_MODE=''; HC_OWNER=''; HC_LINK=''
hc_refuse() {   # <label> <host.conf text or -> [pve]
    local label="$1" out rc
    fresh "hc$n"
    out=$(run_sync_hc "$2" "${3:-}"); rc=$?
    n=$((n + 1))
    if [ "$rc" -eq 0 ]; then bad "sync ACCEPTED: $label"
    elif [ -e "$D" ] || ls "$T/sudoers.d" 2>/dev/null | grep -q .; then bad "sync refused ($label) but had already published something"
    else ok "refused: $label"; fi
}
grants_of() { grep -hv '^#' "$T"/sudoers.d/* 2>/dev/null | sed -n 's/^\([^ ]*\) ALL=.*/\1/p' | sort -u | tr '\n' ' '; }

echo "== sync-scripts: host.conf web user + ufw gate =="
userdel laranode_web >/dev/null 2>&1 || true
hc_refuse 'Proxmox host without host.conf (would grant www-data = pveproxy)' - pve
hc_refuse 'Proxmox host with web_user=www-data'                    "web_user=www-data${NL}ufw=0${NL}" pve
hc_refuse 'web_user=laranode_web but the account does not exist'   "web_user=laranode_web${NL}ufw=1${NL}"
getent passwd laranode_web >/dev/null || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --user-group laranode_web
hc_refuse 'host.conf names another user'                           "web_user=root${NL}"
hc_refuse 'host.conf with an unknown line'                         "web_user=laranode_web${NL}evil=1${NL}"
hc_refuse 'host.conf ufw value not 0/1'                            "web_user=laranode_web${NL}ufw=yes${NL}"
HC_MODE=664; hc_refuse 'host.conf group-writable'                  "web_user=laranode_web${NL}"; HC_MODE=''
HC_OWNER=laranode_ln; hc_refuse 'host.conf not owned by root'      "web_user=laranode_web${NL}"; HC_OWNER=''
HC_LINK=1; hc_refuse 'host.conf is a symlink'                      "web_user=laranode_web${NL}"; HC_LINK=''

fresh hcweb
out=$(run_sync_hc "web_user=laranode_web${NL}ufw=1${NL}" pve); rc=$?
n=$((n + 1))
if [ "$rc" -ne 0 ]; then bad "web_user=laranode_web on Proxmox refused (rc=$rc): ${out:0:300}"
elif grep -v '^#' "$T"/sudoers.d/* | grep -q 'www-data'; then bad "laranode_web render: www-data still named: $(grep -l www-data "$T"/sudoers.d/* | tr '\n' ' ')"
elif [ "$(grants_of)" != "laranode_web " ]; then bad "laranode_web render: grants go to [$(grants_of)], want [laranode_web ]"
elif ! grep -q "^laranode_web ALL=(laranode_web) NOPASSWD: " "$T"/sudoers.d/*; then bad "laranode_web render: no ALL=(laranode_web) runas line (the www-data runas column was not rendered)"
elif ! [ -f "$T/sudoers.d/laranode-ufw" ]; then bad "ufw=1: laranode-ufw drop-in not installed"
else
    vbad=0; for f in "$T"/sudoers.d/*; do visudo -c -f "$f" >/dev/null 2>&1 || { vbad=1; bad "rendered drop-in fails visudo: ${f##*/}"; }; done
    [ "$vbad" = 0 ] && ok "web_user=laranode_web: every grant names laranode_web, none www-data, visudo clean"
fi

fresh hcufw
: > "$T/sudoers.d/laranode-ufw"; chmod 440 "$T/sudoers.d/laranode-ufw"   # left by an earlier ufw=1 run
out=$(run_sync_hc "web_user=laranode_web${NL}ufw=0${NL}" pve); rc=$?
n=$((n + 1))
if [ "$rc" -ne 0 ]; then bad "ufw=0 refused (rc=$rc): ${out:0:300}"
elif [ -e "$T/sudoers.d/laranode-ufw" ]; then bad "ufw=0: laranode-ufw drop-in still present (installed or not removed)"
elif ! [ -f "$T/sudoers.d/laranode-panel" ]; then bad "ufw=0: the other drop-ins were not installed"
else ok "ufw=0: laranode-ufw removed and not installed, the rest published"; fi

fresh hcplain
out=$(run_sync_hc -); rc=$?
n=$((n + 1))
if [ "$rc" -ne 0 ]; then bad "plain host without host.conf refused (rc=$rc): ${out:0:300}"
elif [ "$(grants_of)" != "www-data " ]; then bad "plain host: grants go to [$(grants_of)], want [www-data ] (unchanged)"
else ok "plain host without host.conf: unchanged www-data grants"; fi

# lib/validate.sh: every sudo-able script takes LN_WEB_USER from the fixed /etc/laranode/host.conf
echo "== lib/validate.sh: LN_WEB_USER from host.conf =="
VAL="$PANEL/laranode-scripts/lib/validate.sh"
HCR=/etc/laranode/host.conf
mkdir -p /etc/laranode
had_hc=0; [ -e "$HCR" ] && { had_hc=1; cp -a "$HCR" "$W/host.conf.saved"; }
had_pve=0; [ -e /etc/pve ] && had_pve=1
lnweb() { bash -c '. "$1" && echo "$LN_WEB_USER"' _ "$VAL" 2>&1; }
val_case() {   # <label> <want: user or REFUSED> <host.conf text or -> [mode] [pve]
    local label="$1" want="$2" text="$3" mode="${4:-644}" pve="${5:-}" got rc
    rm -f "$HCR"
    [ "$text" = - ] || { printf '%s' "$text" > "$HCR"; chmod "$mode" "$HCR"; }
    [ "$pve" = pve ] && [ "$had_pve" = 0 ] && mkdir -p /etc/pve
    got=$(lnweb); rc=$?
    [ "$pve" = pve ] && [ "$had_pve" = 0 ] && rmdir /etc/pve
    n=$((n + 1))
    if [ "$want" = REFUSED ]; then
        if [ "$rc" -ne 0 ]; then ok "validate.sh refuses: $label"; else bad "validate.sh ACCEPTED ($label): LN_WEB_USER=$got"; fi
    elif [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then ok "validate.sh: $label -> $want"
    else bad "validate.sh ($label): got [$got] rc=$rc, want $want"; fi
}
if [ "$had_pve" = 0 ]; then
    val_case 'no host.conf'                     www-data     -
    val_case 'web_user=laranode_web'            laranode_web "web_user=laranode_web${NL}ufw=0${NL}"
    val_case 'web_user=root'                    REFUSED      "web_user=root${NL}"
    val_case 'group-writable host.conf'         REFUSED      "web_user=laranode_web${NL}" 664
    val_case 'Proxmox, no host.conf'            REFUSED      - 644 pve
    val_case 'Proxmox, web_user=www-data'       REFUSED      "web_user=www-data${NL}" 644 pve
    val_case 'Proxmox, web_user=laranode_web'   laranode_web "web_user=laranode_web${NL}" 644 pve
else
    echo "  (skipped: /etc/pve exists on this host)"
fi
rm -f "$HCR"; [ "$had_hc" = 1 ] && cp -a "$W/host.conf.saved" "$HCR"

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
