#!/usr/bin/env bash
# r4: the installer is root, the panel account (laranode_ln) owns the panel dir. Any root step
# that follows a symlink laranode_ln planted there (.env.example -> a root-only file; .env ->
# any file) copies/appends root-only content into a file laranode_ln can read, or edits an
# arbitrary file. _seed_env and env_set must run AS the panel account, where the kernel stops it.
# Runs inside a container, as root, against the installer under test (INSTALLER=path).
set -uo pipefail
INSTALLER=${INSTALLER:?INSTALLER not set}
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
ok()  { echo "  ok: $*"; }
export LARANODE_INSTALLER_TEST=1

W=$(mktemp -d); chmod 755 "$W"
trap 'rm -rf "$W" "${P:-/nonexistent}"' EXIT
SECRET="$W/root-secret"; printf 'ROOT_ONLY_SECRET=hunter2\n' > "$SECRET"; chmod 600 "$SECRET"
CANARY="$W/canary"; printf 'canary-line\n' > "$CANARY"; chmod 644 "$CANARY"

P=$(mktemp -d /home/laranode_ln/envtest.XXXXXX); chown laranode_ln:laranode_ln "$P"; chmod 750 "$P"
as_panel() { runuser -u laranode_ln -- "$@"; }
inst() { ( . "$INSTALLER" >/dev/null 2>&1; PANEL_PATH="$P"; set +e; "$@" ) >/dev/null 2>&1; }
reset() { rm -f "$P/.env" "$P/.env.example"; }

echo "== installer .env handling =="

# 1. clean seed: .env appears 0640, owned by the panel account, content copied
reset; printf 'APP_KEY=\n' | as_panel tee "$P/.env.example" >/dev/null
inst _seed_env
if [ ! -f "$P/.env" ] || ! grep -qx 'APP_KEY=' "$P/.env"; then bad "clean seed: .env not created from .env.example"
elif [ "$(stat -c '%U:%a' "$P/.env")" != "laranode_ln:640" ]; then bad "clean seed: .env is $(stat -c '%U:%a' "$P/.env"), want laranode_ln:640"
else ok "clean seed: .env created laranode_ln:640"; fi

# 2. .env.example is a symlink to a root-only file: root must not copy its content
reset; as_panel ln -s "$SECRET" "$P/.env.example"
inst _seed_env
if grep -q hunter2 "$P/.env" 2>/dev/null; then bad "_seed_env copied a root-only file through a symlinked .env.example into .env (laranode_ln can read it)"
else ok "symlinked .env.example: root-only content not copied"; fi

# 3. .env is a symlink to a root-owned file: env_set must not modify the target
reset; as_panel ln -s "$CANARY" "$P/.env"
inst env_set DB_PASSWORD 'pw#1' "$P/.env"
inst env_set APP_URL 'http://x' "$P/.env"
if [ "$(cat "$CANARY")" != "canary-line" ]; then bad "env_set modified a root-owned file through a symlinked .env: $(tr '\n' '|' < "$CANARY")"
else ok "symlinked .env: root-owned target untouched by env_set"; fi

# 4. env_set still works on a normal .env (add + replace), as the panel account
reset; printf 'A=old\nB=keep\n' | as_panel tee "$P/.env" >/dev/null
inst env_set A 'new' "$P/.env"; inst env_set C 'added' "$P/.env"
if grep -qx 'A="new"' "$P/.env" && grep -qx 'C="added"' "$P/.env" && grep -qx 'B=keep' "$P/.env" && [ "$(stat -c %U "$P/.env")" = laranode_ln ]; then ok "env_set adds and replaces on a normal .env, file stays laranode_ln's"
else bad "env_set on a normal .env: $(tr '\n' '|' < "$P/.env")"; fi

exit $fail
