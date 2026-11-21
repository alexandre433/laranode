#!/usr/bin/env bash
# Scenario: rerun-sleep — re-running the installer on a host where service sleep/wake is ON.
#
# A re-run re-copies the unit templates and `enable`s + `start`s reverb and the queue worker
# (phase_services). Without care that (a) wakes everything an admin put to sleep and re-enables
# it at boot, and (b) leaves each sleep drop-in pinned to the OLD ExecStart. The installer's
# _reassert_sleep_wake re-applies `laranode-sleep.sh <key> enable <idle>` for every key whose
# state says enabled=1. Asserts, after the SECOND run:
#   1. the installer exits 0 both times
#   2. Reverb is asleep: real unit inactive + not enabled at boot, the sleep socket owns its port
#   3. the drop-in was re-rendered (a deliberately stale ExecStart planted between the runs is gone)
#   4. the queue timer is active and the queue worker is not enabled at boot
#   5. a connect to the Reverb port still wakes it (clients unaffected)
#   6. `disable` restores the ORIGINAL state: both units enabled at boot again, Reverb running
#
# Standalone (does not use run_scenario): run_scenario's baseline asserts "reverb active",
# which is by design false while Reverb sleeps.
set -uo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CACHE="${LARANODE_COMPOSER_CACHE:-$HOME/.cache/laranode-it-composer}"
mkdir -p "$CACHE" 2>/dev/null || true
C=laranode-install-test-rerun-sleep
IMG="${IMAGE:-jrei/systemd-ubuntu:24.04}"
KEEP="${KEEP:-0}"
INSTALLER="bash /home/laranode_ln/panel/laranode-scripts/bin/laranode-installer.sh"
ENVV="LARANODE_APP_URL=http://laranode.example.com LARANODE_UNATTENDED=1 LARANODE_HTTP_PORT=80"
SLEEP_SH=/home/laranode_ln/panel/laranode-scripts/bin/laranode-sleep.sh
FAILS=0

cleanup() { [ "$KEEP" = 1 ] || docker rm -f "$C" >/dev/null 2>&1 || true; }
die() { echo "FAIL[rerun-sleep]: $1" >&2; cleanup; exit 1; }
d() { docker exec "$C" bash -c "$1"; }
check() { # name, in-container command
    if docker exec "$C" bash -c "$2" >/dev/null 2>&1; then printf '   %-66s PASS\n' "$1"; else printf '   %-66s FAIL\n' "$1"; FAILS=$((FAILS + 1)); fi
}

docker rm -f "$C" >/dev/null 2>&1 || true
echo "[rerun-sleep][1/5] Booting $IMG with systemd..."
docker run -d --name "$C" --privileged --cgroupns=host --cap-add NET_ADMIN --cap-add NET_RAW \
    --stop-signal SIGRTMIN+3 -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v "$REPO":/src:ro \
    -v "$CACHE":/composer-cache --tmpfs /run --tmpfs /run/lock --tmpfs /tmp "$IMG" >/dev/null || die "container did not start"
for _ in $(seq 1 30); do
    case "$(docker exec "$C" systemctl is-system-running 2>/dev/null || true)" in running|degraded|starting) break ;; esac
    sleep 2
done

echo "[rerun-sleep][2/5] Injecting working tree..."
d 'mkdir -p /home/laranode_ln/panel && tar -C /src --exclude=./vendor --exclude=./node_modules --exclude=./.git --exclude=./public/build --exclude=./.env -cf - . | tar -C /home/laranode_ln/panel -xf - && rm -f /home/laranode_ln/panel/bootstrap/cache/*.php' || die "repo injection failed"

TOKEN="${LARANODE_GH_TOKEN:-$(gh auth token 2>/dev/null || true)}"
ENVARGS=(-e COMPOSER_CACHE_DIR=/composer-cache)
[ -n "$TOKEN" ] && ENVARGS+=(-e "COMPOSER_AUTH={\"github-oauth\":{\"github.com\":\"${TOKEN}\"}}")

