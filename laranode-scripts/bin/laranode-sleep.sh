#!/bin/bash
#
# laranode-sleep.sh — the ONE privileged entry point for service sleep/wake.
#
#   Usage: laranode-sleep.sh <key> <action> [idle_minutes]
#     key     reverb | queue | hostdb | fpm        (fixed list, never a unit name)
#     action  enable | disable | wake | sleep
#     idle    integer 1..1440 (enable only; ignored by queue)
#
# Exit codes: 0 ok, 1 failed (rolled back), 2 bad arguments, 3 refused, 4 not privileged.
#
# Safety model (see docs/sleep-wake.md):
#   * Only services Laranode itself installed AND registered in the root-owned
#     registry /etc/laranode/managed.d/<key>.conf can be touched. No registry
#     file => refuse. Unit names come from the registry, never from arguments, and
#     must also match a per-key pattern, so a bad registry line cannot widen the scope.
#   * Pre-existing services on a host (e.g. a shared PostgreSQL, Redis, nginx) are
#     never registered, so they are never managed.
#   * The panel's own database is never put to sleep.
#   * Every enable is reversible: `disable` restores boot-enablement and running state.
#
set -uo pipefail
umask 022

EX_FAIL=1 EX_USAGE=2 EX_REFUSED=3 EX_PRIV=4

die() { local code=$1; shift; echo "ERROR: $*" >&2; exit "$code"; }

# --- test-mode overrides: honoured ONLY when not running through sudo -------------
MANAGED_DIR=/etc/laranode
SYSTEMD_DIR=/etc/systemd/system
PHP_ETC=/etc/php
AA_ENABLED=/sys/module/apparmor/parameters/enabled
AA_PROFILES=/sys/kernel/security/apparmor/profiles
TESTMODE=0
if [ "${LARANODE_SLEEP_TEST:-}" = 1 ] && [ -z "${SUDO_UID:-}" ]; then
    TESTMODE=1
    MANAGED_DIR=${LARANODE_MANAGED_DIR:-$MANAGED_DIR}
    SYSTEMD_DIR=${LARANODE_SYSTEMD_DIR:-$SYSTEMD_DIR}
    PHP_ETC=${LARANODE_PHP_ETC:-$PHP_ETC}
    # in test mode ONLY the injected files count, never the host the tests happen to run on
    AA_ENABLED=${LARANODE_AA_ENABLED:-/nonexistent/apparmor-enabled}
    AA_PROFILES=${LARANODE_AA_PROFILES:-/nonexistent/apparmor-profiles}
fi

# --- argument validation (before anything touches the system) ---------------------
[ $# -ge 2 ] && [ $# -le 3 ] || die $EX_USAGE "usage: $0 <reverb|queue|hostdb|fpm> <enable|disable|wake|sleep> [idle_minutes]"
KEY=$1
ACTION=$2
IDLE=${3-}
HAVE_IDLE=0
[ $# -eq 3 ] && HAVE_IDLE=1

case "$KEY" in
    reverb|queue|hostdb|fpm) ;;
    *) die $EX_USAGE "unknown key '$KEY' (allowed: reverb, queue, hostdb, fpm)" ;;
esac
case "$ACTION" in
    enable|disable|wake|sleep) ;;
    *) die $EX_USAGE "unknown action '$ACTION' (allowed: enable, disable, wake, sleep)" ;;
esac
if [ "$HAVE_IDLE" = 1 ]; then
    [ "$ACTION" = enable ] || die $EX_USAGE "idle minutes only valid with enable"
    [[ $IDLE =~ ^[1-9][0-9]{0,3}$ ]] && [ "$IDLE" -le 1440 ] || die $EX_USAGE "idle minutes must be an integer 1..1440"
fi
if [ "$ACTION" = enable ] && [ "$KEY" != queue ] && [ "$HAVE_IDLE" = 0 ]; then
    die $EX_USAGE "enable needs idle minutes (1..1440) for '$KEY'"
fi
if [ "$KEY" = fpm ] && { [ "$ACTION" = wake ] || [ "$ACTION" = sleep ]; }; then
    die $EX_USAGE "fpm has no manual wake/sleep (workers spawn on demand)"
fi

if [ "$(id -u)" != 0 ] && [ "$TESTMODE" != 1 ]; then
    die $EX_PRIV "must run as root (via the sudoers allowlist)"
