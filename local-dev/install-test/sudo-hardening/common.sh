#!/usr/bin/env bash
# Shared helpers for the sudo-hardening checks. Runs INSIDE a container, as root.
# Source this file; do not execute it.
#
# The checks are layout-agnostic: the script directory is discovered from what
# `sudo -l -U www-data` really grants, so the same assertions prove both the
# legacy layout (scripts inside the www-data-writable panel tree) and the fixed one.

# The panel web user: www-data, or laranode_web on a Proxmox host (the installer records it in
# /etc/laranode/host.conf). Every check below runs as, and reads the grants of, that account.
ln_web_user() {
    local u
    u=$(sed -n 's/^web_user=\(www-data\|laranode_web\)$/\1/p' /etc/laranode/host.conf 2>/dev/null | tail -n1)
    echo "${u:-www-data}"
}
LN_WEB=$(ln_web_user)

ln_sudo_rules() {   # one command spec per line, as sudo -l prints them for the web user
    sudo -l -U "$LN_WEB" 2>/dev/null \
      | sed -n -E 's/^ +\([^)]*\) +//p' \
      | sed -E 's/^((NOPASSWD|PASSWD|SETENV|NOSETENV|EXEC|NOEXEC|LOG_INPUT|LOG_OUTPUT):[ ]*)+//' \
      | tr ',' '\n' | sed -E 's/^ +//; s/ +$//' | sed '/^$/d'
}

ln_bin_dir() {      # directory holding the sudo-granted laranode-*.sh scripts
    local c
    while read -r c; do
        case "${c%% *}" in */laranode-*.sh) dirname "${c%% *}"; return 0 ;; esac
    done < <(ln_sudo_rules)
    return 1
}

ln_tpl_dir() {      # template dir = sibling of the script dir
    local b; b=$(ln_bin_dir) || return 1
    echo "$(cd "$b/.." && pwd)/templates"
}

# run a sudo'd script the way PHP does: as the web user, `sudo -n <script> args…`
# (RUNAS=www-data means "as the web user itself", whatever its name on this host)
ln_run() {          # ln_run script-basename args…   (RUNAS=root|www-data|direct)
    local s="$1"; shift
    local -a pre=(sudo -n)
    [ "${RUNAS:-root}" = www-data ] && pre=(sudo -n -u "$LN_WEB")
    [ "${RUNAS:-root}" = direct ] && pre=()   # no sudo at all: the script itself must refuse a non-root caller
    timeout 30 runuser -u "$LN_WEB" -- "${pre[@]}" "$(ln_bin_dir)/$s" "$@" </dev/null
}

# Everything a hostile call could damage, as one comparable string.
ln_snap() {
    {
        sha256sum /etc/shadow /etc/passwd /etc/group /etc/hostname /etc/sudoers 2>/dev/null
        stat -c '%n %U:%G %a' /tmp /var/tmp /home /var/spool /etc/hostname /etc/passwd /etc/shadow /etc/sudoers /etc/laranode-canary 2>/dev/null
        cat /etc/laranode-canary 2>/dev/null
        ls -la /etc/sudoers.d /etc/cron.d 2>/dev/null
        ls -la /etc/apache2/sites-available /etc/apache2/sites-enabled 2>/dev/null
        ls -la /etc/php/*/fpm/pool.d 2>/dev/null
        ls -la /etc/systemd/system 2>/dev/null | grep -i laranode
        ls -la /home 2>/dev/null
        # (the live panel on a real install writes its own storage/logs while the checks run)
        find /home -maxdepth 4 -newer /etc/laranode-canary 2>/dev/null | grep -v '/\.' \
            | grep -vE '^/home/laranode_ln/(panel/(storage|bootstrap)|logs)' | sort
        ls /tmp 2>/dev/null | grep -E '^pwned' 
        getent passwd | wc -l
    } 2>&1
}
