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
#   IMAGE           systemd base image (default: jrei/systemd-ubuntu:24.04;
#                   Debian scenarios use jrei/systemd-debian:13)
#   EXPECT_INSTALLER_FAIL  regex: the installer must refuse (non-zero, message matches)
#                   and POST_ASSERTS_CMD then checks nothing was changed
#   KEEP            1 = leave container after run for manual inspection (default: 0)

set -uo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

_LIB_IMAGE=jrei/systemd-ubuntu:24.04
_LIB_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Persistent composer cache shared across every clean-room run. Packages that
# download successfully once are reused forever, so a re-run only re-fetches the
# few that hit the codeload HTTP/2 400 flake — the matrix converges and speeds up
# over time instead of re-downloading ~150 packages per container.
_LIB_COMPOSER_CACHE="${LARANODE_COMPOSER_CACHE:-$HOME/.cache/laranode-it-composer}"
mkdir -p "$_LIB_COMPOSER_CACHE" 2>/dev/null || true

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

    echo "[$scenario][1/6] Booting ${IMAGE:-$_LIB_IMAGE} with systemd..."
    # Preserve all flags from the original run.sh exactly:
    docker run -d --name "$cname" --privileged --cgroupns=host \
        --cap-add NET_ADMIN --cap-add NET_RAW --stop-signal SIGRTMIN+3 \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        -v "$_LIB_REPO":/src:ro \
        -v "$_LIB_COMPOSER_CACHE":/composer-cache \
        --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
        "${IMAGE:-$_LIB_IMAGE}" >/dev/null || _fail "container did not start"

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
    # installer's behavior). codeload.github.com intermittently returns HTTP/2
    # 400 on dist (legacy.zip) downloads, and a single failure aborts the whole
    # `composer install`. Two mitigations:
    #   1) COMPOSER_CACHE_DIR -> the persistent /composer-cache mount, so a
    #      re-run only re-fetches packages that failed last time and converges.
    #   2) COMPOSER_AUTH from the host GitHub token (gh CLI or $LARANODE_GH_TOKEN)
    #      -> 5000/hr authenticated rate limit instead of 60/hr anonymous.
    # Token is read at runtime, passed via `docker exec -e` (never written to
    # disk or committed), and optional — empty falls back to anonymous.
    local _gh_token="${LARANODE_GH_TOKEN:-$(gh auth token 2>/dev/null || true)}"
    local -a _composer_env=(-e COMPOSER_CACHE_DIR=/composer-cache)
    if [ -n "$_gh_token" ]; then
        _composer_env+=(-e "COMPOSER_AUTH={\"github-oauth\":{\"github.com\":\"${_gh_token}\"}}")
    fi
    # EXPECT_INSTALLER_FAIL=<regex>: the installer must REFUSE (non-zero exit, message
    # matching the regex) and POST_ASSERTS_CMD must then show the host was not touched.
    if [ -n "${EXPECT_INSTALLER_FAIL:-}" ]; then
        local _out _rc=0
        _out=$(docker exec "${_composer_env[@]}" "$cname" bash -c \
            "$installer_env bash /home/laranode_ln/panel/laranode-scripts/bin/laranode-installer.sh" 2>&1) || _rc=$?
        printf '%s\n' "$_out" | tail -12
        [ "$_rc" -ne 0 ] || _fail "installer should have refused but exited 0"
        printf '%s\n' "$_out" | grep -qE "$EXPECT_INSTALLER_FAIL" \
            || _fail "refusal message did not match /${EXPECT_INSTALLER_FAIL}/"
        echo "[post] Installer refused as expected; checking the host was not touched..."
        if docker exec "$cname" bash -c "${POST_ASSERTS_CMD:-true}"; then
            echo "RESULT[$scenario]: PASS"; _cleanup; return 0
        fi
        _fail "post-assertion failed after the refusal"
    fi
    docker exec "${_composer_env[@]}" "$cname" bash -c \
        "$installer_env bash /home/laranode_ln/panel/laranode-scripts/bin/laranode-installer.sh" \
        || _fail "installer exited non-zero"

    echo "[$scenario][5/6] Seeding admin account..."
    docker exec "$cname" bash -lc \
        'cd /home/laranode_ln/panel && /usr/bin/php8.4 artisan tinker --execute='\''
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


    # --- Scheduler: cron daemon up + cron.d entry present and runnable ---
    st=$(docker exec "$cname" systemctl is-active cron 2>/dev/null || echo inactive)
    printf "   %-32s %s\n" "cron" "$st"
    [ "$st" = active ] || ok=0
    if docker exec "$cname" bash -c \
        'grep -qE "^\* \* \* \* \* laranode_ln /usr/bin/php8.4 /home/laranode_ln/panel/artisan schedule:run" /etc/cron.d/laranode-schedule \
         && sudo -u laranode_ln /usr/bin/php8.4 /home/laranode_ln/panel/artisan schedule:list >/dev/null 2>&1'; then
        printf "   %-32s %s\n" "scheduler cron.d + schedule:list" "ok"
    else
        printf "   %-32s %s\n" "scheduler cron.d + schedule:list" "MISSING"; ok=0
    fi

    # --- Service manifest: present, ours = managed:true ---
    if docker exec "$cname" bash -c \
        'mf=/etc/laranode/service-manifest.json; [ -f "$mf" ] \
         && grep -q "\"unit\":\"laranode-reverb.service\",\"managed\":true" "$mf" \
         && grep -q "\"unit\":\"laranode-queue-worker.service\",\"managed\":true" "$mf" \
         && grep -q "\"version\":1" "$mf"'; then
        printf "   %-32s %s\n" "service manifest" "ok"
    else
        printf "   %-32s %s\n" "service manifest" "MISSING/INVALID"; ok=0
    fi
    # --- Engine-specific DB service ---
    if [ "$expect_engine" = pgsql ]; then
        # Any version/cluster name (16/main on Ubuntu 24.04, 17/main on Debian 13):
        # count clusters pg_lsclusters reports online.
        n=$(docker exec "$cname" bash -c \
            'pg_lsclusters --no-header 2>/dev/null | awk "\$4==\"online\"{n++} END{print n+0}"' \
            2>/dev/null || echo 0)
        pg=inactive; [ "${n:-0}" -ge 1 ] && pg=active
        printf "   %-32s %s (%s online)\n" "postgresql" "$pg" "${n:-0}"
        [ "$pg" = active ] || ok=0
    else
        # MySQL or a MariaDB stand-in: both answer to the `mysql` unit alias or `mariadb`.
        st=$(docker exec "$cname" bash -c \
            'systemctl is-active mysql 2>/dev/null || systemctl is-active mariadb 2>/dev/null || echo inactive' \
            2>/dev/null | head -1)
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
        'cd /home/laranode_ln/panel && /usr/bin/php8.4 artisan tinker --execute='\''
            echo Illuminate\Support\Facades\Auth::attempt(
                ["email" => "admin@laranode.test", "password" => "password"]
            ) ? "yes" : "no";
        '\''' 2>/dev/null | tail -1)
    printf "   %-32s %s\n" "admin login" "$login"
    echo "$login" | grep -q yes || ok=0

    # ── Sudo hardening gate (every full install) ────────────────────────────
    # www-data holds NOPASSWD sudo on the privileged scripts, so (1) nothing it can
    # write may sit on the path to those scripts or their templates, and (2) every
    # script must refuse hostile arguments without touching the host. Both checks
    # live in sudo-hardening/ and discover the script dir from `sudo -l -U www-data`.
    # SKIP_SUDO_HARDENING=1 only for a scenario that deliberately has no panel.
    if [ "${SKIP_SUDO_HARDENING:-0}" != 1 ]; then
        echo "[post] sudo hardening: installed permissions"
        docker exec "${cname}" bash /src/local-dev/install-test/sudo-hardening/assert-perms.sh || ok=0
        echo "[post] sudo hardening: hostile arguments as www-data"
        docker exec "${cname}" bash /src/local-dev/install-test/sudo-hardening/assert-hostile.sh || ok=0
    fi

    # ── Scenario-specific extra assertions (optional) ──────────────────────
    if [ -n "${POST_ASSERT_FN:-}" ] && declare -f "${POST_ASSERT_FN}" >/dev/null 2>&1; then
        "${POST_ASSERT_FN}" "${cname}" || ok=0
    fi

    # ── POST_ASSERTS_CMD — optional extra bash run INSIDE the container ──────
    # Runs only when standard assertions already passed, so a failure here is
    # clearly the scenario-specific check, not the baseline gate.
    if [ "${ok:-0}" = 1 ] && [ -n "${POST_ASSERTS_CMD:-}" ]; then
        echo "[post] Running scenario-specific assertions..."
        docker exec "${cname}" bash -c "${POST_ASSERTS_CMD}" || {
            echo "FAIL: post-assertion failed for scenario '${SCENARIO}'"
            ok=0
        }
    fi

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