fi

# --- escape the php-fpm sandbox ---------------------------------------------------
# The stock php-fpm unit runs with ProtectSystem=full, and a `sudo` child inherits that
# mount namespace: /etc (unit files, registry state, DB config) is READ-ONLY even for
# root. Re-run ourselves once as a transient unit owned by PID 1 (clean namespace).
# Same validated arguments, no environment carried over, and no extra sudoers rule:
# we are already root here.
if [ "$TESTMODE" != 1 ] && [ -z "${LARANODE_SLEEP_REEXEC:-}" ] && [ ! -w /etc/systemd/system ] \
    && command -v systemd-run >/dev/null 2>&1; then
    exec systemd-run --quiet --wait --pipe --collect --setenv=LARANODE_SLEEP_REEXEC=1 \
        -- "$(readlink -f "$0")" "$@"
fi

# --- registry gate ----------------------------------------------------------------
declare -A R=()
REG_FILE="$MANAGED_DIR/managed.d/$KEY.conf"
STATE_DIR="$MANAGED_DIR/sleep"
STATE_FILE="$STATE_DIR/$KEY.state"

[ -f "$REG_FILE" ] || die $EX_REFUSED "'$KEY' is not managed by Laranode (no registry entry): external services are never touched"

if [ "$TESTMODE" != 1 ]; then
    # registry must be root-owned and not writable by anyone else
    for p in "$REG_FILE" "$MANAGED_DIR/managed.d"; do
        read -r uid mode < <(stat -c '%u %a' "$p")
        [ "$uid" = 0 ] && [[ $mode =~ ^[0-7]*[0145][0145]$ ]] || die $EX_REFUSED "registry path $p is not root-owned/non-writable"
    done
fi

while IFS='=' read -r k v || [ -n "$k" ]; do
    k=${k//[[:space:]]/}
    case "$k" in ''|\#*) continue ;; esac
    [[ $k =~ ^[a-z_]+$ ]] || continue
    v=${v#"${v%%[![:space:]]*}"}
    v=${v%"${v##*[![:space:]]}"}
    R[$k]=$v
done < "$REG_FILE"

valid_unit() { [[ ${1-} =~ ^[A-Za-z0-9@:._-]+\.service$ ]]; }
valid_port() { [[ ${1-} =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_ipv4() { # dotted quad, each octet 0..255, no leading junk
    local o IFS=.
    [[ ${1-} =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    for o in $1; do [ "$((10#$o))" -le 255 ] || return 1; done
}
valid_path() { [[ ${1-} =~ ^/[A-Za-z0-9_./-]+$ ]] && [[ $1 != *..* ]]; }

KIND=${R[kind]-}
UNIT=${R[unit]-}

case "$KEY" in
    reverb)
        [ "$KIND" = reverb ] || die $EX_REFUSED "registry kind mismatch for reverb"
        [[ $UNIT =~ ^laranode-reverb\.service$ ]] || die $EX_REFUSED "registry unit '$UNIT' is not the Laranode Reverb unit"
        valid_port "${R[public_port]-}" || die $EX_REFUSED "registry public_port invalid"
        # The socket must listen exactly where Reverb itself listens (the installer binds it to
        # 127.0.0.1 on Proxmox/CloudPanel). A missing/odd value is refused, never widened.
        valid_ipv4 "${R[bind_host]-}" || die $EX_REFUSED "registry bind_host missing or invalid (re-run laranode-managed-register.sh)"
        ;;
    queue)
        [ "$KIND" = queue ] || die $EX_REFUSED "registry kind mismatch for queue"
        [[ $UNIT =~ ^laranode-queue-worker\.service$ ]] || die $EX_REFUSED "registry unit '$UNIT' is not the Laranode queue unit"
        ;;
    fpm)
        [ "$KIND" = fpm ] || die $EX_REFUSED "registry kind mismatch for fpm"
        ;;
    hostdb)
        [ "$KIND" = db ] || die $EX_REFUSED "registry kind mismatch for hostdb"
        case "${R[engine]-}" in
            mysql|mariadb) ;;
            postgres) die $EX_REFUSED "unsupported engine 'postgres': PostgreSQL peer-auth over the unix socket cannot be proxied safely" ;;
            *) die $EX_REFUSED "unsupported or missing engine" ;;
        esac
        [[ $UNIT =~ ^(mysql|mariadb|mysqld)\.service$ ]] || die $EX_REFUSED "registry unit '$UNIT' is not a MySQL/MariaDB unit"
        valid_port "${R[public_port]-}" || die $EX_REFUSED "registry public_port invalid"
        valid_path "${R[public_socket]-}" || die $EX_REFUSED "registry public_socket invalid"
        valid_path "${R[cnf_dir]-}" || die $EX_REFUSED "registry cnf_dir invalid"
        ;;
