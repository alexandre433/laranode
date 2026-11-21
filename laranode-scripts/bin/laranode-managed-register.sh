#!/bin/bash
#
# laranode-managed-register.sh — root-only (NOT in sudoers). Run by the installer.
#
# Writes the allowlist of services Laranode itself installed:
#   /etc/laranode/managed.d/<key>.conf   (root:root, read-only)
# laranode-sleep.sh (the one privileged panel entry point) refuses everything not
# listed here, so pre-existing services on a host (shared PostgreSQL, Redis,
# nginx, Percona, ...) are never touched. Unit names are detected at runtime, so
# the same build works on Ubuntu 24.04 and Debian 13.
#
# Usage: laranode-managed-register.sh <reverb|queue|fpm|hostdb> [...]
#   $DIR/service-manifest.json (written by the installer) is the source of truth and is
#   REQUIRED: a key is registered only if the manifest lists its service as managed:true
#   (installed by Laranode). No manifest = nothing is registered (fail closed).
#
set -uo pipefail

[ "$(id -u)" = 0 ] || { echo "ERROR: must run as root" >&2; exit 4; }
[ $# -ge 1 ] || { echo "usage: $0 <reverb|queue|fpm|hostdb> ..." >&2; exit 2; }

DIR=${LARANODE_MANAGED_DIR:-/etc/laranode}
UNIT_DIR=${LARANODE_UNIT_DIR:-/etc/systemd/system}
PANEL_ENV=${LARANODE_PANEL_ENV:-/home/laranode_ln/panel/.env}
MANIFEST="$DIR/service-manifest.json"

install -d -m 0755 -o root -g root "$DIR" "$DIR/managed.d" "$DIR/sleep"

write_entry() { # key ; stdin = k=v lines
    local tmp
    tmp=$(mktemp "$DIR/managed.d/.tmp.XXXXXX") || exit 1
    cat > "$tmp"
    chown root:root "$tmp"; chmod 0644 "$tmp"
    mv -f "$tmp" "$DIR/managed.d/$1.conf"
    echo "registered: $1"
}

env_value() { # NAME default
    local v
    v=$(grep -m1 "^$1=" "$PANEL_ENV" 2>/dev/null | cut -d= -f2- | tr -d '"'"'" | tr -d '[:space:]')
    printf '%s' "${v:-$2}"
}

# manifest_allows <role>: 0 = allowed. With a manifest it must list a managed:true line
# for the role; without one the caller falls back to the legacy behaviour.
have_manifest() { [ -f "$MANIFEST" ]; }
manifest_allows() {
    grep -F '"managed":true' "$MANIFEST" | grep -qF "\"role\":\"$1\""
}
manifest_gate() { # role key ; returns 1 (and says why) when the manifest does not back it
    # FAIL CLOSED: no manifest = nothing proves Laranode installed the service
    have_manifest || { echo "skip $2: no service manifest ($MANIFEST): cannot prove Laranode installed it (never managed)" >&2; return 1; }
    manifest_allows "$1" && return 0
    echo "skip $2: service manifest lists no Laranode-installed '$1' service (external, never managed)" >&2
    return 1
}

register_reverb() {
    manifest_gate reverb reverb || return 0
    [ -f "$UNIT_DIR/laranode-reverb.service" ] || { echo "skip reverb: laranode-reverb.service not installed" >&2; return 0; }
    local port
    port=$(env_value REVERB_SERVER_PORT 8080)
    [[ $port =~ ^[0-9]{1,5}$ ]] || port=8080
    # Where Reverb itself listens (the installer sets REVERB_SERVER_HOST=127.0.0.1 on Proxmox /
    # CloudPanel hosts; config/reverb.php defaults to 0.0.0.0). The sleep socket must bind
    # exactly there, so enabling sleep can never expose a loopback-only Reverb.
    local host o
    host=$(env_value REVERB_SERVER_HOST 0.0.0.0)
    [ "$host" = localhost ] && host=127.0.0.1
    if [[ $host =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        for o in ${host//./ }; do [ "$((10#$o))" -le 255 ] || host=""; done
    else
        host=""
    fi
    [ -n "$host" ] || { echo "skip reverb: REVERB_SERVER_HOST is not a plain IPv4 address (cannot mirror its bind safely)" >&2; return 0; }
    write_entry reverb <<EOF
kind=reverb
unit=laranode-reverb.service
public_port=$port
bind_host=$host
EOF
}

register_queue() {
    manifest_gate queue queue || return 0
    [ -f "$UNIT_DIR/laranode-queue-worker.service" ] || { echo "skip queue: laranode-queue-worker.service not installed" >&2; return 0; }
    write_entry queue <<EOF
kind=queue
unit=laranode-queue-worker.service
EOF
}

register_fpm() {
    manifest_gate php fpm || return 0
    write_entry fpm <<EOF
kind=fpm
EOF
}

# aa_state: none | enforced | unknown. Root can read the kernel profile list; the panel cannot, so the
# verdict is recorded here for the Power page. laranode-sleep.sh re-checks it on every enable/wake.
aa_state() {
    local en="" enabled=${LARANODE_AA_ENABLED:-/sys/module/apparmor/parameters/enabled}
    local profiles=${LARANODE_AA_PROFILES:-/sys/kernel/security/apparmor/profiles}
    [ -r "$enabled" ] && en=$(tr -d '[:space:]' < "$enabled" 2>/dev/null)
    [ "$en" = Y ] || { echo none; return; }
    [ -r "$profiles" ] || { echo unknown; return; }
    if grep -Eq '(^|/)(mysqld|mariadbd)[[:space:]]+[(]enforce[)]$' "$profiles" 2>/dev/null; then echo enforced; else echo none; fi
}

register_hostdb() {
    manifest_gate database hostdb || return 0
    local engine unit sock cnf mfunit=""
    # pin to the exact unit the installer recorded for the database it installed, so a
    # pre-existing MySQL next to a Laranode-installed PostgreSQL is never picked up
    mfunit=$(grep -F '"managed":true' "$MANIFEST" | grep -F '"role":"database"' | sed -n 's/.*"unit":"\([^"]*\)".*/\1/p' | head -1)
    [[ $mfunit =~ ^(mysql|mariadb|mysqld)\.service$ ]] || { echo "skip hostdb: manifest database unit '$mfunit' is not MySQL/MariaDB" >&2; return 0; }
    systemctl cat "$mfunit" >/dev/null 2>&1 || { echo "skip hostdb: $mfunit not found" >&2; return 0; }
    unit=$mfunit
    case $mfunit in mariadb.service) engine=mariadb ;; *) engine=mysql ;; esac
    # canonical unit (mysql.service is an alias of mariadb.service on Debian)
    unit=$(systemctl show -p Id --value "$unit" 2>/dev/null || echo "$unit")
    [[ $unit =~ ^(mysql|mariadb|mysqld)\.service$ ]] || { echo "skip hostdb: unexpected unit $unit" >&2; return 0; }

    sock=$(my_print_defaults mysqld 2>/dev/null | sed -n 's/^--socket=//p' | tail -1)
    [ -n "$sock" ] || sock=/run/mysqld/mysqld.sock
    [[ $sock =~ ^/[A-Za-z0-9_./-]+$ ]] || sock=/run/mysqld/mysqld.sock

    # the last-included config dir wins, so our drop-in must live there
    cnf=/etc/mysql/conf.d
    for d in /etc/mysql/mysql.conf.d /etc/mysql/mariadb.conf.d; do [ -d "$d" ] && cnf=$d; done
    [ -d "$cnf" ] || { echo "skip hostdb: no config dir" >&2; return 0; }

    write_entry hostdb <<EOF
kind=db
engine=$engine
unit=$unit
public_port=3306
public_socket=$sock
cnf_dir=$cnf
panel_env=$PANEL_ENV
apparmor=$(aa_state)
EOF
}

rc=0
for key in "$@"; do
    case "$key" in
        reverb) register_reverb ;;
        queue) register_queue ;;
        fpm) register_fpm ;;
        hostdb) register_hostdb ;;
        *) echo "ERROR: unknown key '$key'" >&2; rc=2 ;;
    esac
done
exit $rc
