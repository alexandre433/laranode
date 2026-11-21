#!/usr/bin/env bash
# Scenario: rerun — idempotent re-install in the same container.
# Runs the full installer TWICE. Asserts:
#   1. second run exits 0 under set -e
#   2. APP_KEY is identical after both runs
#   3. custom LARANODE_APP_URL is preserved across runs
#   4. admin login still works (standard run_scenario assertion)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

SCENARIO=rerun

# ---- PRESETUP: run the installer a FIRST time, seed admin, capture state ----
# run_scenario will boot the container, inject the tree, then execute PRESETUP
# before running the installer a SECOND time as its "main" installer invocation.
# We create the admin inside PRESETUP so the users table is non-empty when
# the second run checks the first-run seed sentinel.
PRESETUP='
set -euo pipefail
echo "[rerun] === First installer run ==="
LARANODE_APP_URL=http://laranode.example.com LARANODE_UNATTENDED=1 COMPOSER_CACHE_DIR=/composer-cache \
    bash /home/laranode_ln/panel/laranode-scripts/bin/laranode-installer.sh

echo "[rerun] === Seeding admin after run 1 (users-table sentinel for run 2) ==="
/usr/bin/php8.4 /home/laranode_ln/panel/artisan tinker \
    --execute="App\Models\User::updateOrCreate(
        [\"username\"=>\"laranode\"],
        [\"name\"=>\"Admin\",\"email\"=>\"admin@laranode.test\",
         \"password\"=>bcrypt(\"password\"),\"role\"=>\"admin\",
         \"ssh_access\"=>true,\"email_verified_at\"=>now()]
    );" 2>/dev/null

echo "[rerun] === Capturing first-run state ==="
KEY1="$(grep "^APP_KEY=" /home/laranode_ln/panel/.env | cut -d= -f2-)"
URL1="$(grep "^APP_URL=" /home/laranode_ln/panel/.env | cut -d= -f2- | tr -d "\"'"'"'")"
printf "KEY1=%s\nURL1=%s\n" "$KEY1" "$URL1" > /tmp/laranode-rerun-state
echo "[rerun] KEY1=${KEY1}"
echo "[rerun] URL1=${URL1}"
echo "[rerun] === PRESETUP done; run_scenario will now run the installer a second time ==="
'

# run_scenario runs this as the second (main) installer invocation:
INSTALLER_ENV="LARANODE_APP_URL=http://laranode.example.com LARANODE_UNATTENDED=1 LARANODE_HTTP_PORT=80"
EXPECT_PORT=80
EXPECT_ENGINE=mysql

# ---- POST_ASSERTS_CMD: extra idempotency checks after standard service/HTTP/login assertions ----
POST_ASSERTS_CMD='
source /tmp/laranode-rerun-state
KEY2="$(grep "^APP_KEY=" /home/laranode_ln/panel/.env | cut -d= -f2-)"
URL2="$(grep "^APP_URL=" /home/laranode_ln/panel/.env | cut -d= -f2- | tr -d "\"'"'"'")"
extra_ok=0
printf "   %-30s %s\n" "APP_KEY (run 1)" "$KEY1"
printf "   %-30s %s\n" "APP_KEY (run 2)" "$KEY2"
if [ "$KEY1" = "$KEY2" ]; then
    printf "   %-30s PASS\n" "APP_KEY preserved"
else
    printf "   %-30s FAIL (rotated!)\n" "APP_KEY preserved"
    extra_ok=1
fi
if echo "$URL2" | grep -qF "laranode.example.com"; then
    printf "   %-30s PASS (%s)\n" "APP_URL preserved" "$URL2"
else
    printf "   %-30s FAIL (got: %s)\n" "APP_URL preserved" "$URL2"
    extra_ok=1
fi
exit $extra_ok
'

run_scenario