esac

# --- installer manifest gate (defence in depth) -----------------------------------
# The installer records, per service, whether Laranode installed it (managed:true) or
# found it already running (managed:false). When that manifest exists it is the source
# of truth: a registry entry the manifest does not back is refused. FAIL CLOSED: no manifest =
# nothing can prove Laranode installed the service, so nothing is touched (re-run the installer,
# which writes the manifest and re-registers).
MANIFEST="$MANAGED_DIR/service-manifest.json"
# Exception: `disable` of a key whose root-owned state says sleep is ON. It only restores the
# originals (registry-gated above), so a deleted manifest, or a service that flipped to
# managed:false on an installer re-run, must never trap a service asleep. Everything that turns
# sleep on or pokes the service stays fail closed.
RESTORE_ONLY=0
if [ "$ACTION" = disable ] && [ -f "$STATE_FILE" ] && grep -qx 'enabled=1' "$STATE_FILE" 2>/dev/null; then RESTORE_ONLY=1; fi
if [ "$RESTORE_ONLY" != 1 ]; then
[ -f "$MANIFEST" ] || die $EX_REFUSED "service manifest $MANIFEST is missing: cannot prove Laranode installed '$KEY' (re-run the Laranode installer)"
{
    if [ "$TESTMODE" != 1 ]; then
        read -r muid mmode < <(stat -c '%u %a' "$MANIFEST")
        [ "$muid" = 0 ] && [[ $mmode =~ ^[0-7]*[0145][0145]$ ]] || die $EX_REFUSED "service manifest $MANIFEST is not root-owned/non-writable"
    fi
    case "$KEY" in
        reverb) MROLE=reverb ;;
        queue) MROLE=queue ;;
        fpm) MROLE=php ;;
        hostdb) MROLE=database ;;
    esac
    grep -F '"managed":true' "$MANIFEST" | grep -qF "\"role\":\"$MROLE\"" \
        || die $EX_REFUSED "service manifest does not list a Laranode-installed '$MROLE' service (managed:true): external services are never touched"
    if [ "$KEY" = hostdb ]; then
        MDB=$(grep -F '"managed":true' "$MANIFEST" | grep -F '"role":"database"' | sed -n 's/.*"unit":"\([^"]*\)".*/\1/p' | head -1)
        [[ $MDB =~ ^(mysql|mariadb|mysqld)\.service$ ]] \
            || die $EX_REFUSED "service manifest database unit '$MDB' is not a Laranode-installed MySQL/MariaDB"
    fi
}
fi

# --- state helpers ----------------------------------------------------------------
declare -A S=()
load_state() {
    S=()
    [ -f "$STATE_FILE" ] || return 0
    while IFS='=' read -r k v || [ -n "$k" ]; do
        [[ $k =~ ^[a-z_]+$ ]] && S[$k]=$v
    done < "$STATE_FILE"
}
write_state() { # args: key=value ...
    mkdir -p "$STATE_DIR"
    local tmp
    tmp=$(mktemp "$STATE_DIR/.$KEY.XXXXXX") || return 1
    printf '%s\n' "$@" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$STATE_FILE"
}
is_enabled() { load_state; [ "${S[enabled]-}" = 1 ]; }

sc() { systemctl "$@"; }

write_unit() { # path ; content on stdin
    mkdir -p "$(dirname "$1")"
    cat > "$1"
    chmod 644 "$1"
}

PROXYD=/usr/lib/systemd/systemd-socket-proxyd
[ -x "$PROXYD" ] || { [ -x /lib/systemd/systemd-socket-proxyd ] && PROXYD=/lib/systemd/systemd-socket-proxyd; }
require_proxyd() { [ -x "$PROXYD" ] || [ "$TESTMODE" = 1 ] || die $EX_REFUSED "systemd-socket-proxyd not found on this host"; }

