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
#   hostdb is registered ONLY when LARANODE_DB_INSTALLED_BY_US=1 (the installer
#   set it because it installed the database itself, not because one existed).
#
set -uo pipefail

[ "$(id -u)" = 0 ] || { echo "ERROR: must run as root" >&2; exit 4; }
[ $# -ge 1 ] || { echo "usage: $0 <reverb|queue|fpm|hostdb> ..." >&2; exit 2; }

DIR=${LARANODE_MANAGED_DIR:-/etc/laranode}
UNIT_DIR=${LARANODE_UNIT_DIR:-/etc/systemd/system}
PANEL_ENV=${LARANODE_PANEL_ENV:-/home/laranode_ln/panel/.env}

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

register_reverb() {
    [ -f "$UNIT_DIR/laranode-reverb.service" ] || { echo "skip reverb: laranode-reverb.service not installed" >&2; return 0; }
    local port
    port=$(env_value REVERB_SERVER_PORT 8080)
    [[ $port =~ ^[0-9]{1,5}$ ]] || port=8080
    write_entry reverb <<EOF
kind=reverb
unit=laranode-reverb.service
public_port=$port
EOF
}

register_queue() {
    [ -f "$UNIT_DIR/laranode-queue-worker.service" ] || { echo "skip queue: laranode-queue-worker.service not installed" >&2; return 0; }
    write_entry queue <<EOF
kind=queue
unit=laranode-queue-worker.service
EOF
}

register_fpm() {
    write_entry fpm <<EOF
kind=fpm
EOF
}

register_hostdb() {
    if [ "${LARANODE_DB_INSTALLED_BY_US:-0}" != 1 ]; then
        echo "skip hostdb: database was not installed by Laranode (external, never managed)" >&2
        return 0
    fi
    local engine unit sock cnf
    if systemctl cat mariadb.service >/dev/null 2>&1; then engine=mariadb; unit=mariadb.service
    elif systemctl cat mysql.service >/dev/null 2>&1; then engine=mysql; unit=mysql.service
    else echo "skip hostdb: no MySQL/MariaDB unit found" >&2; return 0; fi
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
