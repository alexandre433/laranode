#!/bin/bash
#
# OS matrix for service sleep/wake: one build, proven on Ubuntu 24.04 AND Debian 13
# against real systemd + a real MySQL (Ubuntu) / MariaDB (Debian). SKYTOP-only (the repo
# has no CI); needs Docker. Uses throw-away containers, never touches a real host.
#
#   Run from Git Bash/WSL/PowerShell-with-bash at the repo root:
#       MSYS_NO_PATHCONV=1 bash tests/system/sleep/matrix.sh [ubuntu|debian|all]
#
# Each container needs: systemd as PID 1, mysql-server (ubuntu) / mariadb-server (debian),
# python3, iproute2. The default images used for the proof:
#   jrei/systemd-ubuntu:24.04  (+ apt install mysql-server)
#   jrei/systemd-debian:13     (+ apt install mariadb-server)
#
set -u
cd "$(dirname "$0")/../../.."
WHICH=${1:-all}
RC=0

declare -A IMG=( [ubuntu]=jrei/systemd-ubuntu:24.04 [debian]=jrei/systemd-debian:13 )
declare -A PKG=( [ubuntu]=mysql-server [debian]=mariadb-server )

run_one() {
    local os=$1 c="laranode-sleep-$1"
    echo "################ $os (${IMG[$os]}) ################"
    if ! docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
        docker run -d --name "$c" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /tmp --tmpfs /run --tmpfs /run/lock "${IMG[$os]}" >/dev/null || return 1
        sleep 5
        docker exec "$c" bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ${PKG[$os]} python3 iproute2 >/dev/null" || return 1
        sleep 3
    fi
    docker exec "$c" bash -c 'rm -rf /opt/ln-test && mkdir -p /opt/ln-test'
    tar -c laranode-scripts tests/system/sleep | docker exec -i "$c" tar -x -C /opt/ln-test
    docker exec "$c" bash -c 'chmod +x /opt/ln-test/laranode-scripts/bin/*.sh /opt/ln-test/tests/system/sleep/*.sh'
    docker exec "$c" /opt/ln-test/tests/system/sleep/inner.sh /opt/ln-test/laranode-scripts/bin
}

for os in ubuntu debian; do
    [ "$WHICH" = all ] || [ "$WHICH" = "$os" ] || continue
    run_one "$os" || RC=1
done
echo "################ matrix exit: $RC ################"
exit $RC