fragment_execstart() { # unit -> original ExecStart (from the distro/main unit file, not drop-ins)
    local frag line
    frag=$(sc show -p FragmentPath --value "$1" 2>/dev/null)
    [ -n "$frag" ] && [ -f "$frag" ] || die $EX_REFUSED "unit file for $1 not found"
    line=$(grep -m1 '^ExecStart=' "$frag") || die $EX_REFUSED "no ExecStart in $1"
    printf '%s' "${line#ExecStart=}"
}

port_free() { # port
    command -v ss >/dev/null 2>&1 || return 0
    [ -z "$(ss -Hltn "sport = :$1" 2>/dev/null)" ]
}
pick_backend_port() { # preferred -> free loopback port
    local p
    if [ -n "${S[backend_port]-}" ] && valid_port "${S[backend_port]}"; then printf '%s' "${S[backend_port]}"; return; fi
    p=$((${R[public_port]:-8080} + 10000))
    [ "$p" -gt 65000 ] && p=20000
    while ! port_free "$p"; do p=$((p + 1)); done
    printf '%s' "$p"
}

wait_active() { # unit seconds
    local i
    for ((i = 0; i < $2 * 5; i++)); do
        sc is-active "$1" >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    return 1
}
wait_inactive() {
    local i
    for ((i = 0; i < $2 * 5; i++)); do
        sc is-active "$1" >/dev/null 2>&1 || return 0
        sleep 0.2
    done
    return 1
}
poke_tcp() { # port : opening a connection to the proxy socket wakes the real service
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# panel-DB guard: does the panel's own database live on the hosting engine's instance?
panel_db_same_instance() {
    local env=${R[panel_env]:-/home/laranode_ln/panel/.env} conn='' host='' port='' sock='' k v
    valid_path "$env" || return 0
    [ -r "$env" ] || return 0   # cannot prove it is separate -> treat as same (refuse)
    while IFS='=' read -r k v || [ -n "$k" ]; do
        v=${v%\"}; v=${v#\"}; v=${v%\'}; v=${v#\'}
        case "$k" in
            DB_CONNECTION) conn=$v ;; DB_HOST) host=$v ;; DB_PORT) port=$v ;; DB_SOCKET) sock=$v ;;
        esac
    done < "$env"
    [ -n "$conn" ] || return 0          # unknown -> refuse
    case "$conn" in mysql|mariadb) ;; *) return 1 ;; esac  # sqlite/pgsql/other: different instance
    [ -n "$sock" ] && [ "$sock" = "${R[public_socket]-}" ] && return 0
    case "$host" in ''|localhost|127.0.0.1|::1) ;; *) return 1 ;; esac
    [ -z "$port" ] && port=3306
    [ "$port" = "${R[public_port]-}" ]
}
guard_hostdb() {
    if panel_db_same_instance; then
        die $EX_REFUSED "cannot sleep: the panel database lives on this database instance (it must stay up)"
    fi
}

# AppArmor: Ubuntu ships an enforced profile for mysqld that only allows /run/mysqld/*. Hosting-DB
# sleep moves the real server socket to /run/laranode-hostdb/, which that profile denies, so the
# database would fail to start on the first wake. We never rewrite security policy from this script:
# refuse instead. Only a profile in a DENYING mode matters (enforce, kill, prompt; complain logs and never denies). AppArmor
# enabled but the profile list unreadable = cannot prove it is safe = refuse.
apparmor_blocks_hostdb() {
    local en=""
    [ -r "$AA_ENABLED" ] && en=$(tr -d "[:space:]" < "$AA_ENABLED" 2>/dev/null)
    [ "$en" = Y ] || return 1
    [ -r "$AA_PROFILES" ] || return 0
    grep -Eq '(^|/)(mysqld|mariadbd)[[:space:]]+[(](enforce|kill|prompt)[)]$' "$AA_PROFILES" 2>/dev/null
}
guard_apparmor() {
    if apparmor_blocks_hostdb; then
        die $EX_REFUSED "cannot sleep: an enforced AppArmor profile for mysqld/mariadbd is active; it would deny the moved database socket and the database would not start on wake. Hosting-DB sleep stays off on this host."
    fi
}

