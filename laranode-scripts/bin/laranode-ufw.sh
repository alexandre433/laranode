#!/bin/bash
set -euo pipefail

# laranode-ufw.sh <subcommand> [args...]
# Allowlisted wrapper around /usr/sbin/ufw for www-data.
#
# Replaces the old unrestricted `www-data ... NOPASSWD: /usr/sbin/ufw` grant so
# the panel can only run status reads and stage allow/deny rules from the
# vocabulary its own UI emits, plus delete a numbered rule. `ufw reset`,
# `ufw default` and flag injection (e.g. --force) never reach the binary.
# Called via sudo by app/Actions/Firewall/* — keep the subcommand list and the
# rule-token grammar in sync with BuildUfwRuleSpecAction and
# SafeSetupFirewallAction.

UFW_BIN=/usr/sbin/ufw

# Validate a single allow/deny rule token. Exits 1 when the token is outside the
# vocabulary the panel emits (see BuildUfwRuleSpecAction / SafeSetupFirewallAction),
# so no ufw flag or extra subcommand can be smuggled through.
validate_rule_token() {
    TOKEN="$1"

    case "$TOKEN" in -*) echo "ERROR: invalid rule token (leading dash not allowed): $TOKEN" >&2; exit 1 ;; esac

    # Keywords emitted by BuildUfwRuleSpecAction / SafeSetupFirewallAction
    case "$TOKEN" in
        in|out|proto|from|to|port|any|tcp|udp) return 0 ;;
    esac

    # <port>/<tcp|udp> shorthand — e.g. 22/tcp (SafeSetupFirewallAction)
    if [[ "$TOKEN" =~ ^[1-9][0-9]{0,4}/(tcp|udp)$ ]]; then
        if [ "${TOKEN%%/*}" -gt 65535 ]; then
            echo "ERROR: port out of range: $TOKEN" >&2
            exit 1
        fi
        return 0
    fi

    # bare port — e.g. `... port 80` (BuildUfwRuleSpecAction)
    if [[ "$TOKEN" =~ ^[1-9][0-9]{0,4}$ ]]; then
        if [ "$TOKEN" -gt 65535 ]; then
            echo "ERROR: port out of range: $TOKEN" >&2
            exit 1
        fi
        return 0
    fi

    # host — IPv4 or IPv6, optionally /CIDR (BuildUfwRuleSpecAction ip/to)
    if [[ "$TOKEN" =~ ^(([0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-fA-F:]*:[0-9a-fA-F:]*)(/[0-9]{1,3})?$ ]]; then
        return 0
    fi

    echo "ERROR: invalid rule token '$TOKEN'. Allowed: in|out|proto|from|to|port|any|tcp|udp, <port>/<tcp|udp>, <port>, or an IP address." >&2
    exit 1
}

# ---- arg validation ----
if [ $# -lt 1 ]; then
    echo "Usage: $0 {status|status-numbered|show-added|allow|deny|delete|enable|disable} [args...]" >&2
    exit 1
fi

SUBCMD="$1"
shift

# Reject leading-dash subcommands (flag injection)
case "$SUBCMD" in -*) echo "ERROR: invalid subcommand (leading dash not allowed): $SUBCMD" >&2; exit 1 ;; esac

# ---- dispatch ----
case "$SUBCMD" in
    status)
        [ $# -eq 0 ] || { echo "ERROR: 'status' takes no arguments" >&2; exit 1; }
        exec "$UFW_BIN" status
        ;;
    status-numbered)
        [ $# -eq 0 ] || { echo "ERROR: 'status-numbered' takes no arguments" >&2; exit 1; }
        exec "$UFW_BIN" status numbered
        ;;
    show-added)
        [ $# -eq 0 ] || { echo "ERROR: 'show-added' takes no arguments" >&2; exit 1; }
        exec "$UFW_BIN" show added
        ;;
    allow|deny)
        [ $# -ge 1 ] || { echo "ERROR: '$SUBCMD' requires a rule spec" >&2; exit 1; }
        for TOKEN in "$@"; do
            validate_rule_token "$TOKEN"
        done
        exec "$UFW_BIN" "$SUBCMD" "$@"
        ;;
    delete)
        [ $# -eq 1 ] || { echo "Usage: $0 delete <rule-number>" >&2; exit 1; }
        RULE_NUMBER="$1"
        case "$RULE_NUMBER" in -*) echo "ERROR: invalid rule number (leading dash not allowed): $RULE_NUMBER" >&2; exit 1 ;; esac
        if ! echo "$RULE_NUMBER" | grep -qE '^[1-9][0-9]{0,5}$'; then
            echo "ERROR: invalid rule number '$RULE_NUMBER'. Must be a numeric rule id." >&2
            exit 1
        fi
        exec "$UFW_BIN" --force delete "$RULE_NUMBER"
        ;;
    enable)
        [ $# -eq 0 ] || { echo "ERROR: 'enable' takes no arguments" >&2; exit 1; }
        exec "$UFW_BIN" --force enable
        ;;
    disable)
        [ $# -eq 0 ] || { echo "ERROR: 'disable' takes no arguments" >&2; exit 1; }
        exec "$UFW_BIN" --force disable
        ;;
    *)
        echo "ERROR: unknown subcommand '$SUBCMD'. Allowed: status, status-numbered, show-added, allow, deny, delete, enable, disable" >&2
        exit 1
        ;;
esac
