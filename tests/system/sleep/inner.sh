#!/bin/bash
#
# System-level proof of service sleep/wake against REAL systemd + a real MySQL/MariaDB.
# Runs INSIDE a throw-away systemd container (see matrix.sh). Never run this on a real host:
# it installs stand-in units, changes the database socket layout and stops services.
#
# Usage (inside container, as root): inner.sh <laranode-scripts/bin dir>
#
set -u
BIN=${1:?scripts bin dir}
SLEEP="$BIN/laranode-sleep.sh"
REGISTER="$BIN/laranode-managed-register.sh"
PANEL=/home/laranode_ln/panel
UNITS=/etc/systemd/system
FAILS=0
CREATED=()

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }
check() { # name, command...
    local name=$1; shift
    if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
snapshot() {
    {
        find "$UNITS" /etc/php /etc/mysql -type f 2>/dev/null | sort | xargs -r md5sum 2>/dev/null
        find "$UNITS" -type l 2>/dev/null | sort | while read -r l; do echo "link $l -> $(readlink "$l")"; done
        for u in laranode-reverb.service laranode-queue-worker.service "$DBUNIT"; do echo "enabled $u $(systemctl is-enabled "$u" 2>&1)"; done
    } | grep -v '/etc/laranode' | md5sum | cut -d' ' -f1
}
owner_of_port() { ss -ltnp "sport = :$1" 2>/dev/null | grep -o 'users:.*' | head -1; }
rss_db() { ps -o rss= -C mysqld,mariadbd 2>/dev/null | awk '{s+=$1} END{print s+0}'; }
http_get() { python3 - "$1" <<'PY'
import sys, urllib.request
print(urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/", timeout=30).status)
PY
}
run() { "$@" >/tmp/ln-last.out 2>&1; echo $?; }

echo "=== host: $(. /etc/os-release; echo "$PRETTY_NAME")"

# ─── fixtures (stand-ins for what the Laranode installer lays down) ───────────────
[ -x /usr/bin/php8.4 ] || {
    cat > /usr/bin/php8.4 <<'PHP'
#!/bin/bash
# stand-in for `php artisan ...`
shift
case "$1" in
  reverb:start)
    host=0.0.0.0; port=8080
    for a in "$@"; do case $a in --host=*) host=${a#--host=};; --port=*) port=${a#--port=};; esac; done
    sleep 1   # simulated boot: the bind happens late (the race ExecStartPost must cover)
    exec python3 -m http.server "$port" --bind "$host" ;;
  queue:work) echo "run $(date +%s)" >> /tmp/ln-queue-runs; exit 0 ;;
esac
PHP
    chmod 755 /usr/bin/php8.4; CREATED+=(/usr/bin/php8.4)
}
id laranode_ln >/dev/null 2>&1 || { useradd -m laranode_ln; CREATED+=(user:laranode_ln); }
mkdir -p "$PANEL" && printf 'DB_CONNECTION=sqlite\nREVERB_SERVER_PORT=8080\n' > "$PANEL/.env"
cp "$BIN/../templates/laranode-reverb.service" "$UNITS/laranode-reverb.service"
cp "$BIN/../templates/laranode-queue-worker.service" "$UNITS/laranode-queue-worker.service"
mkdir -p /etc/php/8.4/fpm/pool.d
printf '[alice_ln]\nuser = alice_ln\npm = dynamic\npm.max_children = 5\n' > /etc/php/8.4/fpm/pool.d/alice_ln.conf
printf '[www]\nuser = www-data\npm = dynamic\n' > /etc/php/8.4/fpm/pool.d/www.conf
printf '[clouddeploy]\nuser = www-data\npm = dynamic\n' > /etc/php/8.4/fpm/pool.d/clouddeploy.conf
systemctl daemon-reload
systemctl enable --now laranode-reverb.service >/dev/null 2>&1

CLI=$(command -v mariadb || command -v mysql)
DUMP=$(command -v mariadb-dump || command -v mysqldump)
DBUNIT=$(systemctl show -p Id --value mariadb.service 2>/dev/null); [ "$(systemctl cat mariadb.service >/dev/null 2>&1; echo $?)" = 0 ] || DBUNIT=mysql.service
systemctl is-active "$DBUNIT" >/dev/null 2>&1 || systemctl start "$DBUNIT"
$CLI -e "create database if not exists spikedb; create user if not exists 'spk'@'127.0.0.1' identified by 'pw'; create user if not exists 'spk'@'localhost' identified by 'pw'; grant all on spikedb.* to 'spk'@'127.0.0.1'; grant all on spikedb.* to 'spk'@'localhost'; create table if not exists spikedb.t(a int); delete from spikedb.t; insert into spikedb.t values (1);"
echo "db unit: $DBUNIT  cli: $CLI"