# =====================================================================================
# generic: record prior boot/run state once, restore on disable/rollback
# =====================================================================================
record_prior() { # unit : sets PRIOR_ENABLED / PRIOR_ACTIVE (only first enable keeps real values)
    load_state
    if [ -n "${S[was_enabled]-}" ]; then
        PRIOR_ENABLED=${S[was_enabled]}; PRIOR_ACTIVE=${S[was_active]:-no}
    else
        sc is-enabled "$1" >/dev/null 2>&1 && PRIOR_ENABLED=yes || PRIOR_ENABLED=no
        sc is-active "$1" >/dev/null 2>&1 && PRIOR_ACTIVE=yes || PRIOR_ACTIVE=no
    fi
}
restore_prior() { # unit
    [ "${PRIOR_ENABLED-no}" = yes ] && sc enable "$1" >/dev/null 2>&1
    [ "${PRIOR_ACTIVE-no}" = yes ] && sc start "$1" >/dev/null 2>&1
    return 0
}

# files created by the current enable, for rollback
CREATED=()
put() { # path ; stdin
    CREATED+=("$1")
    write_unit "$1"
}
rollback_files() {
    local f
    for f in "${CREATED[@]:-}"; do [ -n "$f" ] && rm -f "$f"; done
    rmdir "$SYSTEMD_DIR/${UNIT}.d" 2>/dev/null || true
    sc daemon-reload >/dev/null 2>&1 || true
}

# =====================================================================================
# reverb / hostdb : socket + proxyd + StopWhenUnneeded
# =====================================================================================
proxy_socket() { echo "laranode-sleep-$KEY.socket"; }
proxy_service() { echo "laranode-sleep-$KEY.service"; }

remove_proxy_files() {
    rm -f "$SYSTEMD_DIR/$(proxy_socket)" "$SYSTEMD_DIR/$(proxy_service)" \
          "$SYSTEMD_DIR/$UNIT.d/laranode-sleep.conf"
    rmdir "$SYSTEMD_DIR/$UNIT.d" 2>/dev/null || true
}

disable_proxied() {
    load_state
    [ "${S[enabled]-}" = 1 ] || { echo "sleep already off for $KEY"; return 0; }
    PRIOR_ENABLED=${S[was_enabled]:-no}; PRIOR_ACTIVE=${S[was_active]:-no}
    sc disable --now "$(proxy_socket)" >/dev/null 2>&1
    sc stop "$(proxy_service)" >/dev/null 2>&1
    sc stop "$UNIT" >/dev/null 2>&1
    remove_proxy_files
    [ "$KEY" = hostdb ] && rm -f "${R[cnf_dir]}/zz-laranode-sleep.cnf"
    sc daemon-reload >/dev/null 2>&1
    restore_prior "$UNIT"
    rm -f "$STATE_FILE"
    echo "sleep off for $KEY: restored $UNIT (enabled=$PRIOR_ENABLED active=$PRIOR_ACTIVE)"
}

enable_reverb() {
    require_proxyd
    local exec_line backend
    exec_line=$(fragment_execstart "$UNIT")
    [[ $exec_line =~ ^/usr/bin/php[0-9.]*\ [A-Za-z0-9_./-]+/artisan\ reverb:start$ ]] \
        || die $EX_REFUSED "unexpected Reverb ExecStart; refusing to rewrite it"
    load_state
    backend=$(pick_backend_port)
    record_prior "$UNIT"

    put "$SYSTEMD_DIR/$(proxy_socket)" <<EOF
[Unit]
Description=Laranode sleep: public socket for Reverb (a connection wakes it)

[Socket]
ListenStream=${R[bind_host]}:${R[public_port]}

[Install]
WantedBy=sockets.target
EOF
    put "$SYSTEMD_DIR/$(proxy_service)" <<EOF
[Unit]
Description=Laranode sleep: Reverb proxy (exits when idle)
Requires=$UNIT
After=$UNIT

[Service]
DynamicUser=yes
NoNewPrivileges=yes
ExecStart=$PROXYD --exit-idle-time=${IDLE}min 127.0.0.1:$backend
EOF
    put "$SYSTEMD_DIR/$UNIT.d/laranode-sleep.conf" <<EOF
[Unit]
StopWhenUnneeded=yes

[Service]
ExecStart=
ExecStart=$exec_line --host=127.0.0.1 --port=$backend
ExecStartPost=/bin/bash -c 'for i in \$(seq 1 100); do (exec 3<>/dev/tcp/127.0.0.1/$backend) 2>/dev/null && exit 0; sleep 0.1; done; exit 1'
EOF
    activate_proxied "$backend"
}

