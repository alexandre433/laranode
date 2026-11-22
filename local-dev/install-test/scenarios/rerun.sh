#!/usr/bin/env bash
# Scenario: rerun — idempotent re-install in the same container.
# Runs the full installer TWICE. Asserts:
#   1. second run exits 0 under set -e
#   2. APP_KEY is identical after both runs
#   3. custom LARANODE_APP_URL is preserved across runs
#   4. admin login still works (standard run_scenario assertion)
#   5. PR #11 r2: a REAL clone (not an injected tree) from a local repo at a LIGHTWEIGHT tag lands
#      detached at exactly that commit; the re-run at the ANNOTATED tag (same commit) passes the
#      ref + clean-tree check; a re-run at another tag dies and leaves the checkout alone.
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
fail() { echo "FAIL: $*" >&2; exit 1; }
echo "[rerun] === Local repo: lightweight tag, annotated tag (same commit), a later tag ==="
apt-get update -qq >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git >/dev/null 2>&1 \
    || fail "could not install git for the local test repo"
git config --system --add safe.directory "*"
R=/srv/ln-repo
mkdir -p $R && tar -C /home/laranode_ln/panel -cf - . | tar -C $R -xf -
git -C $R init -q
git -C $R -c user.name=t -c user.email=t@t add -A
git -C $R -c user.name=t -c user.email=t@t commit -q -m base
git -C $R tag v-light
git -C $R -c user.name=t -c user.email=t@t tag -a v-ann -m annotated
TAGGED=$(git -C $R rev-parse v-light^{commit})
[ "$(git -C $R rev-parse v-ann^{commit})" = "$TAGGED" ] || fail "annotated tag does not peel to the same commit"
git -C $R -c user.name=t -c user.email=t@t commit -q --allow-empty -m later
git -C $R tag v-later
chmod -R a+rX $R
# no checkout: the first run must do a real clone
rm -rf /home/laranode_ln/panel

echo "[rerun] === First installer run: real clone at the lightweight tag ==="
LARANODE_REPO=$R LARANODE_REF=v-light LARANODE_APP_URL=http://laranode.example.com LARANODE_UNATTENDED=1 COMPOSER_CACHE_DIR=/composer-cache \
    bash $R/laranode-scripts/bin/laranode-installer.sh
HEAD1=$(runuser -u laranode_ln -- git -C /home/laranode_ln/panel rev-parse HEAD)
[ "$HEAD1" = "$TAGGED" ] || fail "clone HEAD $HEAD1 is not the tagged commit $TAGGED"
if runuser -u laranode_ln -- git -C /home/laranode_ln/panel symbolic-ref -q HEAD >/dev/null 2>&1; then fail "clone is on a branch, not detached"; fi
echo "PASS: real clone at the lightweight tag: detached HEAD = tagged commit"
# PR #12 r1: the installer own build/permission steps must leave the checkout clean, or a re-run
# with LARANODE_REF could never pass
dirty=$(runuser -u laranode_ln -- git -c core.fileMode=false -C /home/laranode_ln/panel status --porcelain)
[ -z "$dirty" ] || fail "the installer left the checkout dirty after run 1: $(echo "$dirty" | head -5 | tr "\n" ";")"
echo "PASS: checkout clean after the first install"

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
echo "[rerun] === Re-run at ANOTHER tag must die on the ref check and leave the checkout alone ==="
if LARANODE_REPO=$R LARANODE_REF=v-later LARANODE_UNATTENDED=1 LARANODE_HTTP_PORT=80 COMPOSER_CACHE_DIR=/composer-cache \
    bash /home/laranode_ln/panel/laranode-scripts/bin/laranode-installer.sh > /tmp/rerun-badref.log 2>&1; then
    fail "re-run at a different LARANODE_REF succeeded"
fi
grep -q "is not at LARANODE_REF" /tmp/rerun-badref.log || { tail -15 /tmp/rerun-badref.log >&2; fail "re-run died, but not on the ref check"; }
[ "$(runuser -u laranode_ln -- git -C /home/laranode_ln/panel rev-parse HEAD)" = "$TAGGED" ] || fail "the refused re-run moved the checkout"
echo "PASS: re-run at another tag refused by the ref check, checkout untouched"
echo "[rerun] === PRESETUP done; run_scenario will now run the installer a second time ==="
'

# run_scenario runs this as the second (main) installer invocation:
INSTALLER_ENV="LARANODE_REPO=/srv/ln-repo LARANODE_REF=v-ann LARANODE_APP_URL=http://laranode.example.com LARANODE_UNATTENDED=1 LARANODE_HTTP_PORT=80"
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
