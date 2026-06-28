#!/usr/bin/env bash
# Shared run_scenario function consumed by every scenario script.
# Source this file; do not execute directly.
#
# Inputs (via env before sourcing):
#   SCENARIO        (required) short name used in container/log labels
#   PRESETUP        bash snippet executed INSIDE container after tree injection,
#                   BEFORE the installer — may be empty
#   INSTALLER_ENV   space-separated VAR=VAL assignments prefixed to the installer
#                   invocation (default: LARANODE_UNATTENDED=1)
#   EXPECT_PORT     HTTP port to assert /login on (default: 80)
#   EXPECT_ENGINE   mysql | pgsql — controls which DB service is asserted
#                   (default: mysql)
#   KEEP            1 = leave container after run for manual inspection (default: 0)

set -uo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

_LIB_IMAGE=jrei/systemd-ubuntu:24.04
_LIB_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

run_scenario() {
    local scenario="${SCENARIO:?SCENARIO env var must be set}"
    local presetup="${PRESETUP:-}"
    local installer_env="${INSTALLER_ENV:-LARANODE_UNATTENDED=1}"
    local expect_port="${EXPECT_PORT:-80}"
    local expect_engine="${EXPECT_ENGINE:-mysql}"
    local keep="${KEEP:-0}"
    local cname="laranode-install-test-${scenario}"

    _cleanup() {
        [ "$keep" = 1 ] || docker rm -f "$cname" >/dev/null 2>&1 || true
    }
    _fail() {
        echo "FAIL[$scenario]: $1" >&2
        if [ "$keep" = 1 ]; then
            echo "(container kept — inspect with: docker exec -it $cname bash)" >&2
        fi
        _cleanup
        exit 1
    }

    # Remove any leftover container from a previous interrupted run
    docker rm -f "$cname" >/dev/null 2>&1 || true

    echo "[$scenario][1/6] Booting $_LIB_IMAGE with systemd..."
    # Preserve all flags from the original run.sh exactly:
    docker run -d --name "$cname" --privileged --cgroupns=host \
        --cap-add NET_ADMIN --cap-add NET_RAW --stop-signal SIGRTMIN+3 \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        -v "$_LIB_REPO":/src:ro \
        --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
        "$_LIB_IMAGE" >/dev/null || _fail "container did not start"

    # Wait for systemd to reach a stable state (running/degraded/starting)
    for _ in $(seq 1 30); do
        state=$(docker exec "$cname" systemctl is-system-running 2>/dev/null || true)
        case "$state" in running|degraded|starting) break ;; esac
        sleep 2
    done

    echo "[$scenario][2/6] Injecting working tree (no vendor/node_modules/.git/build/.env)..."
    docker exec "$cname" mkdir -p /home/laranode_ln/panel
    docker exec "$cname" bash -c \
        'tar -C /src \
            --exclude=./vendor --exclude=./node_modules --exclude=./.git \
            --exclude=./public/build --exclude=./.env \
            --exclude=./.env.local-backup \
            -cf - . | tar -C /home/laranode_ln/panel -xf -' \
        || _fail "repo injection failed"
    # Drop any stale cached config from the host so the fresh .env actually takes effect
    docker exec "$cname" bash -c \
        'rm -f /home/laranode_ln/panel/bootstrap/cache/*.php' || true

    if [ -n "$presetup" ]; then
        echo "[$scenario][3/6] Running PRESETUP..."
        docker exec "$cname" bash -c "$presetup" || _fail "PRESETUP failed"
    else
        echo "[$scenario][3/6] PRESETUP: (none)"
    fi

    echo "[$scenario][4/6] Running installer (env: $installer_env)..."
    # Composer reliability (test-harness only — no effect on the production
    # installer's behavior): anonymous downloads from codeload.github.com
    # intermittently return HTTP/2 400 under rate limiting, flaking the
    # clean-room `composer install`. Authenticate composer with the host's
    # GitHub token (gh CLI or $LARANODE_GH_TOKEN) so requests use the 5000/hr
    # authenticated limit instead of 60/hr anonymous; also force HTTP/1.1.
    # The token is read at runtime, passed via `docker exec -e` (never written
    # to disk or committed), and is optional — empty falls back to anonymous.
    local _gh_token="${LARANODE_GH_TOKEN:-$(gh auth token 2>/dev/null || true)}"
    local -a _composer_env=(-e COMPOSER_DISABLE_HTTP2=1)
    if [ -n "$_gh_token" ]; then
        _composer_env+=(-e "COMPOSER_AUTH={\"github-oauth\":{\"github.com\":\"${_gh_token}\"}}")
    fi
    docker exec "${_composer_env[@]}" "$cname" bash -c \
        "$installer_env bash /home/laranode_ln/panel/laranode-scripts/bin/laranode-installer.sh" \
        || _fail "installer exited non-zero"

    echo "[$scenario][5/6] Seeding admin account..."
    docker exec "$cname" bash -lc \
        'cd /home/laranode_ln/panel && php artisan tinker --execute='\''
            App\Models\User::updateOrCreate(
                ["username" => "laranode"],
                ["name" => "Admin", "email" => "admin@laranode.test",
                 "password" => bcrypt("password"), "role" => "admin",
                 "ssh_access" => true, "email_verified_at" => now()]
            );
        '\''' \
        || _fail "admin seeding failed"

    echo "[$scenario][6/6] Assertions..."
    local ok=1

    # --- Always-required services ---
    for svc in apache2 php8.4-fpm laranode-reverb laranode-queue-worker; do
        st=$(docker exec "$cname" systemctl is-active "$svc" 2>/dev/null || echo inactive)
        printf "   %-32s %s\n" "$svc" "$st"
        [ "$st" = active ] || ok=0
    done

    # --- Engine-specific DB service ---
    if [ "$expect_engine" = pgsql ]; then
        pg=$(docker exec "$cname" bash -c \
            'systemctl is-active postgresql@16-main 2>/dev/null \
             || systemctl is-active postgresql 2>/dev/null \
             || echo inactive')
        printf "   %-32s %s\n" "postgresql" "$pg"
        [ "$pg" = active ] || ok=0
    else
        st=$(docker exec "$cname" systemctl is-active mysql 2>/dev/null || echo inactive)
        printf "   %-32s %s\n" "mysql" "$st"
        [ "$st" = active ] || ok=0
    fi

    # --- HTTP check on expected port ---
    code=$(docker exec "$cname" \
        curl -s -o /dev/null -w '%{http_code}' \
        "http://localhost:${expect_port}/login" 2>/dev/null || echo 000)
    printf "   %-32s %s\n" "GET :${expect_port}/login" "$code"
    [ "$code" = 200 ] || ok=0

    # --- Admin login check ---
    login=$(docker exec "$cname" bash -lc \
        'cd /home/laranode_ln/panel && php artisan tinker --execute='\''
            echo Illuminate\Support\Facades\Auth::attempt(
                ["email" => "admin@laranode.test", "password" => "password"]
            ) ? "yes" : "no";
        '\''' 2>/dev/null | tail -1)
    printf "   %-32s %s\n" "admin login" "$login"
    echo "$login" | grep -q yes || ok=0

    if [ "$ok" = 1 ]; then
        echo "RESULT[$scenario]: PASS"
        _cleanup
        return 0
    else
        echo "RESULT[$scenario]: FAIL — one or more assertions above did not pass"
        [ "$keep" = 1 ] && echo "(container kept for inspection)"
        _cleanup
        return 1
    fi
}