enable_hostdb() {
    require_proxyd
    guard_hostdb
    guard_apparmor
    local priv=/run/laranode-hostdb/mysqld.sock
    [ "$(sc show -p Id --value "$UNIT" 2>/dev/null)" = "$UNIT" ] \
        || die $EX_REFUSED "registry unit $UNIT is an alias; re-register the canonical unit"
    load_state
    record_prior "$UNIT"

    put "${R[cnf_dir]}/zz-laranode-sleep.cnf" <<EOF
# Managed by Laranode sleep mode (laranode-sleep.sh hostdb). Removed on disable.
[mysqld]
skip-networking
socket=$priv
EOF
    put "$SYSTEMD_DIR/$(proxy_socket)" <<EOF
[Unit]
Description=Laranode sleep: public sockets for the hosting database (a connection wakes it)

[Socket]
ListenStream=127.0.0.1:${R[public_port]}
ListenStream=${R[public_socket]}
SocketMode=0666

[Install]
WantedBy=sockets.target
EOF
    put "$SYSTEMD_DIR/$(proxy_service)" <<EOF
[Unit]
Description=Laranode sleep: hosting database proxy (exits when idle)
Requires=$UNIT
After=$UNIT

[Service]
DynamicUser=yes
NoNewPrivileges=yes
ExecStart=$PROXYD --exit-idle-time=${IDLE}min $priv
EOF
    put "$SYSTEMD_DIR/$UNIT.d/laranode-sleep.conf" <<EOF
[Unit]
StopWhenUnneeded=yes

[Service]
RuntimeDirectory=
RuntimeDirectory=laranode-hostdb
RuntimeDirectoryMode=0755
ExecStartPost=/bin/bash -c 'for i in \$(seq 1 300); do [ -S $priv ] && exit 0; sleep 0.1; done; exit 1'
EOF
    activate_proxied ""
}

activate_proxied() { # backend port (reverb) or ""
    local backend=$1
    {
        sc daemon-reload &&
        sc disable "$UNIT" >/dev/null 2>&1; true
    }
    # A re-enable (installer re-run) may rewrite the socket unit with a NEW port/bind host while the
    # old socket is still active: `enable --now` would leave it listening on the stale address.
    # Stop socket + proxy first so the fresh unit is what actually binds.
    sc stop "$(proxy_socket)" "$(proxy_service)" >/dev/null 2>&1
    if ! { sc stop "$UNIT" >/dev/null 2>&1; sc enable --now "$(proxy_socket)" >/dev/null 2>&1; }; then
        echo "enable failed; rolling back" >&2
        sc disable --now "$(proxy_socket)" >/dev/null 2>&1
        rollback_files
        restore_prior "$UNIT"
        rm -f "$STATE_FILE"
        exit $EX_FAIL
    fi
    write_state enabled=1 "idle_minutes=$IDLE" "was_enabled=$PRIOR_ENABLED" "was_active=$PRIOR_ACTIVE" ${backend:+"backend_port=$backend"} || die $EX_FAIL "cannot write state"
    echo "sleep on for $KEY (idle ${IDLE}min)"
}

wake_proxied() {
    [ "$KEY" = hostdb ] && { guard_hostdb; guard_apparmor; }
    is_enabled || die $EX_REFUSED "sleep is not enabled for $KEY"
    poke_tcp "${R[public_port]}" || die $EX_FAIL "could not connect to the $KEY socket"
    wait_active "$UNIT" 90 || die $EX_FAIL "$UNIT did not come up"
    echo "$KEY awake"
}
sleep_proxied() {
    [ "$KEY" = hostdb ] && guard_hostdb
    is_enabled || die $EX_REFUSED "sleep is not enabled for $KEY"
    sc stop "$(proxy_service)" >/dev/null 2>&1
    sc stop "$UNIT" >/dev/null 2>&1
    wait_inactive "$UNIT" 90 || die $EX_FAIL "$UNIT did not stop"
    echo "$KEY asleep"
}