echo "[rerun-sleep][3/5] First installer run, then switch Reverb + queue sleep ON..."
docker exec "${ENVARGS[@]}" "$C" bash -c "$ENVV $INSTALLER" || die "first installer run failed"
d "[ \"\$($SLEEP_SH reverb enable 1 >/tmp/rs.out 2>&1; echo \$?)\" = 0 ] && [ \"\$($SLEEP_SH queue enable >>/tmp/rs.out 2>&1; echo \$?)\" = 0 ]" || { d 'cat /tmp/rs.out'; die "could not enable sleep after the first run"; }
RPORT=$(d "awk -F= '/^public_port=/{print \$2}' /etc/laranode/managed.d/reverb.conf" | tr -d '[:space:]')
echo "   reverb public port: $RPORT"
DROPIN=/etc/systemd/system/laranode-reverb.service.d/laranode-sleep.conf
check "precondition: Reverb asleep after enabling, socket owns :$RPORT" "! systemctl is-active --quiet laranode-reverb.service && ss -ltnp 'sport = :$RPORT' | grep -q systemd"
# plant a stale pinned ExecStart: what an older template/PHP version would have left behind
d "sed -i 's|^ExecStart=/usr/bin/php8.4 |ExecStart=/usr/bin/php8.4 -d memory_limit=-1 |' $DROPIN && systemctl daemon-reload" || die "could not plant the stale drop-in"
check "precondition: stale ExecStart planted" "grep -q 'memory_limit=-1' $DROPIN"

echo "[rerun-sleep][4/5] SECOND installer run with sleep ON..."
docker exec "${ENVARGS[@]}" "$C" bash -c "$ENVV $INSTALLER" || die "second installer run failed"

echo "[rerun-sleep][5/5] Assertions..."
# The installer re-picks the Reverb port on every run (8080 can turn into 8081 once the first
# run's own sleep socket holds it). Sleep must follow the registry, so re-read it.
RPORT2=$(d "awk -F= '/^public_port=/{print \$2}' /etc/laranode/managed.d/reverb.conf" | tr -d '[:space:]')
echo "   reverb public port after re-run: $RPORT2 (was $RPORT)"
RPORT="$RPORT2"
check "reverb: real unit asleep again (the re-run's start did not leave it awake)" "! systemctl is-active --quiet laranode-reverb.service"
check "reverb: not enabled at boot (the re-run's enable was undone)" "! systemctl is-enabled --quiet laranode-reverb.service"
check "reverb: sleep socket owns :$RPORT" "ss -ltnp 'sport = :$RPORT' | grep -q systemd"
check "reverb: drop-in re-rendered, stale ExecStart gone" "! grep -q 'memory_limit=-1' $DROPIN && grep -q -- '--port=[0-9]' $DROPIN"
check "reverb: drop-in ExecStart is the NEW unit's ExecStart + loopback backend" "base=\$(grep -m1 '^ExecStart=' /etc/systemd/system/laranode-reverb.service | sed 's/^ExecStart=//'); grep -qF \"ExecStart=\$base --host=127.0.0.1 --port=\" $DROPIN"
check "queue: sleep timer active" "systemctl is-active --quiet laranode-sleep-queue.timer"
check "queue: worker not enabled at boot" "! systemctl is-enabled --quiet laranode-queue-worker.service"
check "queue: drop-in still uses --stop-when-empty" "grep -q 'stop-when-empty' /etc/systemd/system/laranode-queue-worker.service.d/laranode-sleep.conf"
check "reverb clients unaffected: a connect to :$RPORT wakes it" "code=\$(curl -s -o /dev/null -m 30 -w '%{http_code}' http://127.0.0.1:$RPORT/ || true); [ \"\$code\" != 000 ] && systemctl is-active --quiet laranode-reverb.service"
check "panel itself still serves /login" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://localhost:80/login)\" = 200 ]"
MF=/etc/laranode/service-manifest.json
check "manifest gone: wake stays refused (fail closed)" "mv $MF /tmp/mf.bak && [ \"\$($SLEEP_SH reverb wake >/dev/null 2>&1; echo \$?)\" = 3 ]"
check "manifest gone: disable reverb + queue STILL works (never trapped asleep)" "$SLEEP_SH reverb disable && $SLEEP_SH queue disable; rc=\$?; mv /tmp/mf.bak $MF; [ \$rc = 0 ]"
check "disable restores the original state: reverb enabled at boot and running" "systemctl is-enabled --quiet laranode-reverb.service && systemctl is-active --quiet laranode-reverb.service"
check "disable restores the original state: queue worker enabled at boot" "systemctl is-enabled --quiet laranode-queue-worker.service"
check "disable leaves no sleep units behind" "[ ! -e /etc/systemd/system/laranode-sleep-reverb.socket ] && [ ! -e /etc/systemd/system/laranode-sleep-queue.timer ] && [ ! -e $DROPIN ]"

if [ "$FAILS" -eq 0 ]; then echo "PASS[rerun-sleep]"; cleanup; exit 0; fi
echo "FAIL[rerun-sleep]: $FAILS check(s) failed" >&2
[ "$KEEP" = 1 ] && echo "(container kept: docker exec -it $C bash)" >&2
cleanup
exit 1
