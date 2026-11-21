#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# laranode-ufw.sh status | status-numbered | show-added | enable | disable
# laranode-ufw.sh allow|deny <rule tokens...>
# laranode-ufw.sh delete <rule number | rule tokens...>
#
# The ONLY way the panel drives ufw. It replaces a blanket `NOPASSWD: /usr/sbin/ufw`,
# which let a compromised web user pass any option or sub-command. Here every rule
# token must be one of the ufw rule-grammar words, a port / port range / port/proto,
# an IP address or CIDR, or (as the only token) an application-profile name. Options
# (anything starting with "-") are never passed through; prompts are answered with
# --force by this script, so the PHP side needs no `yes |`.
ln_argc 1 20 "$0 {status|status-numbered|show-added|enable|disable|allow|deny|delete} [rule...]"

CMD=$1; shift
ln_rule_tokens() {   # validate "$@" as a ufw rule spec (1..16 tokens)
    local t
    [ $# -ge 1 ] && [ $# -le 16 ] || ln_die "invalid rule"
    for t in "$@"; do

        case "$t" in
            from|to|any|port|proto|tcp|udp|in|out) continue ;;
        esac
        [[ $t =~ ^[0-9]{1,5}(:[0-9]{1,5})?(/(tcp|udp))?$ ]] && continue
        [[ $t =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] && continue
        [[ $t == *:* && $t =~ ^[0-9A-Fa-f:]{2,39}(/[0-9]{1,3})?$ ]] && continue
        if [ $# -eq 1 ] && [[ $t =~ ^[A-Za-z][A-Za-z0-9._-]{0,31}$ ]]; then continue; fi
        ln_die "invalid rule token"
    done
    return 0
}

case "$CMD" in
    status)          ln_argc 1 1 "$0 status";           exec ufw status ;;
    status-numbered) ln_argc 1 1 "$0 status-numbered";  exec ufw status numbered ;;
    show-added)      ln_argc 1 1 "$0 show-added";       exec ufw show added ;;
    enable)          ln_argc 1 1 "$0 enable";           exec ufw --force enable ;;
    disable)         ln_argc 1 1 "$0 disable";          exec ufw --force disable ;;
    allow|deny)
        ln_argc 2 20 "$0 $CMD <rule...>"
        ln_rule_tokens "$@"
        exec ufw "$CMD" "$@" ;;
    delete)
        ln_argc 2 20 "$0 delete <number|rule...>"
        if [ $# -eq 1 ] && [[ $1 =~ ^[0-9]{1,4}$ ]]; then
            exec ufw --force delete "$1"
        fi
        case "$1" in allow|deny) : ;; *) ln_die "invalid rule" ;; esac
        ln_rule_tokens "${@:2}"
        exec ufw --force delete "$@" ;;
    *) ln_die "unknown command" ;;
esac