# =====================================================================================
# queue : stop-when-empty worker woken by a 30 s timer (+ explicit wake on dispatch)
# =====================================================================================
enable_queue() {
    local exec_line new_exec
    exec_line=$(fragment_execstart "$UNIT")
    [[ $exec_line =~ ^/usr/bin/php[0-9.]*\ [A-Za-z0-9_./-]+/artisan\ queue:work(\ [A-Za-z0-9=:_.,-]+)*$ ]] \
        || die $EX_REFUSED "unexpected queue ExecStart; refusing to rewrite it"
    new_exec=$exec_line
    [[ $exec_line == *--stop-when-empty* ]] || new_exec="$new_exec --stop-when-empty"
    [[ $exec_line == *--max-time=* ]] || new_exec="$new_exec --max-time=300"
    record_prior "$UNIT"

    put "$SYSTEMD_DIR/laranode-sleep-queue.timer" <<EOF
[Unit]
Description=Laranode sleep: start the queue worker every 30s (it exits when the queue is empty)

[Timer]
OnBootSec=30s
OnUnitInactiveSec=30s
Unit=$UNIT

[Install]
WantedBy=timers.target
EOF
    put "$SYSTEMD_DIR/$UNIT.d/laranode-sleep.conf" <<EOF
[Service]
ExecStart=
ExecStart=$new_exec
Restart=no
EOF
    sc daemon-reload
    sc disable "$UNIT" >/dev/null 2>&1
    sc stop "$UNIT" >/dev/null 2>&1   # SIGTERM: the worker finishes its current job first
    if ! sc enable --now laranode-sleep-queue.timer >/dev/null 2>&1; then
        echo "enable failed; rolling back" >&2
        rollback_files
        restore_prior "$UNIT"
        rm -f "$STATE_FILE"
        exit $EX_FAIL
    fi
    write_state enabled=1 "was_enabled=$PRIOR_ENABLED" "was_active=$PRIOR_ACTIVE" || die $EX_FAIL "cannot write state"
    echo "sleep on for queue (wake on dispatch or within 30s)"
}
disable_queue() {
    load_state
    [ "${S[enabled]-}" = 1 ] || { echo "sleep already off for queue"; return 0; }
    PRIOR_ENABLED=${S[was_enabled]:-no}; PRIOR_ACTIVE=${S[was_active]:-no}
    sc disable --now laranode-sleep-queue.timer >/dev/null 2>&1
    rm -f "$SYSTEMD_DIR/laranode-sleep-queue.timer" "$SYSTEMD_DIR/$UNIT.d/laranode-sleep.conf"
    rmdir "$SYSTEMD_DIR/$UNIT.d" 2>/dev/null
    sc daemon-reload >/dev/null 2>&1
    restore_prior "$UNIT"
    rm -f "$STATE_FILE"
    echo "sleep off for queue"
}

# =====================================================================================
# fpm : pm=ondemand for Laranode pools (*_ln.conf) only, byte-exact restore
# =====================================================================================
FPM_ORIG_DIR="$STATE_DIR/fpm"