# a pre-existing service Laranode did NOT install (stands in for DS's shared PostgreSQL / Redis)
cat > "$UNITS/ln-decoy-external.service" <<'EOF'
[Service]
ExecStart=/bin/sleep infinity
EOF
systemctl daemon-reload && systemctl start ln-decoy-external.service

LARANODE_DB_INSTALLED_BY_US=1 bash "$REGISTER" reverb queue fpm hostdb
echo "--- registry:"; head -20 /etc/laranode/managed.d/*.conf

# ─── 0. installer manifest is the source of truth (real root, real systemctl) ─────
MF=/etc/laranode/service-manifest.json
write_manifest() { # php-managed(true|false)
    printf '{"version":1,"services":[\n{"unit":"laranode-reverb.service","managed":true,"role":"reverb","reason":"t"},\n{"unit":"laranode-queue-worker.service","managed":true,"role":"queue","reason":"t"},\n{"unit":"php8.4-fpm.service","managed":%s,"role":"php","reason":"t"},\n{"unit":"%s","managed":true,"role":"database","reason":"t"}\n]}\n' "$1" "$DBUNIT" > "$MF"
    chmod 644 "$MF"
}
write_manifest false
check "manifest: pre-existing php-fpm (managed:false) -> fpm enable refused (exit 3)" test "$(run "$SLEEP" fpm enable 1)" = 3
mv /etc/laranode/managed.d/fpm.conf /tmp/fpm.conf.bak
bash "$REGISTER" fpm >/dev/null 2>&1
check "manifest: register skips a pre-existing php-fpm" test ! -e /etc/laranode/managed.d/fpm.conf
mv /tmp/fpm.conf.bak /etc/laranode/managed.d/fpm.conf
write_manifest true
check "manifest: managed:true php-fpm -> fpm gate passes (disable is a clean no-op, exit 0)" test "$(run "$SLEEP" fpm disable)" = 0
rm -f /etc/laranode/managed.d/hostdb.conf; bash "$REGISTER" hostdb >/dev/null 2>&1
check "manifest: register derives hostdb from the manifest database unit (no env flag needed)" grep -q "^unit=$DBUNIT\$" /etc/laranode/managed.d/hostdb.conf

# ─── 1. toggle OFF = no change to the system ─────────────────────────────────────
BASE=$(snapshot)
for k in reverb queue hostdb fpm; do
    check "toggle off ($k): disable is a clean no-op" test "$(run "$SLEEP" "$k" disable)" = 0
done
check "toggle off: units/pools/enablement byte-identical" test "$(snapshot)" = "$BASE"
check "toggle off: public port 8080 still owned by the real service, not systemd" bash -c "! ss -ltnp 'sport = :8080' | grep -q '\"systemd\"'"

# ─── 2. safety: refusals ─────────────────────────────────────────────────────────
for bad in postgresql 'postgresql@16-main' redis-server nginx mysql sshd 'reverb;id' laranode-reverb.service; do
    check "unknown key '$bad' refused (exit 2)" test "$(run "$SLEEP" "$bad" enable 1)" = 2
done
check "unknown action refused (exit 2)" test "$(run "$SLEEP" reverb restart 1)" = 2
check "bad idle refused (exit 2)" test "$(run "$SLEEP" reverb enable 0)" = 2

cp /etc/laranode/managed.d/reverb.conf /tmp/reverb.conf.bak
printf 'kind=reverb\nunit=redis-server.service\npublic_port=6379\n' > /etc/laranode/managed.d/reverb.conf
check "registry naming a pre-existing unit (redis-server) is refused" test "$(run "$SLEEP" reverb enable 1)" = 3
cp /tmp/reverb.conf.bak /etc/laranode/managed.d/reverb.conf

mv /etc/laranode/managed.d/hostdb.conf /tmp/hostdb.conf.bak
check "pre-existing DB not in registry: refused (exit 3, not managed)" test "$(run "$SLEEP" hostdb enable 1)" = 3
check "…and the message says so" grep -q 'not managed' /tmp/ln-last.out
mv /tmp/hostdb.conf.bak /etc/laranode/managed.d/hostdb.conf

printf 'DB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_PORT=3306\n' > "$PANEL/.env"
check "panel DB on the same instance: hostdb enable refused (exit 3)" test "$(run "$SLEEP" hostdb enable 1)" = 3
check "…message says cannot sleep" grep -q 'cannot sleep' /tmp/ln-last.out
check "…database untouched (still active, no proxy units)" bash -c "systemctl is-active $DBUNIT >/dev/null && [ ! -e $UNITS/laranode-sleep-hostdb.socket ]"
printf 'DB_CONNECTION=sqlite\nREVERB_SERVER_PORT=8080\n' > "$PANEL/.env"

# ─── 3. reverb + hostdb: socket owns the port, idle stop, wake on connect ─────────
RSS_AWAKE=$(rss_db)
check "reverb enable 1min" test "$(run "$SLEEP" reverb enable 1)" = 0
check "hostdb enable 1min" test "$(run "$SLEEP" hostdb enable 1)" = 0
sleep 1
check "reverb: socket (systemd) owns :8080" bash -c "ss -ltnp 'sport = :8080' | grep -q systemd"
check "reverb: real unit asleep after enable" bash -c "! systemctl is-active laranode-reverb.service >/dev/null"
check "reverb: real unit not wanted at boot any more" bash -c "! systemctl is-enabled laranode-reverb.service >/dev/null 2>&1"
check "hostdb: socket (systemd) owns TCP :3306" bash -c "ss -ltnp 'sport = :3306' | grep -q systemd"
check "hostdb: socket (systemd) owns the canonical unix socket" bash -c "ss -lxp | grep -q 'mysqld.sock.*systemd\|mysqld.sock.*users:((\"systemd\"'  || ss -lx | grep -q mysqld.sock"
check "hostdb: database process gone (RAM freed)" test "$(rss_db)" = 0
echo "METRIC db_rss_awake_kb=$RSS_AWAKE db_rss_asleep_kb=$(rss_db)"

t0=$(now_ms); code=$(http_get 8080 2>/dev/null); t1=$(now_ms)
check "reverb: connect wakes it (HTTP $code)" test "$code" = 200
echo "METRIC reverb_wake_ms=$((t1 - t0))"
check "reverb: real unit active after wake" systemctl is-active --quiet laranode-reverb.service

t0=$(now_ms); n=$($CLI -h127.0.0.1 -P3306 -uspk -ppw -N -e 'select count(*) from spikedb.t' 2>/tmp/ln-dberr); t1=$(now_ms)
check "hostdb: TCP connect wakes it and returns data" test "$n" = 1
echo "METRIC db_tcp_wake_ms=$((t1 - t0))  rss_awake_again_kb=$(rss_db)"

check "hostdb: manual sleep" test "$(run "$SLEEP" hostdb sleep)" = 0
check "hostdb: db down after manual sleep" bash -c "! systemctl is-active $DBUNIT >/dev/null"
$DUMP -h127.0.0.1 -P3306 -uspk -ppw spikedb > /tmp/ln-backup.sql 2>/tmp/ln-dberr
check "backup while asleep: dump wakes the DB and succeeds" grep -q 'CREATE TABLE' /tmp/ln-backup.sql
SOCKPATH=$(awk -F= '/^public_socket=/{print $2}' /etc/laranode/managed.d/hostdb.conf)
t0=$(now_ms); n=$($CLI -S "$SOCKPATH" -uspk -ppw -N -e 'select count(*) from spikedb.t' 2>/dev/null); t1=$(now_ms)
check "hostdb: unix-socket client (canonical path) works" test "$n" = 1
echo "METRIC db_unix_ms=$((t1 - t0))"

check "reverb: manual sleep" test "$(run "$SLEEP" reverb sleep)" = 0
check "reverb: down after manual sleep" bash -c "! systemctl is-active laranode-reverb.service >/dev/null"
check "reverb: manual wake" test "$(run "$SLEEP" reverb wake)" = 0
check "reverb: up after manual wake" systemctl is-active --quiet laranode-reverb.service

# idle: both must stop on their own (idle=1min). poll up to 150 s
http_get 8080 >/dev/null 2>&1; $CLI -h127.0.0.1 -uspk -ppw -e 'select 1' >/dev/null 2>&1   # reset idle clocks
T0=$(date +%s); R=0; D=0
while [ $(( $(date +%s) - T0 )) -lt 150 ]; do
    systemctl is-active --quiet laranode-reverb.service || R=1
    systemctl is-active --quiet "$DBUNIT" || D=1
    [ $R = 1 ] && [ $D = 1 ] && break
    sleep 3
done
echo "METRIC idle_stop_after_s=$(( $(date +%s) - T0 ))"
check "reverb: stops itself after idle" test $R = 1
check "hostdb: stops itself after idle" test $D = 1
check "decoy external service untouched through all of it" systemctl is-active --quiet ln-decoy-external.service

# ─── 4. queue ────────────────────────────────────────────────────────────────────
rm -f /tmp/ln-queue-runs
check "queue enable" test "$(run "$SLEEP" queue enable)" = 0
check "queue: timer active" systemctl is-active --quiet laranode-sleep-queue.timer
check "queue: worker not wanted at boot" bash -c "! systemctl is-enabled laranode-queue-worker.service >/dev/null 2>&1"
check "queue: drop-in uses --stop-when-empty" grep -q 'stop-when-empty' "$UNITS/laranode-queue-worker.service.d/laranode-sleep.conf"
check "queue wake runs the worker" bash -c "$SLEEP queue wake >/dev/null 2>&1; sleep 2; test -s /tmp/ln-queue-runs"
check "queue disable restores enablement" bash -c "$SLEEP queue disable >/dev/null 2>&1; systemctl is-enabled laranode-queue-worker.service >/dev/null 2>&1; [ ! -e $UNITS/laranode-sleep-queue.timer ]"

# ─── 5. fpm: only laranode pools, byte-exact restore ─────────────────────────────
PD=/etc/php/8.4/fpm/pool.d
H=$(md5sum $PD/*.conf | md5sum)
check "fpm enable" test "$(run "$SLEEP" fpm enable 2)" = 0
check "fpm: laranode pool is ondemand" grep -q '^pm = ondemand' $PD/alice_ln.conf
check "fpm: foreign pools (www, clouddeploy) byte-identical" bash -c "grep -q '^pm = dynamic' $PD/www.conf && grep -q '^pm = dynamic' $PD/clouddeploy.conf && ! grep -q ondemand $PD/www.conf $PD/clouddeploy.conf"
check "fpm disable restores every pool byte-for-byte" bash -c "$SLEEP fpm disable >/dev/null 2>&1; [ \"\$(md5sum $PD/*.conf | md5sum)\" = \"$H\" ]"

# ─── 6. everything off again = original system ───────────────────────────────────
for k in reverb hostdb; do check "disable $k" test "$(run "$SLEEP" "$k" disable)" = 0; done
sleep 1
check "full cycle leaves units/pools/enablement byte-identical" test "$(snapshot)" = "$BASE"
check "db awake and usable after disable" test "$($CLI -h127.0.0.1 -uspk -ppw -N -e 'select count(*) from spikedb.t' 2>/dev/null)" = 1
check "decoy external service still untouched" systemctl is-active --quiet ln-decoy-external.service

# ─── 7. php-fpm sandbox: the panel runs us under ProtectSystem=full (/etc read-only) ───
# systemd-run -p ProtectSystem=full reproduces what a sudo child of php-fpm inherits.
SANDBOX="systemd-run --quiet --wait --pipe --collect -p ProtectSystem=full --"
check "sandbox really is read-only (precondition)" bash -c "! $SANDBOX /bin/touch /etc/systemd/system/ln-probe"
check "fpm sandbox: reverb enable works (self re-exec escapes the read-only /etc)" bash -c "$SANDBOX $SLEEP reverb enable 1 >/tmp/ln-sbx.out 2>&1"
check "fpm sandbox: socket owns :8080 afterwards" bash -c "sleep 1; ss -ltnp 'sport = :8080' | grep -q systemd"
check "fpm sandbox: refusal exit code is preserved through the re-exec (unknown action => 2)" bash -c "$SANDBOX $SLEEP reverb restart 1 >/dev/null 2>&1; [ \$? = 2 ]"
check "fpm sandbox: reverb disable works" bash -c "$SANDBOX $SLEEP reverb disable >/tmp/ln-sbx.out 2>&1"
sleep 1
check "fpm sandbox: full cycle leaves units/pools/enablement byte-identical" test "$(snapshot)" = "$BASE"

# ─── cleanup ─────────────────────────────────────────────────────────────────────
systemctl stop ln-decoy-external.service; rm -f "$UNITS/ln-decoy-external.service"
$CLI -e "drop user if exists 'spk'@'127.0.0.1'; drop user if exists 'spk'@'localhost'; drop database if exists spikedb" 2>/dev/null
rm -rf /etc/php/8.4 /etc/laranode "$PANEL" /tmp/ln-*
for c in "${CREATED[@]:-}"; do case "$c" in user:*) userdel -r "${c#user:}" 2>/dev/null ;; ?*) rm -f "$c" ;; esac; done
rm -f "$UNITS/laranode-reverb.service" "$UNITS/laranode-queue-worker.service"; systemctl daemon-reload

echo "=== RESULT: $FAILS failure(s)"
exit $((FAILS > 0))
