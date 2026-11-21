#!/usr/bin/env bash
# Scenario: Proxmox-like host (Debian 13 + /etc/pve marker + ufw present but unmanaged).
# Mimics the pve host target: panel must bind 127.0.0.1 only, never touch ufw,
# put the PostgreSQL data directory on the chosen disk, and not take 8006/3128/443.
set -euo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCENARIO_DIR}/../lib.sh"

export SCENARIO="pve"
export IMAGE="jrei/systemd-debian:13"
# Proxmox marker + a stand-in "Proxmox UI" on :8006 + a stand-in "tailscale serve" on
# :443 (nginx), plus ufw INSTALLED so we can prove it is never enabled or edited.
export PRESETUP='
    apt-get update -q >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y --quiet nginx ufw >/dev/null 2>&1
    mkdir -p /etc/pve /srv/hdd-test
    cat > /etc/nginx/conf.d/pve-standin.conf <<NGX
server { listen 8006; location / { return 200 "PVE_UI_8006\n"; } }
server { listen 3128; location / { return 200 "PVE_SPICE_3128\n"; } }
NGX
    # nginx default site holds :80 on Debian: free it so the panel can take :80 (127.0.0.1)
    rm -f /etc/nginx/sites-enabled/default
    systemctl restart nginx
    ufw show added > /root/ufw.before 2>&1 || true
    ufw status > /root/ufw.status.before 2>&1 || true
'
export INSTALLER_ENV="LARANODE_UNATTENDED=1 LARANODE_PG_DATADIR=/srv/hdd-test/pgdata"
export EXPECT_PORT=80
export EXPECT_ENGINE=pgsql

export POST_ASSERTS_CMD='
    # panel reachable on loopback only
    ss -tlnH "( sport = :80 )" | awk "{print \$4}" | grep -qx "127.0.0.1:80" \
        || { echo "FAIL: panel not bound to 127.0.0.1:80" >&2; ss -tlnH >&2; exit 1; }
    ss -tlnH "( sport = :80 )" | awk "{print \$4}" | grep -qE "^(0\.0\.0\.0|\*|\[::\]):80$" \
        && { echo "FAIL: :80 also listening on a wildcard address" >&2; exit 1; }
    echo "PASS: panel bound to 127.0.0.1:80 only"
    # Reverb must not be reachable from outside either
    ss -tlnH "( sport = :8080 )" | awk "{print \$4}" | grep -qx "127.0.0.1:8080" \
        || { echo "FAIL: reverb not bound to 127.0.0.1:8080" >&2; ss -tlnH >&2; exit 1; }
    echo "PASS: reverb bound to 127.0.0.1:8080"
    # protected ports untouched
    [ "$(curl -s --max-time 5 http://127.0.0.1:8006/)" = "PVE_UI_8006" ] || { echo "FAIL: :8006 stand-in changed" >&2; exit 1; }
    [ "$(curl -s --max-time 5 http://127.0.0.1:3128/)" = "PVE_SPICE_3128" ] || { echo "FAIL: :3128 stand-in changed" >&2; exit 1; }
    echo "PASS: :8006 and :3128 untouched"
    # ufw: not enabled, no rule added
    ufw show added > /root/ufw.after 2>&1 || true
    diff -q /root/ufw.before /root/ufw.after >/dev/null || { echo "FAIL: ufw rules changed" >&2; diff /root/ufw.before /root/ufw.after >&2; exit 1; }
    ufw status | grep -q "Status: inactive" || { echo "FAIL: ufw got enabled" >&2; exit 1; }
    echo "PASS: ufw untouched and inactive"
    # data directory on the chosen disk
    dd=$(sudo -u postgres psql -At -c "SHOW data_directory;")
    case "$dd" in /srv/hdd-test/pgdata/*) echo "PASS: PG data_directory=$dd";; *) echo "FAIL: data_directory=$dd" >&2; exit 1;; esac
    # Apache holds no 443 listener
    ss -tlnp "( sport = :443 )" | grep -q apache2 && { echo "FAIL: apache took :443" >&2; exit 1; }
    echo "PASS: apache not on :443"
'

run_scenario