fpm_pools() { # prints "version<TAB>path"
    local d ver f
    for d in "$PHP_ETC"/*/fpm/pool.d; do
        [ -d "$d" ] || continue
        ver=$(basename "$(dirname "$(dirname "$d")")")
        [[ $ver =~ ^[0-9]+\.[0-9]+$ ]] || continue
        for f in "$d"/*_ln.conf; do
            [ -f "$f" ] && printf '%s\t%s\n' "$ver" "$f"
        done
    done
}
fpm_orig_path() { printf '%s/%s__%s.orig' "$FPM_ORIG_DIR" "$1" "$(basename "$2")"; }

fpm_apply() { # ver file idle
    local ver=$1 f=$2 idle=$3 orig tmp pmline
    orig=$(fpm_orig_path "$ver" "$f")
    mkdir -p "$FPM_ORIG_DIR"
    pmline=$(grep -m1 -E '^pm[[:space:]]*=' "$f") || return 0   # no pm line: leave alone
    if [ ! -f "$orig" ]; then
        local has_idle=no
        grep -qE '^pm\.process_idle_timeout[[:space:]]*=' "$f" && has_idle=yes
        { echo "pm_line=$pmline"; echo "had_idle=$has_idle"; } > "$orig"
        chmod 644 "$orig"
    fi
    local had_idle
    had_idle=$(sed -n 's/^had_idle=//p' "$orig")
    tmp=$(mktemp)
    awk -v idle="$idle" -v had="$had_idle" '
        /^pm\.process_idle_timeout = [0-9]+m$/ && had == "no" { next }   # our earlier line
        /^pm[[:space:]]*=/ && !done { print "pm = ondemand"; if (had == "no") print "pm.process_idle_timeout = " idle "m"; done = 1; next }
        { print }
    ' "$f" > "$tmp" && cat "$tmp" > "$f"
    rm -f "$tmp"
}
fpm_restore() { # ver file
    local ver=$1 f=$2 orig tmp pmline had_idle
    orig=$(fpm_orig_path "$ver" "$f")
    [ -f "$orig" ] || return 0
    pmline=$(sed -n 's/^pm_line=//p' "$orig")
    had_idle=$(sed -n 's/^had_idle=//p' "$orig")
    tmp=$(mktemp)
    awk -v pm="$pmline" -v had="$had_idle" '
        /^pm\.process_idle_timeout = [0-9]+m$/ && had == "no" { next }
        /^pm = ondemand$/ && !done { print pm; done = 1; next }
        { print }
    ' "$f" > "$tmp" && cat "$tmp" > "$f"
    rm -f "$tmp" "$orig"
}
fpm_reload() { # versions...
    local ver
    for ver in "$@"; do
        if [ "$TESTMODE" != 1 ] && command -v "php-fpm$ver" >/dev/null 2>&1 && ! "php-fpm$ver" -t >/dev/null 2>&1; then
            echo "php-fpm$ver config test failed; not reloading" >&2
            return 1
        fi
        # A missing/inactive php-fpm unit is not an error: nothing to reload, the new
        # pool config is picked up when the unit next starts.
        sc reload "php${ver}-fpm" >/dev/null 2>&1 || true
    done
    return 0
}
enable_fpm() {
    local ver f seen=" "
    local -a vers=()
    while IFS=$'\t' read -r ver f; do
        fpm_apply "$ver" "$f" "$IDLE"
        case "$seen" in *" $ver "*) ;; *) seen="$seen$ver "; vers+=("$ver") ;; esac
    done < <(fpm_pools)
    if ! fpm_reload "${vers[@]}"; then
        while IFS=$'\t' read -r ver f; do fpm_restore "$ver" "$f"; done < <(fpm_pools)
        rm -f "$STATE_FILE"
        exit $EX_FAIL
    fi
    write_state enabled=1 "idle_minutes=$IDLE" || die $EX_FAIL "cannot write state"
    echo "sleep on for fpm: ${#vers[@]} version(s), idle ${IDLE}m"
}
disable_fpm() {
    local ver f seen=" " vers=()
    load_state
    [ "${S[enabled]-}" = 1 ] || { echo "sleep already off for fpm"; return 0; }
    while IFS=$'\t' read -r ver f; do
        fpm_restore "$ver" "$f"
        case "$seen" in *" $ver "*) ;; *) seen="$seen$ver "; vers+=("$ver") ;; esac
    done < <(fpm_pools)
    fpm_reload "${vers[@]}"
    rm -f "$STATE_FILE"
    rmdir "$FPM_ORIG_DIR" 2>/dev/null
    echo "sleep off for fpm"
}

# =====================================================================================
# dispatch
# =====================================================================================
case "$KEY:$ACTION" in
    reverb:enable)  enable_reverb ;;
    reverb:disable) disable_proxied ;;
    reverb:wake)    wake_proxied ;;
    reverb:sleep)   sleep_proxied ;;

    hostdb:enable)  enable_hostdb ;;
    hostdb:disable) disable_proxied ;;
    hostdb:wake)    wake_proxied ;;
    hostdb:sleep)   sleep_proxied ;;

    queue:enable)   enable_queue ;;
    queue:disable)  disable_queue ;;
    queue:wake)
        is_enabled || die $EX_REFUSED "sleep is not enabled for queue"
        sc start --no-block "$UNIT" ;;
    queue:sleep)
        is_enabled || die $EX_REFUSED "sleep is not enabled for queue"
        sc stop "$UNIT" ;;

    fpm:enable)     enable_fpm ;;
    fpm:disable)    disable_fpm ;;
    *) die $EX_USAGE "unsupported combination $KEY $ACTION" ;;
esac
