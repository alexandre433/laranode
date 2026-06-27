# Installer Pre-existing-Service Hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `laranode-scripts/bin/laranode-installer.sh` fail-loud, idempotent, and non-destructive on hosts that already run some of the services it installs, with operator choice of DB engine and HTTP port.

**Architecture:** In-place single-file rewrite (forced by the curl|bash bootstrap — the installer runs before the repo is cloned, so it cannot source repo helpers). Structure = helper functions + phase functions + a `BASH_SOURCE` source-guard so helpers are unit-testable on the host. A read-only preflight phase detects existing services, resolves all choices (env var > TTY prompt > default), prints a plan, and confirms before any mutation. A parameterized clean-room scenario matrix is the acceptance gate.

**Tech Stack:** Bash (`set -euo pipefail`), Apache2 + per-site PHP-FPM 8.4, MySQL 8 or PostgreSQL 16, Laravel 12 artisan, Docker + systemd (`jrei/systemd-ubuntu:24.04`) for the clean-room tests.

## Global Constraints

Copied verbatim from the design spec (2026-06-28). Every task's requirements implicitly include this section.

- `set -euo pipefail` at top; **fail loud** — the only tolerated silent failures are explicitly `|| true`-wrapped idempotent ops, each with a comment.
- **Never** rotate the system MySQL root password (drop the old `ALTER USER 'root'@'localhost'`).
- **Never** write `/etc/apache2/sites-available/000-default.conf`; the panel gets its own `laranode.conf`.
- **Single DB engine end-to-end:** `LARANODE_DB_ENGINE=mysql|pgsql` selects the panel's backing store **and** user-DB engine; **only that engine's server package is installed.**
- Installer must stay **self-contained** (runs before the repo clone) **and sourceable** (`if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi`).
- Panel **hard-requires php8.4-fpm**; install it additively but **never flip the system `php` alternative**; pin units/calls to `/usr/bin/php8.4`.
- Panel asset build **requires Node major ≥ 20**.
- **Unattended contract:** `LARANODE_UNATTENDED=1` + the `LARANODE_*` env vars keep curl|bash and the clean-room matrix fully non-interactive with sane defaults.
- **Helper signatures, env-var names, and .env keys are fixed by the shared contract** (reproduced below); do not invent variants.
- **Windows:** run `make`/`docker` from **PowerShell or cmd**, not Git Bash.
- The clean-room **scenario matrix is the gate**: all 5 scenarios must pass before merge.

### Fixed contract (helpers / env / harness)

**Helpers (defined in Task 3, called everywhere):** `die` `warn` `log` `have_cmd` `port_in_use PORT` `svc_active NAME` `version_ge HAVE WANT` `confirm MSG` `choose VAR DEF PROMPT` `env_set KEY VAL FILE` `persist_secret LINE`.
**Resolved globals:** `DB_ENGINE` (mysql|pgsql), `HTTP_PORT` (int), `PANEL_PATH=/home/laranode_ln/panel`.
**Env vars:** `LARANODE_DB_ENGINE` · `LARANODE_HTTP_PORT` · `LARANODE_MYSQL_ROOT_PASSWORD` · `LARANODE_PG_PORT` · `LARANODE_APP_URL` · `LARANODE_REPO` · `LARANODE_UNATTENDED`.
**.env keys:** `APP_URL`, `APP_KEY` (only if empty), `DB_CONNECTION`, `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`, `REVERB_HOST`, `VITE_REVERB_HOST`.
**Harness:** `local-dev/install-test/lib.sh` → `run_scenario` (env: `SCENARIO`, `PRESETUP`, `INSTALLER_ENV`, `EXPECT_PORT`, `EXPECT_ENGINE`); scenarios in `local-dev/install-test/scenarios/*.sh`; dispatcher `run.sh [scenario|matrix]`; host helper unit tests `local-dev/install-test/unit/test-helpers.sh`; Make targets `install-test` / `install-test-matrix` / `install-test-unit`.

---

### Task 1: Clean-room test harness refactor (lib.sh + dispatcher + scenarios + unit + Make targets)

**Files:**

| Action | Path |
|--------|------|
| Modify | `local-dev/install-test/run.sh` (replace monolith with dispatcher) |
| Create | `local-dev/install-test/lib.sh` |
| Create | `local-dev/install-test/scenarios/baseline.sh` |
| Create | `local-dev/install-test/scenarios/nginx80.sh` (stub) |
| Create | `local-dev/install-test/scenarios/mysql-rootpw.sh` (stub) |
| Create | `local-dev/install-test/scenarios/pgsql.sh` (stub) |
| Create | `local-dev/install-test/scenarios/rerun.sh` (stub) |
| Create | `local-dev/install-test/unit/test-helpers.sh` |
| Modify | `local-dev/Makefile` (add `install-test-matrix`, `install-test-unit`) |

**Interfaces:**

Consumes:
- `local-dev/install-test/run.sh` — existing file being replaced; all container flags preserved verbatim
- `jrei/systemd-ubuntu:24.04` — container image, unchanged
- `laranode-scripts/bin/laranode-installer.sh` — executed unmodified (current installer, no source guard yet)

Produces:
- `run_scenario` (in `lib.sh`) — callable with env inputs: `SCENARIO`, `PRESETUP`, `INSTALLER_ENV`, `EXPECT_PORT` (default 80), `EXPECT_ENGINE` (default mysql)
- `run.sh` dispatcher — `no-arg|baseline` → baseline; `matrix` → all 5, fail-fast off, summary
- `scenarios/baseline.sh` — passes against current installer (mysql, :80)
- `scenarios/{nginx80,mysql-rootpw,pgsql,rerun}.sh` — stubs that call `run_scenario` with correct envs; expected FAIL until later tasks land
- `unit/test-helpers.sh` — host-only, no container; asserts installer exists + bash -n passes; grows in Task 3

---

- [ ] **Step 1: Anchor — confirm the current monolithic run.sh is green**

  Run the current single-file test to establish a passing baseline before touching anything. This is the reference PASS to protect.

  ```powershell
  # From repo root — PowerShell/cmd only (not Git Bash; see CLAUDE.md)
  bash local-dev/install-test/run.sh
  ```

  Expected (takes 10–20 min): `RESULT: PASS — clean from-scratch install works.`

---

- [ ] **Step 2: Create directory skeleton**

  ```powershell
  # PowerShell — create the subdirectory tree (idempotent)
  New-Item -ItemType Directory -Force "local-dev/install-test/scenarios" | Out-Null
  New-Item -ItemType Directory -Force "local-dev/install-test/unit"      | Out-Null
  ```

---

- [ ] **Step 3: Write the failing dispatcher run.sh (RED)**

  Replace the monolith. The script now delegates to `scenarios/<name>.sh`. Running it immediately reveals the missing scenario files.

  ```bash
  # local-dev/install-test/run.sh
  #!/usr/bin/env bash
  # Scenario dispatcher for the clean-room install test.
  #
  # Usage:
  #   bash local-dev/install-test/run.sh              # baseline (default)
  #   bash local-dev/install-test/run.sh baseline     # explicit
  #   bash local-dev/install-test/run.sh pgsql        # named scenario
  #   bash local-dev/install-test/run.sh matrix       # all 5, fail-fast off, summary
  #
  # Per-run options (env):
  #   KEEP=1   keep container after run for inspection
  set -uo pipefail
  export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

  SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/scenarios" && pwd)"
  ARG="${1:-baseline}"

  ALL_SCENARIOS=(baseline nginx80 mysql-rootpw pgsql rerun)

  if [ "$ARG" = matrix ]; then
      declare -a pass=()
      declare -a fail=()
      for s in "${ALL_SCENARIOS[@]}"; do
          echo ""
          echo "====== Running scenario: $s ======"
          if bash "$SCENARIO_DIR/${s}.sh"; then
              pass+=("$s")
          else
              fail+=("$s")
          fi
      done
      echo ""
      echo "===== Matrix summary ====="
      if [ "${#pass[@]}" -gt 0 ]; then
          for s in "${pass[@]}"; do echo "  PASS: $s"; done
      fi
      if [ "${#fail[@]}" -gt 0 ]; then
          for s in "${fail[@]}"; do echo "  FAIL: $s"; done
      fi
      [ "${#fail[@]}" -eq 0 ]
  else
      scenario_file="$SCENARIO_DIR/${ARG}.sh"
      if [ ! -f "$scenario_file" ]; then
          echo "ERROR: unknown scenario '${ARG}'. Available: ${ALL_SCENARIOS[*]}" >&2
          exit 1
      fi
      bash "$scenario_file"
  fi
  ```

  Run to confirm RED state:

  ```powershell
  bash local-dev/install-test/run.sh baseline
  ```

  Expected: `ERROR: unknown scenario 'baseline'. Available: baseline nginx80 mysql-rootpw pgsql rerun` (exit 1) — because `scenarios/baseline.sh` does not exist yet.

---

- [ ] **Step 4: Write lib.sh**

  All container flags from the original `run.sh` are reproduced verbatim. Engine-aware DB assertion and port-aware HTTP assertion implement the contract.

  ```bash
  # local-dev/install-test/lib.sh
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

      echo "[$scenario][1/6] Booting $IMAGE with systemd..."
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
      docker exec "$cname" bash -c \
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
  ```

---

- [ ] **Step 5: Write scenarios/baseline.sh (the GREEN path)**

  This mirrors the old `run.sh` exactly: mysql engine, panel on :80, unattended, no PRESETUP.

  ```bash
  # local-dev/install-test/scenarios/baseline.sh
  #!/usr/bin/env bash
  # Scenario: bare ubuntu:24.04, all defaults → mysql, panel on :80.
  # This is the primary clean-room regression test for the installer.
  # Must pass against both the current installer and after every hardening task.
  set -uo pipefail
  SCENARIO=baseline
  PRESETUP=""
  INSTALLER_ENV="LARANODE_UNATTENDED=1"
  EXPECT_PORT=80
  EXPECT_ENGINE=mysql
  # shellcheck source=../lib.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
  run_scenario
  ```

---

- [ ] **Step 6: Verify baseline.sh passes (GREEN)**

  ```powershell
  bash local-dev/install-test/run.sh baseline
  ```

  Expected (10–20 min): all service lines show `active`, `GET :80/login` shows `200`, `admin login` shows `yes`, final line: `RESULT[baseline]: PASS`. This proves the refactored harness produces the same result as the old monolith.

---

- [ ] **Step 7: Write stub scenario files**

  Each stub sets the correct env contract and calls `run_scenario`. They will fail until the installer hardening tasks (Tasks 4–9) land. Each file includes a note explaining which task makes it green.

  ```bash
  # local-dev/install-test/scenarios/nginx80.sh
  #!/usr/bin/env bash
  # Scenario: nginx already running on :80 → installer must put panel on :8080.
  # Also asserts nginx is still answering :80 after the install.
  # EXPECTED: FAIL until Task 5 (phase_webserver port-fallback) is implemented.
  set -uo pipefail
  SCENARIO=nginx80
  # Pre-install nginx and start it so :80 is occupied before the installer runs.
  PRESETUP="apt-get install -y nginx && systemctl start nginx"
  INSTALLER_ENV="LARANODE_UNATTENDED=1"
  EXPECT_PORT=8080
  EXPECT_ENGINE=mysql
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
  run_scenario
  ```

  ```bash
  # local-dev/install-test/scenarios/mysql-rootpw.sh
  #!/usr/bin/env bash
  # Scenario: MySQL already installed with an existing root password.
  # Installer must NOT rotate that password; must create the laranode DB user instead.
  # EXPECTED: FAIL until Task 4 (phase_database root-password guard) is implemented.
  set -uo pipefail
  SCENARIO=mysql-rootpw
  # Pre-install MySQL and set a root password so auth_socket is NOT the only path.
  PRESETUP="
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y mysql-server
  systemctl start mysql
  mysql -u root -e \"ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'S3cr3tR00t'; FLUSH PRIVILEGES;\"
  "
  # Pass the known root password so the installer can authenticate without rotating it.
  INSTALLER_ENV="LARANODE_UNATTENDED=1 LARANODE_MYSQL_ROOT_PASSWORD=S3cr3tR00t"
  EXPECT_PORT=80
  EXPECT_ENGINE=mysql
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
  run_scenario
  ```

  ```bash
  # local-dev/install-test/scenarios/pgsql.sh
  #!/usr/bin/env bash
  # Scenario: Postgres engine — installer installs postgresql only (no mysql).
  # Panel must migrate, seed, and serve on Postgres.
  # EXPECTED: FAIL until Task 6 (LARANODE_DB_ENGINE=pgsql end-to-end) is implemented.
  set -uo pipefail
  SCENARIO=pgsql
  PRESETUP=""
  INSTALLER_ENV="LARANODE_UNATTENDED=1 LARANODE_DB_ENGINE=pgsql"
  EXPECT_PORT=80
  EXPECT_ENGINE=pgsql
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
  run_scenario
  ```

  ```bash
  # local-dev/install-test/scenarios/rerun.sh
  #!/usr/bin/env bash
  # Scenario: idempotent re-run — installer runs twice on the same container.
  # Second run must not error under set -euo pipefail; admin + data preserved.
  # EXPECTED: FAIL until Task 2 (set -euo pipefail + idempotency) is implemented.
  #
  # Strategy: PRESETUP does the FIRST full install; run_scenario then does the SECOND.
  # Admin is seeded after the second run; assertions confirm the panel still works.
  set -uo pipefail
  SCENARIO=rerun
  PRESETUP="LARANODE_UNATTENDED=1 bash /home/laranode_ln/panel/laranode-scripts/bin/laranode-installer.sh"
  INSTALLER_ENV="LARANODE_UNATTENDED=1"
  EXPECT_PORT=80
  EXPECT_ENGINE=mysql
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
  run_scenario
  ```

---

- [ ] **Step 8: Write unit/test-helpers.sh skeleton (runs on host, no container)**

  For Task 1 the skeleton asserts: installer file exists, and `bash -n` (syntax check) exits 0. Task 3 will extend this with source-and-assert tests for `env_set`, `version_ge`, and `choose` once the source-guard is in place.

  ```bash
  # local-dev/install-test/unit/test-helpers.sh
  #!/usr/bin/env bash
  # Host-side unit tests for the installer.
  # No container, no root, no network — runs in seconds.
  #
  # Usage: bash local-dev/install-test/unit/test-helpers.sh
  #
  # Task 1: file-existence + syntax checks only.
  # Task 3 will extend with: source installer (via source-guard), then assert
  # env_set add+replace, version_ge true/false, choose precedence (env>default
  # when not a TTY).
  set -euo pipefail

  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  INSTALLER="$REPO_ROOT/laranode-scripts/bin/laranode-installer.sh"

  PASS=0
  FAIL=0

  _ok() {
      echo "  PASS: $*"
      PASS=$((PASS + 1))
  }

  _fail() {
      echo "  FAIL: $*"
      FAIL=$((FAIL + 1))
  }

  echo "=== laranode installer unit tests ==="
  echo ""

  # T1 — installer file exists
  if [ -f "$INSTALLER" ]; then
      _ok "installer file exists"
  else
      _fail "installer file not found: $INSTALLER"
  fi

  # T2 — installer passes bash syntax check (bash -n)
  # NOTE: we do NOT source the file here because the source-guard (BASH_SOURCE[0]
  # check) is added in Task 3. Until then, sourcing would execute the full install.
  if bash -n "$INSTALLER" 2>/dev/null; then
      _ok "installer bash -n syntax OK"
  else
      _fail "installer failed bash -n syntax check"
  fi

  echo ""
  echo "Results: $PASS passed, $FAIL failed."
  [ "$FAIL" -eq 0 ]
  ```

  Run to confirm GREEN:

  ```powershell
  bash local-dev/install-test/unit/test-helpers.sh
  ```

  Expected (< 1 second):
  ```
  === laranode installer unit tests ===

    PASS: installer file exists
    PASS: installer bash -n syntax OK

  Results: 2 passed, 0 failed.
  ```

---

- [ ] **Step 9: Add Makefile targets**

  Append to the `.PHONY` line and add the two new targets in `local-dev/Makefile`. Also update the existing `install-test` target comment to note the dispatcher.

  Find and replace in `local-dev/Makefile`:

  ```makefile
  # Before (existing):
  .PHONY: up provision sh verify test test-system build-assets sync-scripts logs nuke ssl-test
  ```

  ```makefile
  # After:
  .PHONY: up provision sh verify test test-system build-assets sync-scripts logs nuke ssl-test install-test install-test-matrix install-test-unit
  ```

  And replace the existing `install-test` block:

  ```makefile
  # Before:
  # Clean-room test of the REAL production installer on a vanilla ubuntu:24.04.
  install-test:
  	bash local-dev/install-test/run.sh
  ```

  ```makefile
  # After:
  # Clean-room install tests. Each boots a vanilla ubuntu:24.04 container, runs
  # the REAL installer, and asserts services + HTTP + admin login.
  #   install-test        — baseline only (mysql, :80); fastest signal
  #   install-test-matrix — all 5 scenarios sequentially; ~1-2 hr total
  #   install-test-unit   — host-only helper tests; no container; seconds
  install-test:
  	bash local-dev/install-test/run.sh

  install-test-matrix:
  	bash local-dev/install-test/run.sh matrix

  install-test-unit:
  	bash local-dev/install-test/unit/test-helpers.sh
  ```

---

- [ ] **Step 10: Verify the full deliverable state**

  Unit test (host, fast):
  ```powershell
  bash local-dev/install-test/unit/test-helpers.sh
  ```
  Expected: `Results: 2 passed, 0 failed.`

  Baseline via dispatcher (slow, ~15 min):
  ```powershell
  bash local-dev/install-test/run.sh baseline
  ```
  Expected: `RESULT[baseline]: PASS`

  Stubs confirm expected failure state (pick one to spot-check — abort quickly):
  ```powershell
  # rerun exits non-zero because the current installer has no set -euo pipefail
  # and ALTER USER root is still present — that causes a second run to fail the DB step.
  KEEP=0 bash local-dev/install-test/scenarios/rerun.sh
  ```
  Expected: `FAIL[rerun]: ...` (confirms stub is wired correctly and will become green in a later task)

  Make targets smoke-check:
  ```powershell
  make -f local-dev/Makefile install-test-unit
  ```
  Expected: same unit test output, exit 0.

---

- [ ] **Step 11: Commit**

  ```bash
  git add local-dev/install-test/lib.sh \
          local-dev/install-test/run.sh \
          local-dev/install-test/scenarios/baseline.sh \
          local-dev/install-test/scenarios/nginx80.sh \
          local-dev/install-test/scenarios/mysql-rootpw.sh \
          local-dev/install-test/scenarios/pgsql.sh \
          local-dev/install-test/scenarios/rerun.sh \
          local-dev/install-test/unit/test-helpers.sh \
          local-dev/Makefile

  git commit -m "$(cat <<'EOF'
  test(install): refactor run.sh into lib.sh + dispatcher + scenario matrix

  Splits the single-file clean-room harness into a sourceable lib.sh exposing
  run_scenario (engine-aware + port-aware assertions), a dispatcher run.sh
  (no-arg=baseline, matrix=all-5), five scenario files, and a host-side unit
  test skeleton. Baseline passes against the current installer; the four stub
  scenarios are wired with correct envs and expected to fail until later
  hardening tasks land. Adds install-test-matrix and install-test-unit Make
  targets.

  Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JfCWbrFv5vKToujYJAbLyu
  EOF
  )"
  ```

---

Now I have everything I need. Let me draft the plan.

---

### Task 2: Templates: apache-panel.template + php8.4 systemd unit pinning

**Context:** The current installer clobbers `000-default.conf` with a hardcoded `:80` Apache template (line 256) and both systemd units call `/usr/bin/php` (the system default), which breaks when the operator runs a different system PHP. This task creates the new panel-specific Apache template with port/docroot placeholders and pins both unit templates to `/usr/bin/php8.4`, with a fast host-side grep test that gates the change.

---

**Files:**

| Action | Path |
|--------|------|
| Create | `laranode-scripts/templates/apache-panel.template` |
| Modify | `laranode-scripts/templates/laranode-reverb.service` |
| Modify | `laranode-scripts/templates/laranode-queue-worker.service` |
| Create | `local-dev/install-test/unit/test-templates.sh` |
| Modify | `local-dev/Makefile` |

---

**Interfaces:**

Consumes:
- `PANEL_PATH=/home/laranode_ln/panel` (global, set by installer — informational; template paths are hardcoded to that value for logs, with `__DOCROOT__` for the doc root)
- `__PORT__` and `__DOCROOT__` placeholder contract (consumed by `phase_webserver` in the installer, Tasks 4+)

Produces:
- `apache-panel.template` with placeholders `__PORT__` and `__DOCROOT__` (consumed by `phase_webserver` via `sed`)
- Both `.service` files with `ExecStart=/usr/bin/php8.4 …` (consumed by `phase_services` via `cp` to `/etc/systemd/system/`)
- `make install-test-templates` target (cheap, no container, runs on host in seconds)

---

**Steps:**

- [ ] **Step 1: Write the failing test and add a make target**

  Create the unit directory and test script. At this point `apache-panel.template` does not exist and both `.service` files still call `/usr/bin/php`, so all four assertions must fail.

  ```bash
  mkdir -p local-dev/install-test/unit
  ```

  Create `local-dev/install-test/unit/test-templates.sh`:

  ```bash
  #!/usr/bin/env bash
  # Unit test: template content assertions — runs on the HOST, no container needed.
  # Asserts apache-panel.template has the required placeholders and both systemd unit
  # templates pin ExecStart to /usr/bin/php8.4 (not the system-default /usr/bin/php).
  set -uo pipefail

  REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  TEMPLATES="$REPO/laranode-scripts/templates"

  pass=0
  fail=0

  check() {
      local desc="$1" rc="$2"
      if [ "$rc" = "0" ]; then
          echo "  PASS: $desc"
          pass=$((pass + 1))
      else
          echo "  FAIL: $desc"
          fail=$((fail + 1))
      fi
  }

  echo "=== template content assertions ==="

  grep -q '__PORT__'   "$TEMPLATES/apache-panel.template" 2>/dev/null; check "__PORT__ placeholder in apache-panel.template"   $?
  grep -q '__DOCROOT__' "$TEMPLATES/apache-panel.template" 2>/dev/null; check "__DOCROOT__ placeholder in apache-panel.template" $?
  grep -q '/usr/bin/php8\.4' "$TEMPLATES/laranode-reverb.service"       2>/dev/null; check "/usr/bin/php8.4 in laranode-reverb.service"       $?
  grep -q '/usr/bin/php8\.4' "$TEMPLATES/laranode-queue-worker.service" 2>/dev/null; check "/usr/bin/php8.4 in laranode-queue-worker.service" $?

  echo ""
  echo "Results: $pass passed, $fail failed."
  [ "$fail" = 0 ] && exit 0 || exit 1
  ```

  ```bash
  chmod +x local-dev/install-test/unit/test-templates.sh
  ```

  Extend `local-dev/Makefile` — add the new phony target (insert after the existing `install-test:` block):

  ```makefile
  # Fast host-side grep test: template placeholders + php8.4 pinning. No container needed.
  install-test-templates:
  	bash local-dev/install-test/unit/test-templates.sh

  install-test-unit:
  	bash local-dev/install-test/unit/test-templates.sh
  ```

  Also extend the `.PHONY` line to include both new targets:

  ```makefile
  .PHONY: up provision sh verify test test-system build-assets sync-scripts logs nuke ssl-test install-test install-test-templates install-test-unit
  ```

  Run the test — expected result is **4 FAIL**:

  ```bash
  bash local-dev/install-test/unit/test-templates.sh
  ```

  Expected output:
  ```
  === template content assertions ===
    FAIL: __PORT__ placeholder in apache-panel.template
    FAIL: __DOCROOT__ placeholder in apache-panel.template
    FAIL: /usr/bin/php8.4 in laranode-reverb.service
    FAIL: /usr/bin/php8.4 in laranode-queue-worker.service

  Results: 0 passed, 4 failed.
  ```
  *(exit 1 — expected at this stage)*

---

- [ ] **Step 2: Create `laranode-scripts/templates/apache-panel.template`**

  The template is rendered by the installer's `phase_webserver` via two `sed` substitutions: `__PORT__` → the resolved HTTP port, `__DOCROOT__` → `${PANEL_PATH}/public`. Log paths are hardcoded to `PANEL_PATH` because it is fixed at `/home/laranode_ln/panel`. `Options Indexes` is intentionally omitted — directory listing must be off for the panel app.

  Create `laranode-scripts/templates/apache-panel.template`:

  ```apache
  <VirtualHost *:__PORT__>
      ServerAdmin webmaster@localhost
      DocumentRoot __DOCROOT__

      <Directory __DOCROOT__>
          Options FollowSymLinks
          AllowOverride All
          Require all granted
      </Directory>

      ErrorLog /home/laranode_ln/panel/storage/logs/apache-error.log
      CustomLog /home/laranode_ln/panel/storage/logs/apache-access.log combined
  </VirtualHost>
  ```

---

- [ ] **Step 3: Pin `laranode-reverb.service` to `/usr/bin/php8.4`**

  Change the single `ExecStart` line. Full file after edit:

  ```ini
  [Unit]
  Description=Laravel reverb websockets for Laranode Panel
  After=network-online.target
  Wants=network-online.target

  [Service]
  ExecStart=/usr/bin/php8.4 /home/laranode_ln/panel/artisan reverb:start
  Restart=on-failure
  RestartSec=5s

  [Install]
  WantedBy=multi-user.target
  ```

---

- [ ] **Step 4: Pin `laranode-queue-worker.service` to `/usr/bin/php8.4`**

  Change the single `ExecStart` line. Full file after edit:

  ```ini
  [Unit]
  Description=Laranode Queue Worker
  After=network-online.target
  Wants=network-online.target

  [Service]
  User=laranode_ln
  Group=laranode_ln
  ExecStart=/usr/bin/php8.4 /home/laranode_ln/panel/artisan queue:work
  Restart=on-failure
  RestartSec=5s

  [Install]
  WantedBy=multi-user.target
  ```

---

- [ ] **Step 5: Run the test — all 4 must pass**

  ```bash
  bash local-dev/install-test/unit/test-templates.sh
  ```

  Expected output:
  ```
  === template content assertions ===
    PASS: __PORT__ placeholder in apache-panel.template
    PASS: __DOCROOT__ placeholder in apache-panel.template
    PASS: /usr/bin/php8.4 in laranode-reverb.service
    PASS: /usr/bin/php8.4 in laranode-queue-worker.service

  Results: 4 passed, 0 failed.
  ```
  *(exit 0)*

  Also verify via make:

  ```bash
  make -f local-dev/Makefile install-test-templates
  ```

  Expected: `Results: 4 passed, 0 failed.` and make exits 0.

---

- [ ] **Step 6: Commit**

  ```bash
  git add \
    laranode-scripts/templates/apache-panel.template \
    laranode-scripts/templates/laranode-reverb.service \
    laranode-scripts/templates/laranode-queue-worker.service \
    local-dev/install-test/unit/test-templates.sh \
    local-dev/Makefile

  git commit -m "$(cat <<'EOF'
  feat(templates): add apache-panel.template and pin units to php8.4

  Introduces a port/docroot-parameterised Apache panel vhost template so
  phase_webserver can render laranode.conf without touching 000-default.conf.
  Pins both systemd unit ExecStart lines to /usr/bin/php8.4 so the panel
  services never break when the operator's system default PHP differs.
  Adds a fast host-side grep test (make install-test-templates) that
  asserts the placeholders and the php8.4 pin before any container runs.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JfCWbrFv5vKToujYJAbLyu
  EOF
  )"
  ```

---

Now I have everything I need. Let me write the complete plan.

### Task 3: Installer sourceable skeleton: helpers + phase functions (behavior-preserving) + source guard + host unit tests

**Files:**

| Action | Path |
|--------|------|
| Modify | `laranode-scripts/bin/laranode-installer.sh` |
| Create | `local-dev/install-test/unit/test-helpers.sh` |
| Modify | `local-dev/Makefile` |

**Interfaces:**

Consumes:
- Shared contract — all 11 helper signatures (`die`, `warn`, `log`, `have_cmd`, `port_in_use`, `svc_active`, `version_ge`, `confirm`, `choose`, `env_set`, `persist_secret`) and exact bodies from contract prose
- Shared contract — phase call order: `preflight; phase_packages; phase_fetch_panel; phase_database; phase_webserver; phase_php_node; phase_app; phase_services; phase_summary`
- Shared contract — resolved globals `DB_ENGINE`, `HTTP_PORT`, `PANEL_PATH`
- Task 1 harness — `local-dev/install-test/scenarios/baseline.sh` invoked via `run_scenario`

Produces:
- All 11 helper functions callable by Tasks 4–10 without modification
- 9 phase functions + `main()` wrapping every existing install step (no behavior change on a clean box)
- Source-guard at file bottom: `if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi`
- `install-test-unit` make target (host-only, no Docker, runs in seconds)

---

- [ ] **Step 1: Write the failing unit test (TDD — red)**

Create `local-dev/install-test/unit/test-helpers.sh`. Running it against the current installer fails because the current file has no source-guard and no `env_set`/`version_ge`/`choose` functions.

```bash
#!/usr/bin/env bash
# local-dev/install-test/unit/test-helpers.sh
# Sources the installer (source-guard keeps main() silent) and asserts the
# three pure-bash helpers that later tasks rely on. No Docker, no root, ~1 s.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/../../../laranode-scripts/bin/laranode-installer.sh"

# Source the installer — source-guard must prevent main() from running
# shellcheck source=/dev/null
source "$INSTALLER"

PASS=0; FAIL=0
pass()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
flunk() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---- env_set ----------------------------------------------------------------
echo "=== env_set ==="

TMP=$(mktemp)
printf 'EXISTING=old\nOTHER=keep\n' > "$TMP"

env_set NEW_KEY myval "$TMP"
grep -q '^NEW_KEY="myval"$' "$TMP" \
  && pass "env_set: adds new key"      || flunk "env_set: adds new key"

env_set EXISTING replaced "$TMP"
grep -q '^EXISTING="replaced"$' "$TMP" \
  && pass "env_set: replaces existing" || flunk "env_set: replaces existing"
grep -q '^EXISTING=old$' "$TMP" \
  && flunk "env_set: stale value gone" || pass  "env_set: stale value gone"
grep -q '^OTHER=keep$' "$TMP" \
  && pass "env_set: untouched sibling" || flunk "env_set: untouched sibling"

rm -f "$TMP"

# ---- version_ge -------------------------------------------------------------
echo "=== version_ge ==="

version_ge 22.3 20  && pass "version_ge 22.3>=20 (true)"  || flunk "version_ge 22.3>=20 (true)"
version_ge 18.0 20  && flunk "version_ge 18.0>=20 (false)" || pass  "version_ge 18.0>=20 (false)"
version_ge 20.0 20  && pass "version_ge 20.0>=20 equal"    || flunk "version_ge 20.0>=20 equal"
version_ge 1.9 1.10 && flunk "version_ge 1.9>=1.10 (false)" || pass "version_ge 1.9>=1.10 (false)"

# ---- choose -----------------------------------------------------------------
echo "=== choose ==="

# env var beats default
MYVAR=from_env
result=$(choose MYVAR default_val "Enter val")
[ "$result" = "from_env" ] \
  && pass "choose: env var beats default" || flunk "choose: env var beats default"
unset MYVAR

# default used when no TTY (stdin is a pipe here)
result=$(echo "" | choose MYVAR default_val "Enter val")
[ "$result" = "default_val" ] \
  && pass "choose: default in non-tty"   || flunk "choose: default in non-tty"

# LARANODE_UNATTENDED=1 also forces default
LARANODE_UNATTENDED=1
result=$(choose MYVAR default_val "Enter val")
[ "$result" = "default_val" ] \
  && pass "choose: default when UNATTENDED=1" || flunk "choose: default when UNATTENDED=1"
unset LARANODE_UNATTENDED

# ---- summary ----------------------------------------------------------------
echo ""
echo "Results: passed=$PASS  failed=$FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL PASS" && exit 0
echo "FAILURES: $FAIL"
exit 1
```

Run command (before installer rewrite — expected to fail):

```bash
bash local-dev/install-test/unit/test-helpers.sh
```

Expected output (red, pre-rewrite):
```
laranode-installer.sh: line N: main: command not found   # or hangs trying to run apt-get
# or
bash: local-dev/install-test/unit/test-helpers.sh: ...env_set: command not found
FAIL: env_set: adds new key
...
FAILURES: N
```

(Exact failure mode depends on current installer state; test exits non-zero.)

---

- [ ] **Step 2: Rewrite `laranode-scripts/bin/laranode-installer.sh`**

Complete replacement. Every existing install step is wrapped verbatim into a phase function. The only structural changes are: `set -euo pipefail` at top, helper functions, phase-function wrappers, `main`, and source-guard at bottom. **No behavioral change on a clean Ubuntu 24.04 box.**

> Note: `a2enconf php8.4-fpm` is moved from the packages block into `phase_php_node` (after `php8.4-fpm` is installed) because the conf file `/etc/apache2/conf-available/php8.4-fpm.conf` is provided by that package. All other `a2enmod` calls stay in `phase_webserver` — they need only Apache itself. This is the sole ordering delta vs. the original; behavior on a clean box is identical.

> Note: `set -euo pipefail` means a second run (rerun scenario) now exits non-zero on `CREATE USER` already-exists. Idempotence hardening is Task 6; the rerun scenario is expected to be red until then.

```bash
#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ---- Overridable config (env-var interface — set before sourcing or calling) ----
LARANODE_REPO="${LARANODE_REPO:-https://github.com/alexandre433/laranode.git}"

# ---- Resolved globals (set by preflight, read by subsequent phases) ----
DB_ENGINE=mysql
HTTP_PORT=80
PANEL_PATH=/home/laranode_ln/panel

# ---- Cross-phase state (set by phase_database, read by phase_app + phase_summary) ----
LARANODE_RANDOM_PASS=""
ROOT_RANDOM_PASS=""

# ==============================================================================
# Helpers
# ==============================================================================

die()  { echo "FATAL: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
log()  { echo -e "\033[34m== $* ==\033[0m"; }

have_cmd()    { command -v "$1" >/dev/null 2>&1; }
port_in_use() { ss -tlnH "( sport = :$1 )" | grep -q .; }
svc_active()  { systemctl is-active --quiet "$1"; }

# version_ge HAVE WANT — returns 0 (true) when HAVE >= WANT (version sort)
version_ge() { printf '%s\n%s\n' "$2" "$1" | sort -V -C; }

# confirm MSG — returns 0 to proceed; auto-yes when LARANODE_UNATTENDED=1
confirm() {
  [ "${LARANODE_UNATTENDED:-0}" = "1" ] && return 0
  local _a=""
  read -rp "$1 [y/N] " _a
  [[ "$_a" =~ ^[Yy]$ ]]
}

# choose VAR_NAME DEFAULT PROMPT — echoes resolved value: env var > prompt > default
# When LARANODE_UNATTENDED=1 or stdin is not a TTY, skips the prompt and uses DEFAULT.
choose() {
  local _cur="${!1:-}"
  if [ -n "$_cur" ]; then echo "$_cur"; return; fi
  if [ "${LARANODE_UNATTENDED:-0}" = "1" ] || [ ! -t 0 ]; then echo "$2"; return; fi
  local _a=""
  read -rp "$3 [$2]: " _a
  echo "${_a:-$2}"
}

# env_set KEY VALUE FILE — add-or-replace a single .env assignment safely
env_set() {
  local k="$1" v="$2" f="$3"
  if grep -qE "^${k}=" "$f"; then
    sed -i "s#^${k}=.*#${k}=\"${v}\"#" "$f"
  else
    printf '%s="%s"\n' "$k" "$v" >> "$f"
  fi
}

# persist_secret LINE — append to /root/.laranode-credentials (0600)
persist_secret() {
  printf '%s\n' "$*" >> /root/.laranode-credentials
  chmod 600 /root/.laranode-credentials
}

# ==============================================================================
# Phase 0 — Preflight (stub: resolve globals; later tasks expand this)
# ==============================================================================

preflight() {
  DB_ENGINE=mysql
  HTTP_PORT=80
  PANEL_PATH=/home/laranode_ln/panel
}

# ==============================================================================
# Phase 1 — Base system packages
# ==============================================================================

phase_packages() {
  log "Installing base tools"
  apt-get update -q
  apt-get install -y software-properties-common git curl ca-certificates sudo openssl

  log "Installing sysstat"
  apt-get install -y sysstat
  systemctl enable sysstat
}

# ==============================================================================
# Phase 2 — Fetch the panel (user + clone)
# ==============================================================================

phase_fetch_panel() {
  log "Creating laranode_ln system user"
  useradd -m -s /bin/bash laranode_ln 2>/dev/null || true
  usermod -aG laranode_ln www-data

  log "Cloning panel from ${LARANODE_REPO}"
  if [ ! -d "${PANEL_PATH}/laranode-scripts" ]; then
    git clone "${LARANODE_REPO}" "${PANEL_PATH}"
  else
    echo "Repo already present at ${PANEL_PATH}, skipping clone."
  fi
}

# ==============================================================================
# Phase 3 — Database (MySQL only in this task; engine branching is Task 6)
# ==============================================================================

phase_database() {
  log "Installing MySQL Server"
  apt-get install -y mysql-server
  systemctl enable mysql
  systemctl start mysql

  log "Creating Laranode MySQL user and database"
  LARANODE_RANDOM_PASS=$(openssl rand -base64 12)
  ROOT_RANDOM_PASS=$(openssl rand -base64 12)

  mysql -u root -e "CREATE USER 'laranode'@'localhost' IDENTIFIED BY '${LARANODE_RANDOM_PASS}';"
  mysql -u root -e "GRANT ALL PRIVILEGES ON *.* TO 'laranode'@'localhost' WITH GRANT OPTION;"
  mysql -u root -e "FLUSH PRIVILEGES;"
  mysql -u root -e "CREATE DATABASE laranode;"
  # NOTE: rotating root password here is a known bug (CRITICAL, ticket #hardening).
  # Preserved verbatim in this task; Task 5 removes it.
  mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_RANDOM_PASS}';"
}

# ==============================================================================
# Phase 4 — Web server (Apache + modules + certbot)
# ==============================================================================

phase_webserver() {
  log "Installing Apache Web Server"
  apt-get install -y apache2
  systemctl enable apache2
  systemctl start apache2

  log "Enabling required Apache modules"
  a2enmod proxy_fcgi
  a2enmod rewrite
  a2enmod setenvif
  a2enmod headers
  a2enmod ssl
  a2enmod proxy proxy_http

  log "Installing Certbot"
  apt-get install -y certbot python3-certbot-apache
}

# ==============================================================================
# Phase 5 — PHP 8.4, Node.js, Composer, PostgreSQL client
# ==============================================================================

phase_php_node() {
  log "Adding ppa:ondrej/php"
  add-apt-repository -y ppa:ondrej/php
  apt-get update -q

  log "Installing PHP 8.4 and required extensions"
  apt-get install -y php8.4 php8.4-fpm php8.4-cli php8.4-common php8.4-curl php8.4-mbstring \
    php8.4-xml php8.4-bcmath php8.4-zip php8.4-mysql php8.4-sqlite3 php8.4-pgsql \
    php8.4-gd php8.4-imagick php8.4-intl php8.4-readline php8.4-tokenizer php8.4-fileinfo \
    php8.4-soap php8.4-opcache unzip curl

  log "Enabling PHP-FPM"
  systemctl enable php8.4-fpm
  systemctl start php8.4-fpm

  # php8.4-fpm package provides /etc/apache2/conf-available/php8.4-fpm.conf;
  # a2enconf must run after the package is installed.
  a2enconf php8.4-fpm

  log "Installing PostgreSQL server and client"
  apt-get install -y postgresql postgresql-client

  log "Installing Composer"
  curl -sS https://getcomposer.org/installer \
    | php -- --install-dir=/usr/local/bin --filename=composer

  log "Installing Node.js 22"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
}

# ==============================================================================
# Phase 6 — Application provisioning
# ==============================================================================

phase_app() {
  log "Installing PHP dependencies"
  cd "${PANEL_PATH}"
  composer install --no-interaction

  [ -f .env ] || cp .env.example .env
  sed -i "s#DB_PASSWORD=.*#DB_PASSWORD=\"${LARANODE_RANDOM_PASS}\"#" .env
  sed -i "s#APP_URL=.*#APP_URL=\"http://$(curl -s icanhazip.com)\"#" .env
  php artisan key:generate --force

  log "Installing sudoers drop-ins for www-data"
  for drop in laranode-panel laranode-cron laranode-runtimes laranode-ufw; do
    SRC="${PANEL_PATH}/laranode-scripts/etc/sudoers.d/${drop}"
    if ! visudo -c -f "${SRC}"; then
      echo "ERROR: sudoers file ${drop} failed syntax check — aborting" >&2
      exit 1
    fi
    install -m 440 "${SRC}" "/etc/sudoers.d/${drop}"
  done
  rm -f /etc/sudoers.d/laranode-postgres

  log "Provisioning PostgreSQL stats-reader role (laranode_pg_reader)"
  # Enable the versioned PG unit for Ubuntu 24.04; fall back to the generic unit.
  systemctl enable --now postgresql@16-main 2>/dev/null \
    || systemctl enable --now postgresql \
    || true

  PGSQL_READER_PASS=$(openssl rand -base64 18)
  PGSQL_PG_TAG=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-z' | head -c 8)
  sudo -u postgres psql -v ON_ERROR_STOP=1 --dbname=postgres <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'laranode_pg_reader') THEN
        CREATE ROLE laranode_pg_reader LOGIN;
    END IF;
END\$\$;
ALTER ROLE laranode_pg_reader PASSWORD \$${PGSQL_PG_TAG}\$${PGSQL_READER_PASS}\$${PGSQL_PG_TAG}\$;
GRANT CONNECT ON DATABASE postgres TO laranode_pg_reader;
GRANT pg_read_all_stats TO laranode_pg_reader;
SQL

  sed -i "s#^PGSQL_PASSWORD=.*#PGSQL_PASSWORD=\"${PGSQL_READER_PASS}\"#" "${PANEL_PATH}/.env" \
    || echo "PGSQL_PASSWORD=\"${PGSQL_READER_PASS}\"" >> "${PANEL_PATH}/.env"

  log "Migrating database, seeding, and building assets"
  php artisan migrate --force
  php artisan db:seed --force
  php artisan storage:link
  php artisan reverb:install --no-interaction
  php artisan laranode:detect-gpu

  sed -i "s#VITE_REVERB_HOST=.*#VITE_REVERB_HOST=$(curl -s icanhazip.com)#" "${PANEL_PATH}/.env"
  sed -i "s#REVERB_HOST=.*#REVERB_HOST=$(curl -s icanhazip.com)#" "${PANEL_PATH}/.env"

  # NOTE: writes to 000-default.conf — known bug (CRITICAL, ticket #hardening).
  # Preserved verbatim in this task; Task 7 replaces with laranode.conf.
  cp "${PANEL_PATH}/laranode-scripts/templates/apache2-default.template" \
    /etc/apache2/sites-available/000-default.conf

  log "Building frontend assets"
  npm install
  npm run build
}

# ==============================================================================
# Phase 7 — Services, firewall, permissions
# ==============================================================================

phase_services() {
  log "Installing systemd service units"
  cp "${PANEL_PATH}/laranode-scripts/templates/laranode-queue-worker.service" \
    /etc/systemd/system/laranode-queue-worker.service
  cp "${PANEL_PATH}/laranode-scripts/templates/laranode-reverb.service" \
    /etc/systemd/system/laranode-reverb.service

  log "Adding UFW rules for SSH / HTTP / HTTPS / Reverb"
  ufw allow 22
  ufw allow 80
  ufw allow 443
  ufw allow 8080

  log "Setting file permissions"
  mkdir -p /home/laranode_ln/logs
  chown -R laranode_ln:laranode_ln /home/laranode_ln
  find /home/laranode_ln -type d -exec chmod 770 {} \;
  find /home/laranode_ln -type f -exec chmod 660 {} \;
  find /home/laranode_ln/panel/laranode-scripts/bin -type f -exec chmod 100 {} \;
  find /home/laranode_ln/panel/storage \
       /home/laranode_ln/panel/bootstrap \
       -type d -exec chmod 775 {} \;

  log "Enabling and starting services"
  systemctl daemon-reload
  systemctl enable laranode-queue-worker.service
  systemctl enable laranode-reverb.service
  systemctl start laranode-queue-worker.service
  systemctl start laranode-reverb.service
  systemctl restart apache2
  systemctl restart php8.4-fpm
}

# ==============================================================================
# Phase 8 — Summary
# ==============================================================================

phase_summary() {
  echo "========================================================================"
  echo "========================================================================"
  echo -e "\033[32m --- NOTES ---\033[0m"
  echo "MySQL Root Password:      ${ROOT_RANDOM_PASS}"
  echo "Laranode MySQL Username:  laranode"
  echo "Laranode MySQL Password:  ${LARANODE_RANDOM_PASS}"
  echo -e "\033[32m --- IMPORTANT ---\033[0m"
  echo "Final Step: create an admin account by running:"
  echo -e "\033[33m cd /home/laranode_ln/panel && php artisan laranode:create-admin \033[0m"
  echo "========================================================================"
  echo "========================================================================"
}

# ==============================================================================
# Entrypoint
# ==============================================================================

main() {
  preflight
  phase_packages
  phase_fetch_panel
  phase_database
  phase_webserver
  phase_php_node
  phase_app
  phase_services
  phase_summary
}

# Source-guard: only run main when executed directly, not when sourced by unit tests.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
```

---

- [ ] **Step 3: Add `install-test-unit` make target to `local-dev/Makefile`**

Add `install-test-unit` to the `.PHONY` line and add the target after `install-test`. (The `install-test-matrix` target was added by Task 1.)

```makefile
.PHONY: up provision sh verify test test-system build-assets sync-scripts logs nuke ssl-test install-test install-test-matrix install-test-unit
```

New target (insert after the `install-test` block):

```makefile
# Unit tests for installer helper functions — runs on the HOST, no Docker needed.
install-test-unit:
	bash local-dev/install-test/unit/test-helpers.sh
```

---

- [ ] **Step 4: Run unit tests — expect PASS (green)**

```bash
bash local-dev/install-test/unit/test-helpers.sh
```

Expected output:
```
=== env_set ===
  PASS: env_set: adds new key
  PASS: env_set: replaces existing
  PASS: env_set: stale value gone
  PASS: env_set: untouched sibling
=== version_ge ===
  PASS: version_ge 22.3>=20 (true)
  PASS: version_ge 18.0>=20 (false)
  PASS: version_ge 20.0>=20 equal
  PASS: version_ge 1.9>=1.10 (false)
=== choose ===
  PASS: choose: env var beats default
  PASS: choose: default in non-tty
  PASS: choose: default when UNATTENDED=1

Results: passed=11  failed=0
ALL PASS
```

Exit code: `0`

---

- [ ] **Step 5: Run baseline scenario — expect PASS (green)**

This proves the phased rewrite produces an identical outcome to the original installer on a clean Ubuntu 24.04 box.

```bash
bash local-dev/install-test/run.sh
```

Or via make:

```powershell
make -f local-dev/Makefile install-test
```

Expected output (abridged — 10–15 minutes):
```
[1/5] Booting clean jrei/systemd-ubuntu:24.04 with systemd...
[2/5] Injecting working tree ...
[3/5] Running the REAL installer (installs everything; can take 10+ min)...
[4/5] Seeding an admin...
[5/5] Assertions:
   apache2                    active
   mysql                      active
   php8.4-fpm                 active
   laranode-reverb            active
   laranode-queue-worker      active
   postgresql                 active
   GET /login                 200
   admin login                yes
RESULT: PASS — clean from-scratch install works.
```

Exit code: `0`

> The rerun scenario will fail at `phase_database` (`CREATE USER` already exists) because `set -euo pipefail` is now enabled. This is expected; rerun idempotence is hardened in Task 6.

---

- [ ] **Step 6: Commit**

```bash
git add laranode-scripts/bin/laranode-installer.sh \
        local-dev/install-test/unit/test-helpers.sh \
        local-dev/Makefile

git commit -m "$(cat <<'EOF'
refactor(installer): sourceable skeleton with helpers, phases, and source-guard

Restructures laranode-installer.sh into 11 contract helpers, 9 phase
functions, a main() entrypoint, and a BASH_SOURCE source-guard so unit
tests can source the file without triggering the install. Enables
set -euo pipefail. All existing install steps are wrapped verbatim
(behavior preserved on a clean box); bugs flagged with inline NOTEs for
hardening tasks. Adds install-test-unit make target (host-only, ~1 s).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JfCWbrFv5vKToujYJAbLyu
EOF
)"
```

---

Now I have everything I need. Let me write the plan.

---

### Task 4: Preflight phase: detect + resolve choices + plan + confirm

**Files:**

- **Modify:** `laranode-scripts/bin/laranode-installer.sh` — add `DB_ENGINE`/`HTTP_PORT` global declarations; add `preflight()` function
- **Modify:** `local-dev/install-test/unit/test-helpers.sh` — extend with 4 preflight resolver assertions

**Interfaces:**

Consumes (all defined by Task 3):
- `port_in_use PORT` — returns 0 if something listens on PORT
- `have_cmd NAME` — returns 0 if NAME is in PATH
- `choose VAR DEF PROMPT` — echoes resolved value (env > TTY > default)
- `confirm MSG` — auto-0 when `LARANODE_UNATTENDED=1`
- `die MSG` / `warn MSG` / `log MSG`

Produces (globals set before any phase that needs them):
- `DB_ENGINE` — `mysql` | `pgsql`; consumed by `phase_database`, `phase_php_node`, `phase_app`
- `HTTP_PORT` — integer; consumed by `phase_webserver`, `phase_services`, `phase_summary`

Produces in test file:
- 4 new assertions covering `DB_ENGINE` and `HTTP_PORT` resolution outcomes

---

- [ ] **Step 1: Write the failing unit test assertions**

Extend `local-dev/install-test/unit/test-helpers.sh` by appending the four preflight-resolver test blocks below. Each block runs in a subshell so `set -euo pipefail` from the sourced installer stays isolated and globals don't bleed between cases.

```bash
# -----------------------------------------------------------------------
# preflight() resolver tests
# Stubs: port_in_use, have_cmd (and therefore every system command guarded
# by have_cmd). LARANODE_UNATTENDED=1 auto-proceeds through confirm().
# -----------------------------------------------------------------------

# T5: default engine resolves to mysql
(
  # shellcheck source=/dev/null
  source "$INSTALLER"
  port_in_use() { return 1; }           # :80 free
  have_cmd()    { return 1; }           # no system commands present
  export LARANODE_UNATTENDED=1
  unset LARANODE_DB_ENGINE LARANODE_HTTP_PORT
  preflight
  [ "$DB_ENGINE"  = "mysql" ] || { echo "FAIL T5: expected DB_ENGINE=mysql, got $DB_ENGINE"; exit 1; }
  [ "$HTTP_PORT"  = "80"    ] || { echo "FAIL T5: expected HTTP_PORT=80, got $HTTP_PORT";    exit 1; }
) && echo "PASS: preflight – default engine=mysql, port=80" \
  || { echo "FAIL: preflight – default engine=mysql, port=80"; FAILED=1; }

# T6: LARANODE_DB_ENGINE=pgsql is honoured
(
  source "$INSTALLER"
  port_in_use() { return 1; }
  have_cmd()    { return 1; }
  export LARANODE_UNATTENDED=1 LARANODE_DB_ENGINE=pgsql
  unset LARANODE_HTTP_PORT
  preflight
  [ "$DB_ENGINE" = "pgsql" ] || { echo "FAIL T6: expected DB_ENGINE=pgsql, got $DB_ENGINE"; exit 1; }
) && echo "PASS: preflight – LARANODE_DB_ENGINE=pgsql" \
  || { echo "FAIL: preflight – LARANODE_DB_ENGINE=pgsql"; FAILED=1; }

# T7: :80 busy → HTTP_PORT defaults to 8080
(
  source "$INSTALLER"
  port_in_use() { [ "$1" = 80 ]; }     # port 80 busy; anything else free
  have_cmd()    { return 1; }
  export LARANODE_UNATTENDED=1
  unset LARANODE_DB_ENGINE LARANODE_HTTP_PORT
  preflight
  [ "$HTTP_PORT" = "8080" ] || { echo "FAIL T7: expected HTTP_PORT=8080, got $HTTP_PORT"; exit 1; }
) && echo "PASS: preflight – :80 busy → HTTP_PORT=8080" \
  || { echo "FAIL: preflight – :80 busy → HTTP_PORT=8080"; FAILED=1; }

# T8: LARANODE_HTTP_PORT env override honoured when :80 is busy
(
  source "$INSTALLER"
  port_in_use() { [ "$1" = 80 ]; }
  have_cmd()    { return 1; }
  export LARANODE_UNATTENDED=1 LARANODE_HTTP_PORT=9000
  unset LARANODE_DB_ENGINE
  preflight
  [ "$HTTP_PORT" = "9000" ] || { echo "FAIL T8: expected HTTP_PORT=9000, got $HTTP_PORT"; exit 1; }
) && echo "PASS: preflight – LARANODE_HTTP_PORT=9000 override" \
  || { echo "FAIL: preflight – LARANODE_HTTP_PORT=9000 override"; FAILED=1; }
```

The top of the same test file must already set `INSTALLER` and `FAILED`. If Task 1 established this pattern, the only change is appending the four blocks above. No other edits to the file.

---

- [ ] **Step 2: Run the unit tests — expect FAIL**

```bash
bash local-dev/install-test/unit/test-helpers.sh
```

Expected output (Tasks 2 + 3 done; `preflight` not yet defined):

```
PASS: env_set add
PASS: env_set replace
PASS: version_ge 1.2 >= 1.1
PASS: version_ge 1.0 >= 1.0
PASS: version_ge 1.0 < 1.1
PASS: choose: env var > default when non-tty
FAIL: preflight – default engine=mysql, port=80
FAIL: preflight – LARANODE_DB_ENGINE=pgsql
FAIL: preflight – :80 busy → HTTP_PORT=8080
FAIL: preflight – LARANODE_HTTP_PORT=9000 override
RESULT: 4 test(s) failed.
```

(Each subshell exits non-zero because `preflight` is not yet defined; `set -euo pipefail` in the subshell makes the subshell exit 127, the parent `||` branch fires.)

---

- [ ] **Step 3: Declare the resolved globals in the installer**

Immediately after `PANEL_PATH` is set (the existing top-of-file globals block, after Task 2/3 have restructured it), add:

```bash
# Resolved by preflight(); read by all subsequent phases.
DB_ENGINE=""    # mysql | pgsql
HTTP_PORT=""    # 80 | 8080 (or operator-chosen)
```

These must be declared before any function that references them so that `set -u` does not fire on an unset variable if a phase function is ever called in isolation.

---

- [ ] **Step 4: Implement `preflight()` in the installer**

Insert the function below after the helpers block (Task 3) and before the first phase function. Every system command other than those already wrapped in `have_cmd` guards is either captured with `|| true` (cosmetic reads that must not abort) or wrapped with explicit error handling.

```bash
# ------------------------------------------------------------------------------
# Phase 0 — Preflight: detect, resolve choices, print plan, confirm.
# NO mutations — apt/systemctl/file writes happen only in later phases.
# ------------------------------------------------------------------------------
preflight() {
  log "Preflight: surveying environment"

  # ---- Web server on :80 -------------------------------------------------------
  local port80_free=1
  local port80_holder="none"
  if port_in_use 80; then
    port80_free=0
    # Best-effort identification; cosmetic only — never fails the install.
    local _ss_out
    _ss_out=$(ss -tlnp '( sport = :80 )' 2>/dev/null || true)
    if   echo "$_ss_out" | grep -qi 'nginx';  then port80_holder="nginx"
    elif echo "$_ss_out" | grep -qi 'apache'; then port80_holder="apache2"
    else                                           port80_holder="unknown"
    fi
    warn ":80 is held by ${port80_holder} — panel will be placed on a different port"
  fi

  # ---- MySQL -------------------------------------------------------------------
  local mysql_note="absent"
  if have_cmd mysql; then
    if mysql -u root -e 'SELECT 1' >/dev/null 2>&1; then
      mysql_note="present (root via auth_socket)"
    else
      mysql_note="present (root password required)"
    fi
  fi

  # ---- Postgres clusters -------------------------------------------------------
  local pg_note="absent"
  if have_cmd pg_lsclusters; then
    local _pg_count
    _pg_count=$(pg_lsclusters --no-header 2>/dev/null | grep -c . || true)
    if [ "${_pg_count:-0}" -gt 0 ]; then
      pg_note="${_pg_count} cluster(s) found"
    fi
  fi

  # ---- PHP ---------------------------------------------------------------------
  local php_note="absent"
  if have_cmd php; then
    local _php_ver
    _php_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
    php_note="system php ${_php_ver} (unchanged)"
  fi

  # ---- Node --------------------------------------------------------------------
  local node_note="absent"
  if have_cmd node; then
    local _node_ver
    _node_ver=$(node --version 2>/dev/null | sed 's/^v//' || true)
    node_note="node v${_node_ver} (reused if major >= 20)"
  fi

  # ---- UFW ---------------------------------------------------------------------
  local ufw_note="inactive"
  if have_cmd ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw_note="active"
  fi

  # ---- Resolve DB_ENGINE -------------------------------------------------------
  DB_ENGINE=$(choose LARANODE_DB_ENGINE mysql "DB engine (mysql|pgsql)")
  case "$DB_ENGINE" in
    mysql|pgsql) ;;
    *) die "LARANODE_DB_ENGINE must be 'mysql' or 'pgsql', got: ${DB_ENGINE}" ;;
  esac

  # ---- Resolve HTTP_PORT -------------------------------------------------------
  if [ "$port80_free" = 1 ]; then
    HTTP_PORT=80
  else
    HTTP_PORT=$(choose LARANODE_HTTP_PORT 8080 "Panel port (:80 busy — suggest 8080)")
    HTTP_PORT="${HTTP_PORT:-8080}"
  fi

  # ---- Build and print the plan ------------------------------------------------
  local _port_desc
  if [ "$port80_free" = 1 ]; then
    _port_desc="port=80"
  else
    _port_desc="port=${HTTP_PORT} (:80 held by ${port80_holder}, left untouched)"
  fi

  local _plan
  _plan="panel DB=${DB_ENGINE} · ${_port_desc} · web=apache"
  _plan+=" · php8.4 added (${php_note})"
  _plan+=" · ${node_note}"
  _plan+=" · mysql: ${mysql_note}"
  _plan+=" · pg: ${pg_note}"
  _plan+=" · ufw: ${ufw_note}"

  log "PLAN: ${_plan}"

  # ---- Confirm -----------------------------------------------------------------
  confirm "Proceed with install?" || die "Aborted by operator."
}
```

**Why `|| true` is deliberate here:** every detection command is cosmetic (its result feeds a display string, not a conditional that changes the install path). Wrapping with `|| true` satisfies `set -eo pipefail` without silently swallowing errors in mutation code — which only appears in later phases.

---

- [ ] **Step 5: Wire `preflight` as the first call inside `main`**

`main` is defined by Task 2. Ensure the call order is:

```bash
main() {
  preflight
  phase_packages
  phase_fetch_panel
  phase_database
  phase_webserver
  phase_php_node
  phase_app
  phase_services
  phase_summary
}
```

No other change to `main`.

---

- [ ] **Step 6: Run the unit tests — expect PASS**

```bash
bash local-dev/install-test/unit/test-helpers.sh
```

Expected output:

```
PASS: env_set add
PASS: env_set replace
PASS: version_ge 1.2 >= 1.1
PASS: version_ge 1.0 >= 1.0
PASS: version_ge 1.0 < 1.1
PASS: choose: env var > default when non-tty
PASS: preflight – default engine=mysql, port=80
PASS: preflight – LARANODE_DB_ENGINE=pgsql
PASS: preflight – :80 busy → HTTP_PORT=8080
PASS: preflight – LARANODE_HTTP_PORT=9000 override
All tests passed.
```

Via Make:

```bash
make -f local-dev/Makefile install-test-unit
```

Expected: exits 0, same lines as above.

---

- [ ] **Step 7: Run baseline scenario — expect PASS**

The baseline scenario boots a clean `ubuntu:24.04` container with `LARANODE_UNATTENDED=1` (the harness default). `preflight` must auto-proceed without a TTY prompt and correctly set `DB_ENGINE=mysql` and `HTTP_PORT=80` (no prior service on :80).

```bash
bash local-dev/install-test/run.sh
```

Expected terminal excerpt (among the normal install output):

```
== Preflight: surveying environment ==
== PLAN: panel DB=mysql · port=80 · web=apache · php8.4 added (absent) · node absent · mysql: absent · pg: absent · ufw: inactive ==
...
RESULT: PASS — clean from-scratch install works.
```

The full assertion block must still show all services active and `GET /login` → 200. This run takes 10–15 minutes; that is expected.

---

- [ ] **Step 8: Commit**

```bash
git add laranode-scripts/bin/laranode-installer.sh \
        local-dev/install-test/unit/test-helpers.sh

git commit -m "$(cat <<'EOF'
feat(installer): add preflight phase — detect, resolve, plan, confirm

Adds preflight() as Phase 0 of the phased installer. Detects web server on
:80 (identifies apache2/nginx via ss -p), MySQL root auth mode, Postgres
clusters, PHP/Node versions, and UFW state — all read-only. Resolves
DB_ENGINE (mysql|pgsql) and HTTP_PORT (80 if free, else 8080 or
LARANODE_HTTP_PORT) via choose(). Prints a single PLAN line and calls
confirm() before any mutation. Unit tests cover 4 resolver outcomes (default,
pgsql, :80-busy, port-override) by stubbing port_in_use/have_cmd after
sourcing the installer; all run on the host in seconds. Baseline clean-room
scenario passes with LARANODE_UNATTENDED=1 auto-proceeding through preflight.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JfCWbrFv5vKToujYJAbLyu
EOF
)"
```

---

Now I have everything I need. Let me write the complete Task 5 plan.

---

### Task 5: Database — MySQL hardening (idempotent, no root rotation, auth strategy)

**Files:**

| Action | Path |
|--------|------|
| Modify | `laranode-scripts/bin/laranode-installer.sh` — add `_mysql_branch` + `phase_database` (MySQL arm) |
| Create | `local-dev/install-test/scenarios/mysql-rootpw.sh` |
| Modify | `local-dev/install-test/lib.sh` — add `POST_ASSERT_FN` callback hook (minor extension to Task 1 output) |

**Interfaces:**

Consumes:
- `run_scenario` — `local-dev/install-test/lib.sh` (Task 1); Task 5 adds the `POST_ASSERT_FN` callback hook to `run_scenario` so scenario files can inject engine-specific assertions after the standard checks
- `die`, `warn`, `log`, `choose`, `env_set`, `persist_secret` — installer helpers defined in Task 3; Task 5 only calls them, never redefines
- Globals `DB_ENGINE`, `PANEL_PATH` — resolved and exported by `preflight` (Task 2); Task 5 reads them, never writes them

Produces:
- `_mysql_branch()` — called by `phase_database` when `DB_ENGINE=mysql`; writes all `DB_*` `.env` keys and calls `persist_secret` for the generated password; callable in isolation for unit testing
- `local-dev/install-test/scenarios/mysql-rootpw.sh` — consumed by `bash local-dev/install-test/run.sh mysql-rootpw` and by the `matrix` dispatcher

---

- [ ] **Step 1: Extend `lib.sh` with a `POST_ASSERT_FN` callback hook**

  `run_scenario` in `lib.sh` (Task 1 output) runs standard assertions then exits. Scenario-specific assertions for engine details (root-pw unchanged, DB exists) need to run inside the same container lifetime and feed into the same `ok` flag. Add a single hook point immediately after the standard assertion loop and before the cleanup/return block:

  ```bash
  # In local-dev/install-test/lib.sh, inside run_scenario(),
  # after the final standard assertion (admin login check) and before
  # the "if [ "$ok" = 1 ]" final result block — splice in:

  # ── Scenario-specific extra assertions (optional) ──────────────────────
  if [ -n "${POST_ASSERT_FN:-}" ] && declare -f "${POST_ASSERT_FN}" >/dev/null 2>&1; then
    "${POST_ASSERT_FN}" "${NAME}" || ok=0
  fi
  ```

  `NAME` is the container name variable already in scope within `run_scenario`. No other change to lib.sh is needed.

  **Expected after edit:** `bash -c 'source local-dev/install-test/lib.sh; echo ok'` prints `ok` with exit 0 (smoke-check that the source guard is still intact and no syntax error was introduced).

---

- [ ] **Step 2: Write the failing test — `scenarios/mysql-rootpw.sh`**

  This file will fail against the current installer because the old installer has no password-based root auth path; with `set -e` commented out all the `mysql -u root -e …` calls silently fail, the laranode DB is never created, `php artisan migrate` fails silently, and the panel never boots.

  ```bash
  #!/usr/bin/env bash
  # Scenario: mysql-rootpw
  #
  # Pre-installs mysql-server and switches root from auth_socket to
  # caching_sha2_password with a known password — simulating a dedicated host
  # that already runs MySQL with a root password set.
  # Runs the installer passing LARANODE_MYSQL_ROOT_PASSWORD.
  # Extra assertions (beyond run_scenario's standard checks):
  #   - root password is UNCHANGED after the install
  #   - the laranode database exists
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "${SCRIPT_DIR}/../lib.sh"

  SCENARIO="mysql-rootpw"
  EXPECT_PORT=80
  EXPECT_ENGINE="mysql"

  # Run inside the container BEFORE the installer.
  # Installs mysql-server and sets a known root password, disabling auth_socket.
  PRESETUP=$(cat <<'BASH'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq mysql-server
  systemctl enable --now mysql
  mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY 'KnownRootPwd_t3st'; FLUSH PRIVILEGES;"
  BASH
  )

  # Passed as a prefix to the installer invocation by run_scenario.
  INSTALLER_ENV="LARANODE_MYSQL_ROOT_PASSWORD=KnownRootPwd_t3st LARANODE_UNATTENDED=1"

  # Scenario-specific post-assertions — invoked by the POST_ASSERT_FN hook in
  # lib.sh with the container name as $1.
  post_assert() {
    local cname="$1"
    local failed=0

    # The original root password must still authenticate.
    # If the installer rotated it, this will fail.
    local auth_out
    auth_out=$(docker exec "${cname}" \
      mysql -u root -p'KnownRootPwd_t3st' --connect-timeout=5 \
      -e 'SELECT "root-auth-ok"' 2>/dev/null || true)
    if echo "${auth_out}" | grep -q 'root-auth-ok'; then
      printf "   %-30s %s\n" "root pw unchanged" "ok"
    else
      printf "   %-30s %s\n" "root pw unchanged" "FAIL — installer rotated the root password"
      failed=1
    fi

    # The laranode database must have been created.
    local db_count
    db_count=$(docker exec "${cname}" \
      mysql -u root -p'KnownRootPwd_t3st' --connect-timeout=5 \
      -e "SHOW DATABASES LIKE 'laranode';" 2>/dev/null \
      | grep -c laranode || true)
    if [ "${db_count:-0}" -ge 1 ]; then
      printf "   %-30s %s\n" "laranode DB exists" "ok"
    else
      printf "   %-30s %s\n" "laranode DB exists" "FAIL — database not found after install"
      failed=1
    fi

    return "${failed}"
  }
  POST_ASSERT_FN=post_assert

  run_scenario
  ```

---

- [ ] **Step 3: Run the failing test — confirm the scenario catches the bug before any fix**

  ```powershell
  # From repo root in PowerShell (not Git Bash — see CLAUDE.md Windows note)
  bash local-dev/install-test/run.sh mysql-rootpw
  ```

  Expected output (abridged — takes 10–15 min):

  ```
  [mysql-rootpw] Booting clean jrei/systemd-ubuntu:24.04 with systemd...
  [mysql-rootpw] Running PRESETUP...
  [mysql-rootpw] Running installer with: LARANODE_MYSQL_ROOT_PASSWORD=KnownRootPwd_t3st LARANODE_UNATTENDED=1
  [mysql-rootpw] Seeding an admin...
  [mysql-rootpw] Assertions:
     apache2                        active
     mysql                          active
     php8.4-fpm                     active
     laranode-reverb                inactive
     laranode-queue-worker          inactive
     GET /login                     500
     admin login                    no
     root pw unchanged              ok
     laranode DB exists             FAIL — database not found after install
  RESULT: FAIL
  ```

  The standard checks for `laranode-reverb`, `GET /login`, `admin login`, and the extra check `laranode DB exists` all fail because the old installer's `mysql -u root -e …` calls silently fail (no root socket auth, no password fallback, `set -e` commented out), so no DB is provisioned and the panel cannot boot.

---

- [ ] **Step 4: Implement `_mysql_branch` and `phase_database` in `laranode-installer.sh`**

  In the hardened installer (which has `set -euo pipefail` at the top, per the shared contract), replace the old flat MySQL block with these two functions. Place them in the **phases section**, after the helpers and after `preflight`.

  ```bash
  # ─────────────────────────────────────────────────────────────────────────────
  # _mysql_branch — MySQL provisioning for phase_database
  #
  # Auth strategy (in order):
  #   1. Try unix socket: mysql -u root -e 'SELECT 1'
  #   2. If that fails, require LARANODE_MYSQL_ROOT_PASSWORD (env/prompt/die).
  #
  # NEVER alters root credentials.  Only the 'laranode' service account is
  # touched.  All SQL ops are idempotent so re-runs converge cleanly.
  # DB_* written to .env only after all SQL ops succeed.
  # ─────────────────────────────────────────────────────────────────────────────
  _mysql_branch() {
    log "Database — MySQL: installing mysql-server"
    apt-get install -y mysql-server
    # enable+start is idempotent whether mysql was just installed or pre-existed.
    systemctl enable --now mysql

    # ── Authenticate as root ────────────────────────────────────────────────
    local -a root_args=(-u root)

    if ! mysql -u root -e 'SELECT 1' >/dev/null 2>&1; then
      # Socket auth is unavailable (root has a password set).
      local root_pw
      root_pw=$(choose LARANODE_MYSQL_ROOT_PASSWORD "" \
        "Enter the existing MySQL root password")
      [ -n "${root_pw}" ] \
        || die "MySQL root socket auth failed and LARANODE_MYSQL_ROOT_PASSWORD is not set — cannot provision the panel database"
      root_args=(-u root -p"${root_pw}")
      mysql "${root_args[@]}" -e 'SELECT 1' >/dev/null 2>&1 \
        || die "MySQL root auth failed with provided password — check LARANODE_MYSQL_ROOT_PASSWORD"
      log "MySQL root auth: caching_sha2_password / native_password (socket unavailable)"
    else
      log "MySQL root auth: unix socket (auth_socket)"
    fi

    # ── Generate a fresh panel service-account password ─────────────────────
    # Always regenerate on each run so .env and the DB stay in sync.
    local db_pass
    db_pass=$(openssl rand -base64 18)

    # ── Idempotent user + database + grants ─────────────────────────────────
    # CREATE USER IF NOT EXISTS creates on first run only.
    # ALTER USER (no IF NOT EXISTS) always syncs the password → .env match.
    # CREATE DATABASE IF NOT EXISTS is a no-op on re-run.
    # GRANT is idempotent in MySQL 8+.
    # NEVER ALTER USER root here or anywhere else in the installer.
    mysql "${root_args[@]}" -e "
      CREATE USER IF NOT EXISTS 'laranode'@'localhost' IDENTIFIED BY '${db_pass}';
      ALTER  USER              'laranode'@'localhost' IDENTIFIED BY '${db_pass}';
      CREATE DATABASE IF NOT EXISTS laranode
             CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      GRANT ALL PRIVILEGES ON *.* TO 'laranode'@'localhost' WITH GRANT OPTION;
      FLUSH PRIVILEGES;
    " || die "MySQL: failed to provision laranode user/database — see output above"

    # ── Write .env (only after all DB ops succeeded) ─────────────────────────
    env_set DB_CONNECTION mysql        "${PANEL_PATH}/.env"
    env_set DB_HOST       127.0.0.1    "${PANEL_PATH}/.env"
    env_set DB_PORT       3306         "${PANEL_PATH}/.env"
    env_set DB_DATABASE   laranode     "${PANEL_PATH}/.env"
    env_set DB_USERNAME   laranode     "${PANEL_PATH}/.env"
    env_set DB_PASSWORD   "${db_pass}" "${PANEL_PATH}/.env"

    persist_secret "MySQL laranode user password: ${db_pass}"
    log "Database — MySQL: done"
  }

  # ─────────────────────────────────────────────────────────────────────────────
  # phase_database — dispatch to the engine-specific branch
  # DB_ENGINE is resolved (and validated to mysql|pgsql) by preflight.
  # ─────────────────────────────────────────────────────────────────────────────
  phase_database() {
    case "${DB_ENGINE}" in
      mysql) _mysql_branch ;;
      pgsql) _pgsql_branch ;;   # Task 6
      *)     die "Unknown DB_ENGINE '${DB_ENGINE}' — expected mysql or pgsql" ;;
    esac
  }
  ```

  Also, remove or replace the old flat MySQL block (lines 57–76 of the current installer):

  ```bash
  # DELETE these lines from the old flat script:
  # LARANODE_RANDOM_PASS=$(openssl rand -base64 12)
  # ROOT_RANDOM_PASS=$(openssl rand -base64 12)
  # mysql -u root -e "CREATE USER 'laranode'@'localhost' IDENTIFIED BY '$LARANODE_RANDOM_PASS';"
  # mysql -u root -e "GRANT ALL PRIVILEGES ON *.* TO 'laranode'@'localhost' WITH GRANT OPTION;"
  # mysql -u root -e "FLUSH PRIVILEGES;"
  # mysql -u root -e "CREATE DATABASE laranode;"
  # mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$ROOT_RANDOM_PASS';"
  # (the last line is the root-password-rotation bug — this is the CRITICAL fix)
  ```

  The `main` function (per the shared contract) calls `phase_database` in order; `_mysql_branch` is a private helper and not called directly from `main`.

---

- [ ] **Step 5: Run the baseline scenario — confirm no regression**

  ```powershell
  bash local-dev/install-test/run.sh baseline
  ```

  Expected (10–15 min):

  ```
  [baseline] Booting clean jrei/systemd-ubuntu:24.04 with systemd...
  [baseline] Running installer with: LARANODE_UNATTENDED=1
  [baseline] Assertions:
     apache2                        active
     mysql                          active
     php8.4-fpm                     active
     laranode-reverb                active
     laranode-queue-worker          active
     GET /login                     200
     admin login                    yes
  RESULT: PASS — clean from-scratch install works.
  ```

  On a bare container, `mysql -u root -e 'SELECT 1'` succeeds via `auth_socket` (Ubuntu 24.04 default), so `_mysql_branch` takes the socket path and no `LARANODE_MYSQL_ROOT_PASSWORD` is needed. The root password is never altered.

---

- [ ] **Step 6: Run the `mysql-rootpw` scenario — confirm the fix**

  ```powershell
  bash local-dev/install-test/run.sh mysql-rootpw
  ```

  Expected (10–15 min):

  ```
  [mysql-rootpw] Booting clean jrei/systemd-ubuntu:24.04 with systemd...
  [mysql-rootpw] Running PRESETUP...
  [mysql-rootpw] Running installer with: LARANODE_MYSQL_ROOT_PASSWORD=KnownRootPwd_t3st LARANODE_UNATTENDED=1
  [mysql-rootpw] Seeding an admin...
  [mysql-rootpw] Assertions:
     apache2                        active
     mysql                          active
     php8.4-fpm                     active
     laranode-reverb                active
     laranode-queue-worker          active
     GET /login                     200
     admin login                    yes
     root pw unchanged              ok
     laranode DB exists             ok
  RESULT: PASS
  ```

  Walk-through of the happy path: PRESETUP sets root password → socket auth fails in `_mysql_branch` → `choose LARANODE_MYSQL_ROOT_PASSWORD` returns `KnownRootPwd_t3st` → password auth succeeds → `CREATE USER IF NOT EXISTS` + `ALTER USER` + `CREATE DATABASE IF NOT EXISTS` + `GRANT` + `FLUSH` all succeed → `.env` written → `migrate --force` succeeds → panel boots → `root pw unchanged` passes (no `ALTER USER root` was ever run).

---

- [ ] **Step 7: Commit**

  ```bash
  git add laranode-scripts/bin/laranode-installer.sh \
          local-dev/install-test/lib.sh \
          local-dev/install-test/scenarios/mysql-rootpw.sh

  git commit -m "$(cat <<'EOF'
  fix(installer): harden MySQL phase — no root rotation, idempotent provisioning

  Replace the flat MySQL block with _mysql_branch(): authenticate as root via
  unix socket (Ubuntu 24.04 default) or LARANODE_MYSQL_ROOT_PASSWORD when
  socket auth is unavailable; never ALTER USER root; provision the laranode
  service account idempotently with CREATE USER IF NOT EXISTS + ALTER USER
  (keeps .env in sync on re-runs); write DB_* .env keys only after all SQL
  ops succeed. Adds the mysql-rootpw install-test scenario to assert root
  credentials are unchanged and the panel boots when MySQL has a pre-existing
  root password.

  Fixes: silent root lockout (CRITICAL) when installer ran on a host with an
  existing MySQL installation.

  Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JfCWbrFv5vKToujYJAbLyu
  EOF
  )"
  ```

---

Now I have everything I need. The `config/database.php` `'pgsql'` block already uses `DB_*` env keys (confirmed at lines 86–98). The only scenario files directory doesn't exist yet (built in Task 1). Let me write the complete plan.

---

### Task 6: Database — Postgres backing-store path

**Scope:** Implement `phase_database_pgsql()` in the installer; verify `config/database.php` `'pgsql'` block reads `DB_*` (not `PGSQL_*`); deliver `scenarios/pgsql.sh` green — panel migrates, seeds, boots, and logs in against a Postgres-only host.

---

**Files:**

| Action | Path |
|--------|------|
| Modify | `laranode-scripts/bin/laranode-installer.sh` |
| Create | `local-dev/install-test/scenarios/pgsql.sh` |
| Test   | `bash local-dev/install-test/run.sh pgsql` (dispatcher built in Task 1) |

---

**Interfaces:**

*Consumes*
- `run_scenario` — `local-dev/install-test/lib.sh` (Task 1)
- `die`, `warn`, `log`, `env_set`, `persist_secret` — helper functions (Task 3)
- `DB_ENGINE`, `PANEL_PATH` — globals resolved by `preflight` (Task 3)
- `LARANODE_PG_PORT` — optional operator env var (spec §5)

*Produces*
- `phase_database_pgsql()` — self-contained, idempotent Postgres setup, callable only from `phase_database()`
- `local-dev/install-test/scenarios/pgsql.sh` — named scenario consumed by the Task 1 dispatcher

---

- [ ] **Step 1: Write the failing scenario (TDD — red)**

Create the scenario file. At this point `phase_database_pgsql` does not exist; the installer exits non-zero when `DB_ENGINE=pgsql` hits the `case` fallthrough `die`, making the scenario FAIL as expected.

```bash
mkdir -p local-dev/install-test/scenarios
cat > local-dev/install-test/scenarios/pgsql.sh <<'EOF'
#!/usr/bin/env bash
# Scenario: Postgres-backed panel install.
# INSTALLER_ENV selects pgsql engine; EXPECT_ENGINE drives harness DB assertions.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

SCENARIO="pgsql"
PRESETUP=""
INSTALLER_ENV="LARANODE_DB_ENGINE=pgsql LARANODE_UNATTENDED=1"
EXPECT_PORT=80
EXPECT_ENGINE=pgsql

run_scenario
EOF
chmod +x local-dev/install-test/scenarios/pgsql.sh
```

Run (expected: **FAIL** — installer errors because `phase_database_pgsql` is undefined):

```bash
bash local-dev/install-test/run.sh pgsql
# Expected output ends with:
# RESULT: FAIL — a check above did not pass.
```

---

- [ ] **Step 2: Verify `config/database.php` `'pgsql'` block reads `DB_*` (hard gate before writing any code)**

Run the grep on the host (no container needed):

```bash
grep -A 12 "'pgsql' =>" config/database.php
```

Expected output confirming `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`:

```
        'pgsql' => [
            'driver' => 'pgsql',
            'url' => env('DB_URL'),
            'host' => env('DB_HOST', '127.0.0.1'),
            'port' => env('DB_PORT', '5432'),
            'database' => env('DB_DATABASE', 'laravel'),
            'username' => env('DB_USERNAME', 'root'),
            'password' => env('DB_PASSWORD', ''),
            'charset' => env('DB_CHARSET', 'utf8'),
            'prefix' => '',
            'prefix_indexes' => true,
            'search_path' => 'public',
            'sslmode' => 'prefer',
        ],
```

Confirm none of `PGSQL_HOST`, `PGSQL_PORT`, `PGSQL_DB`, `PGSQL_USERNAME` appear in this block:

```bash
grep -A 12 "'pgsql' =>" config/database.php | grep -E 'PGSQL_(HOST|PORT|DB|USERNAME)'
# Expected: (no output — the pgsql connection reads DB_* only)
```

Also confirm the separate `pgsql_admin` connection (stats-reader) correctly reads `PGSQL_*` — that block must NOT be changed:

```bash
grep -A 10 "'pgsql_admin' =>" config/database.php
# Expected: 'host' => env('PGSQL_HOST', ...), 'port' => env('PGSQL_PORT', ...), ...
```

**Decision:** `config/database.php` requires no changes. The `'pgsql'` block already uses `DB_*`; the installer need only write `DB_CONNECTION=pgsql` and the companion `DB_*` keys. The `pgsql_admin` block reads `PGSQL_HOST`/`PGSQL_PORT`/`PGSQL_PASSWORD` — the installer must also write those for the stats-reader connection.

---

- [ ] **Step 3: Implement `phase_database_pgsql()`**

Add the following function to `laranode-scripts/bin/laranode-installer.sh`, **before** `phase_database()` (which is added in Step 4). The function must live in the helpers/phase block, not after `main`.

```bash
phase_database_pgsql() {
    log "Database — PostgreSQL"

    # ── packages ─────────────────────────────────────────────────────────────
    # Install only postgresql + postgresql-client; postgresql-common (which
    # provides pg_lsclusters/pg_ctlcluster) is pulled in as a dependency.
    apt-get install -y postgresql postgresql-client

    # ── cluster discovery ─────────────────────────────────────────────────────
    # After apt install, Ubuntu 24.04 creates and starts a default cluster
    # (typically 16/main). We enumerate via pg_lsclusters so the logic works
    # even if the version or cluster name differs.
    local clusters cluster_count
    clusters=$(pg_lsclusters --no-header 2>/dev/null | grep -v '^[[:space:]]*$' || true)
    # grep -c exits 1 on zero matches; || true keeps set -e happy
    cluster_count=$(echo "$clusters" | grep -c . || true)

    local PG_VER PG_CLUSTER_NAME PG_PORT
    if [ "$cluster_count" -eq 0 ]; then
        die "PostgreSQL installed but no cluster found — run pg_createcluster and re-run"
    elif [ "$cluster_count" -eq 1 ]; then
        PG_VER=$(echo "$clusters"         | awk '{print $1}')
        PG_CLUSTER_NAME=$(echo "$clusters" | awk '{print $2}')
        PG_PORT=$(echo "$clusters"         | awk '{print $3}')
    else
        # Multiple clusters: require LARANODE_PG_PORT to disambiguate
        [ -n "${LARANODE_PG_PORT:-}" ] \
            || die "Multiple PostgreSQL clusters found. Set LARANODE_PG_PORT to disambiguate:"$'\n'"$(pg_lsclusters --no-header)"
        PG_PORT="$LARANODE_PG_PORT"
        local matched
        matched=$(echo "$clusters" | awk -v p="$PG_PORT" '$3 == p {print; exit}')
        [ -n "$matched" ] \
            || die "No PostgreSQL cluster found on port $PG_PORT — verify with pg_lsclusters"
        PG_VER=$(echo "$matched"         | awk '{print $1}')
        PG_CLUSTER_NAME=$(echo "$matched" | awk '{print $2}')
    fi

    log "PostgreSQL: ver=$PG_VER cluster=$PG_CLUSTER_NAME port=$PG_PORT"

    # ── enable + start the versioned unit ────────────────────────────────────
    systemctl enable --now "postgresql@${PG_VER}-${PG_CLUSTER_NAME}"

    # ── generate panel DB password ─────────────────────────────────────────
    local DB_PASS DB_PASS_TAG
    DB_PASS=$(openssl rand -base64 18)
    # Dollar-quote tag: random lowercase alphanum so it never collides with the
    # base64 password (which cannot contain lowercase alpha runs of 8 chars
    # identically — but we tag anyway for correctness).
    DB_PASS_TAG=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 8)

    # ── idempotent role (laranode LOGIN) ─────────────────────────────────────
    # Dollar-quote the password to survive special chars from openssl rand.
    # \$\$ in an unquoted heredoc produces $$ in the SQL (dollar-quote delimiter).
    sudo -u postgres psql -p "$PG_PORT" -v ON_ERROR_STOP=1 --dbname=postgres <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'laranode') THEN
        CREATE ROLE laranode LOGIN;
    END IF;
END\$\$;
ALTER ROLE laranode PASSWORD \$${DB_PASS_TAG}\$${DB_PASS}\$${DB_PASS_TAG}\$;
SQL

    # ── idempotent database (laranode OWNER laranode) ─────────────────────────
    # CREATE DATABASE cannot run inside a transaction block (DO$$), so we run it
    # as a standalone statement guarded by || true, then assert existence.
    sudo -u postgres psql -p "$PG_PORT" \
        -c "CREATE DATABASE laranode OWNER laranode;" 2>/dev/null || true
    sudo -u postgres psql -p "$PG_PORT" -At \
        -c "SELECT 1 FROM pg_database WHERE datname='laranode';" \
        | grep -q 1 \
        || die "PostgreSQL database 'laranode' was not created — check cluster logs"
    sudo -u postgres psql -p "$PG_PORT" \
        -c "GRANT ALL PRIVILEGES ON DATABASE laranode TO laranode;" >/dev/null

    # ── pg_hba.conf — scram-sha-256 entry for laranode on 127.0.0.1/32 ───────
    # Resolve the cluster's actual hba_file path (varies by ver/cluster name).
    local HBA_CONF
    HBA_CONF=$(sudo -u postgres psql -p "$PG_PORT" -At \
        -c "SHOW hba_file;" 2>/dev/null) \
        || die "Cannot query hba_file from PostgreSQL on port $PG_PORT"

    # Add entry only if no specific host line for laranode@127.0.0.1/32 exists.
    # We do NOT remove the default 'host all all 127.0.0.1/32 scram-sha-256'
    # catchall — we merely add a more specific entry ahead of it.
    if ! grep -qE '^host[[:space:]]+laranode[[:space:]]+laranode[[:space:]]+127\.0\.0\.1/32' \
            "$HBA_CONF"; then
        echo "host    laranode        laranode        127.0.0.1/32            scram-sha-256" \
            >> "$HBA_CONF"
        sudo -u postgres psql -p "$PG_PORT" \
            -c "SELECT pg_reload_conf();" >/dev/null
    fi

    # ── smoke-test: panel user connects via 127.0.0.1 with password ──────────
    PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -p "$PG_PORT" \
        -U laranode -d laranode -c "SELECT 1;" >/dev/null \
        || die "Panel DB user 'laranode' cannot connect via 127.0.0.1:${PG_PORT} — check pg_hba.conf"

    # ── stats-reader role (laranode_pg_reader) — bound to the RESOLVED port ───
    # The pgsql_admin connection in config/database.php reads PGSQL_* keys.
    # We must target the same cluster port that the panel uses, not :5432 blindly.
    local PGSQL_READER_PASS PGSQL_PG_TAG
    PGSQL_READER_PASS=$(openssl rand -base64 18)
    PGSQL_PG_TAG=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 8)

    sudo -u postgres psql -p "$PG_PORT" -v ON_ERROR_STOP=1 --dbname=postgres <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'laranode_pg_reader') THEN
        CREATE ROLE laranode_pg_reader LOGIN;
    END IF;
END\$\$;
ALTER ROLE laranode_pg_reader PASSWORD \$${PGSQL_PG_TAG}\$${PGSQL_READER_PASS}\$${PGSQL_PG_TAG}\$;
GRANT CONNECT ON DATABASE postgres TO laranode_pg_reader;
GRANT pg_read_all_stats TO laranode_pg_reader;
SQL

    # ── write .env keys via env_set ───────────────────────────────────────────
    # Panel's own DB connection (config/database.php 'pgsql' block reads DB_*).
    env_set DB_CONNECTION pgsql         "${PANEL_PATH}/.env"
    env_set DB_HOST       127.0.0.1     "${PANEL_PATH}/.env"
    env_set DB_PORT       "$PG_PORT"    "${PANEL_PATH}/.env"
    env_set DB_DATABASE   laranode      "${PANEL_PATH}/.env"
    env_set DB_USERNAME   laranode      "${PANEL_PATH}/.env"
    env_set DB_PASSWORD   "$DB_PASS"    "${PANEL_PATH}/.env"

    # Stats-reader admin connection (config/database.php 'pgsql_admin' reads PGSQL_*).
    env_set PGSQL_HOST     127.0.0.1          "${PANEL_PATH}/.env"
    env_set PGSQL_PORT     "$PG_PORT"         "${PANEL_PATH}/.env"
    env_set PGSQL_PASSWORD "$PGSQL_READER_PASS" "${PANEL_PATH}/.env"

    # ── persist secrets ───────────────────────────────────────────────────────
    persist_secret "PostgreSQL panel password  (laranode):           $DB_PASS"
    persist_secret "PostgreSQL reader password (laranode_pg_reader): $PGSQL_READER_PASS"

    log "PostgreSQL setup complete — port=$PG_PORT db/user=laranode"
}
```

---

- [ ] **Step 4: Wire `phase_database()` to dispatch on `$DB_ENGINE`**

Locate the existing `phase_database()` body in the installer (added by Task 5, which contains the MySQL branch). Add the pgsql dispatch arm:

```bash
phase_database() {
    case "$DB_ENGINE" in
        mysql) phase_database_mysql ;;
        pgsql) phase_database_pgsql ;;
        *)     die "Unknown DB_ENGINE '${DB_ENGINE}' — valid values: mysql, pgsql" ;;
    esac
}
```

If Task 5 wrote `phase_database` as a flat MySQL-only function (no `case`), replace the entire function body with the dispatch above and move the MySQL logic into a `phase_database_mysql()` function. The plan for Task 6 assumes Task 5 already introduced the `case` skeleton — if not, the implementer restructures here.

---

- [ ] **Step 5: Run the scenario — confirm green (10–15 min)**

```bash
# From repo root in PowerShell / cmd (not Git Bash — see CLAUDE.md Windows note)
bash local-dev/install-test/run.sh pgsql
```

The lib.sh `run_scenario` (Task 1) will:
1. Boot `jrei/systemd-ubuntu:24.04` with `--privileged --cgroupns=host -v /sys/fs/cgroup:rw --tmpfs /run /run/lock /tmp`
2. Inject repo tree (excluding `vendor node_modules .git public/build .env`)
3. Execute: `LARANODE_DB_ENGINE=pgsql LARANODE_UNATTENDED=1 bash .../laranode-installer.sh`
4. Seed admin via `tinker`
5. Assert:
   - `apache2` active
   - `postgresql@16-main` (or `postgresql`) active — **not** `mysql`
   - `php8.4-fpm`, `laranode-reverb`, `laranode-queue-worker` active
   - `curl http://localhost:80/login` → HTTP 200
   - `Auth::attempt([email, password])` → `yes`

Expected terminal tail:
```
   apache2                    active
   postgresql@16-main         active
   php8.4-fpm                 active
   laranode-reverb            active
   laranode-queue-worker      active
   GET /login                 200
   admin login                yes
RESULT: PASS — scenario pgsql complete.
```

If the scenario fails, use `KEEP=1 bash local-dev/install-test/run.sh pgsql` to retain the container and debug:

```bash
# Inspect DB connectivity inside the kept container
docker exec laranode-install-test-pgsql bash -lc \
  'cd /home/laranode_ln/panel && grep ^DB_ .env'

docker exec laranode-install-test-pgsql bash -lc \
  'pg_lsclusters'

docker exec laranode-install-test-pgsql bash -lc \
  'sudo -u postgres psql -p 5432 -c "\du" postgres'

# Re-run artisan migrate manually to see error detail
docker exec laranode-install-test-pgsql bash -lc \
  'cd /home/laranode_ln/panel && php8.4 artisan migrate --force 2>&1'
```

Common failure modes and fixes:

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| `migrate` fails: `could not connect to server` | `DB_PORT` not written or wrong cluster port | check `env_set DB_PORT` call and `pg_lsclusters` output |
| `migrate` fails: `password authentication failed` | HBA not reloaded or scram entry missing | check `/etc/postgresql/<ver>/main/pg_hba.conf` tail |
| `PGSQL_READER_PASS` not in `.env` | `env_set PGSQL_PASSWORD` ran before `.env` existed | ensure `.env` copy from `.env.example` happens in `phase_app` before `phase_database` output is read |
| `postgresql@16-main` not active | service start race; `systemctl enable --now` failed silently | check `systemctl status postgresql@16-main` + journal |

---

- [ ] **Step 6: Commit**

```bash
git add \
  laranode-scripts/bin/laranode-installer.sh \
  local-dev/install-test/scenarios/pgsql.sh

git commit -m "$(cat <<'EOF'
feat(installer): add pgsql branch to phase_database

Resolve cluster port via pg_lsclusters (single auto; multiple require
LARANODE_PG_PORT); enable versioned postgresql@<ver>-<name> unit;
idempotent laranode role+DB with dollar-quoted ALTER ROLE; scoped
pg_hba.conf scram-sha-256 entry; stats-reader laranode_pg_reader bound
to resolved port; write DB_* + PGSQL_* to .env via env_set + persist_secret.
Scenario pgsql.sh green: panel migrates, seeds, boots, login passes on PG.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JfCWbrFv5vKToujYJAbLyu
EOF
)"
```

---

I have all the context I need. Let me write the complete plan.

---

### Task 7: Web server — no-clobber Apache config + :80→:8080 fallback

**Files:**

| Action | Path |
|--------|------|
| Create | `laranode-scripts/templates/apache-panel.template` |
| Modify | `laranode-scripts/bin/laranode-installer.sh` — add `phase_webserver`, remove legacy `cp → 000-default.conf` line |
| Modify | `local-dev/install-test/lib.sh` — add `POST_ASSERTS_CMD` hook (~6 lines) |
| Create | `local-dev/install-test/scenarios/nginx80.sh` |
| Modify | `local-dev/install-test/run.sh` — register `nginx80` in dispatcher |

**Interfaces:**

*Consumes:*
- `run_scenario` — from `local-dev/install-test/lib.sh` (Task 1); env inputs: `SCENARIO`, `PRESETUP`, `INSTALLER_ENV`, `EXPECT_PORT`, `EXPECT_ENGINE`, and `POST_ASSERTS_CMD` (added in this task)
- Installer helpers (Task 3): `die MSG`, `warn MSG`, `log MSG`, `have_cmd NAME`, `port_in_use PORT`, `svc_active NAME`
- Preflight globals (Task 2): `HTTP_PORT`, `PANEL_PATH`, `DB_ENGINE` — all resolved and exported before `phase_webserver` is called

*Produces:*
- `phase_webserver` — function called by `main` between `phase_database` and `phase_php_node`; renders `/etc/apache2/sites-available/laranode.conf` via sed, handles port fork, enables modules, reloads Apache, UFW rules
- `laranode-scripts/templates/apache-panel.template` — `__PORT__` + `__DOCROOT__` substitution tokens
- `local-dev/install-test/scenarios/nginx80.sh` — consumed by `run.sh` dispatcher

---

- [ ] **Step 1: Extend `lib.sh` with `POST_ASSERTS_CMD` support**

`run_scenario` in `lib.sh` (built by Task 1) manages the full container lifecycle. Task 7 needs to inject an extra in-container check after the standard assertions but before teardown. Locate the internal container-name variable (call it `_CNAME`) and the final `if [ "$ok" = 1 ]` success block. Add the following six lines immediately after the last standard assertion in `run_scenario`, before the `cleanup` call:

```bash
# ── POST_ASSERTS_CMD — optional extra bash run inside the container ──────────
# Scenario scripts set this env before calling run_scenario.  It runs ONLY
# when all standard assertions already passed (ok=1), so failures here are
# clearly from the extra check, not from the baseline gate.
if [ "${ok:-0}" = 1 ] && [ -n "${POST_ASSERTS_CMD:-}" ]; then
    echo "[post] Running scenario-specific assertions..."
    docker exec "${_CNAME}" bash -c "${POST_ASSERTS_CMD}" || {
        echo "FAIL: post-assertion failed for scenario '${SCENARIO}'"
        ok=0
    }
fi
```

Replace `_CNAME` with the exact variable name `run_scenario` uses for the container name (e.g., if Task 1 chose `CNAME` or `NAME`, match it exactly).

---

- [ ] **Step 2 (TDD — failing test first): Create `scenarios/nginx80.sh`, update dispatcher**

Write the scenario and update the dispatcher matrix before implementing `phase_webserver`. Running the scenario now must produce `RESULT: FAIL` — proving the test is wired.

**`local-dev/install-test/scenarios/nginx80.sh`** (create, mode 755):

```bash
#!/usr/bin/env bash
# Scenario: nginx already holds :80  → installer must auto-select :8080.
#
# Standard gate (via run_scenario + EXPECT_PORT=8080):
#   panel serves http://localhost:8080/login  →  200
#   all required systemd units active
#   admin login works
#
# Extra gate (POST_ASSERTS_CMD, in-container):
#   nginx STILL answers http://localhost:80/  →  2xx/3xx
set -euo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCENARIO_DIR}/../lib.sh"

export SCENARIO="nginx80"

# Install + start nginx BEFORE the installer.  The brief readiness loop ensures
# nginx has bound :80 before the installer's preflight port-check runs.
export PRESETUP='
    DEBIAN_FRONTEND=noninteractive apt-get install -y --quiet nginx >/dev/null 2>&1
    systemctl start nginx
    for _ in $(seq 1 15); do
        ss -tlnH "( sport = :80 )" | grep -q . && break
        sleep 1
    done
    ss -tlnH "( sport = :80 )" | grep -q . \
        || { echo "PRESETUP: nginx did not bind :80 in time" >&2; exit 1; }
    echo "PRESETUP: nginx is listening on :80"
'

# LARANODE_HTTP_PORT deliberately omitted — preflight must auto-detect :80 busy
# and set HTTP_PORT=8080 via the choose() logic.
export INSTALLER_ENV="LARANODE_UNATTENDED=1"

export EXPECT_PORT=8080
export EXPECT_ENGINE=mysql

# After the installer finishes, verify the pre-existing nginx is untouched.
export POST_ASSERTS_CMD='
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:80/ \
           2>/dev/null || echo 000)
    case "$code" in
        200|301|302)
            echo "PASS: nginx still answers :80  (HTTP $code)"
            ;;
        *)
            echo "FAIL: nginx on :80 is gone or broken after installer (got $code)" >&2
            exit 1
            ;;
    esac
'

run_scenario
```

**Update `local-dev/install-test/run.sh` — register nginx80 in the matrix array.**

Locate the `SCENARIOS=(...)` line that Task 1 added (e.g. `SCENARIOS=(baseline)`) and extend it:

```bash
SCENARIOS=(baseline nginx80 mysql-rootpw pgsql rerun)
```

Run the failing test (from repo root, PowerShell/cmd on Windows):

```powershell
bash local-dev/install-test/run.sh nginx80
```

Expected result:

```
[1/5] Booting clean jrei/systemd-ubuntu:24.04 with systemd...
[2/5] Injecting working tree...
[pre] Running PRESETUP in container...
PRESETUP: nginx is listening on :80
[3/5] Running the REAL installer (installs everything; can take 10+ min)...
FATAL: phase_webserver not found   ← or installer exits non-zero for another reason
RESULT: FAIL — a check above did not pass.
```

The exact failure message depends on the current installer state; any non-zero exit from the installer (or from the `GET /login (port 8080)` assertion returning non-200) confirms the test is wired correctly. Proceed.

Commit the failing test:

```bash
git add local-dev/install-test/lib.sh \
        local-dev/install-test/scenarios/nginx80.sh \
        local-dev/install-test/run.sh
git commit -m "$(cat <<'EOF'
test(install): add nginx80 scenario for :80-busy port fallback

Extends lib.sh run_scenario with POST_ASSERTS_CMD hook and adds the
nginx80 scenario: PRESETUP starts nginx on :80, expects panel on :8080,
and asserts nginx remains reachable on :80 after the installer finishes.
Currently FAIL — implementation follows in next commits.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JfCWbrFv5vKToujYJAbLyu
EOF
)"
```

---

- [ ] **Step 3: Create `laranode-scripts/templates/apache-panel.template`**

PHP dispatch is handled globally by `a2enconf php8.4-fpm` (which Task 4 / `phase_packages` enables), so no per-vhost `<FilesMatch>` block is needed. Logs use `${APACHE_LOG_DIR}` — an Apache-native variable resolved at runtime from `/etc/apache2/envvars`; sed must NOT expand it.

```apache
<VirtualHost *:__PORT__>
    ServerAdmin webmaster@localhost
    DocumentRoot __DOCROOT__

    <Directory __DOCROOT__>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/laranode-error.log
    CustomLog ${APACHE_LOG_DIR}/laranode-access.log combined
</VirtualHost>
```

Save to: `laranode-scripts/templates/apache-panel.template`

The `${APACHE_LOG_DIR}` token uses curly braces which are safe with `sed -e "s|__PORT__|...|g"` because sed only replaces the two explicit token patterns.

Commit the template:

```bash
git add laranode-scripts/templates/apache-panel.template
git commit -m "$(cat <<'EOF'
feat(install): add apache-panel.template with __PORT__ + __DOCROOT__ tokens

Replaces the hardcoded apache2-default.template used as the panel vhost.
The new template is rendered at install time via sed; 000-default.conf is
never written.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JfCWbrFv5vKToujYJAbLyu
EOF
)"
```

---

- [ ] **Step 4: Add `phase_webserver` to the installer + remove legacy clobber**

**4a — Add the function.** Insert `phase_webserver` in `laranode-scripts/bin/laranode-installer.sh` after the helper-function block (after `persist_secret`) and before `main`:

```bash
# ==============================================================================
# Phase: Web server — Apache panel vhost (no-clobber + port fallback)
# ==============================================================================
phase_webserver() {
    log "Web server — rendering Apache panel vhost"

    # Guard: globals must have been set by preflight.
    [ -n "${HTTP_PORT:-}" ]  || die "HTTP_PORT not set — preflight must run first"
    [ -n "${PANEL_PATH:-}" ] || die "PANEL_PATH not set — preflight must run first"

    # ── Render template → laranode.conf ──────────────────────────────────────
    # NEVER writes 000-default.conf.
    local tmpl="${PANEL_PATH}/laranode-scripts/templates/apache-panel.template"
    local dest="/etc/apache2/sites-available/laranode.conf"
    [ -f "$tmpl" ] || die "apache-panel.template missing at ${tmpl}"

    sed \
        -e "s|__PORT__|${HTTP_PORT}|g" \
        -e "s|__DOCROOT__|${PANEL_PATH}/public|g" \
        "$tmpl" > "$dest"

    # ── Port logic ────────────────────────────────────────────────────────────
    if [ "$HTTP_PORT" -eq 80 ]; then
        # Disable Apache's stock default-site symlink so the panel answers the
        # default vhost on :80.  a2dissite removes sites-enabled/<name>.conf
        # only — the file in sites-available is left untouched.
        a2dissite 000-default >/dev/null 2>&1 || true  # idempotent; ok if already disabled
    else
        # The panel is on an alternate port; tell Apache to listen on it.
        local ports_conf="/etc/apache2/ports.conf"
        if ! grep -qE "^Listen[[:space:]]+${HTTP_PORT}([[:space:]]|$)" "$ports_conf"; then
            printf 'Listen %s\n' "${HTTP_PORT}" >> "$ports_conf"
            log "Added 'Listen ${HTTP_PORT}' to ${ports_conf}"
        fi
        # Leave :80 (held by another server) completely untouched.
    fi

    # ── Enable required modules (a2enmod is idempotent) ──────────────────────
    a2enmod proxy_fcgi rewrite setenvif headers ssl proxy proxy_http \
        >/dev/null 2>&1 || true
    a2enconf php8.4-fpm >/dev/null 2>&1 || true

    # ── Enable the panel site ─────────────────────────────────────────────────
    a2ensite laranode || die "a2ensite laranode failed"

    # ── Validate config before touching a live Apache process ────────────────
    # apachectl configtest exits 0 on valid config (warnings go to stderr but
    # don't affect the exit code; the "could not reliably determine FQDN"
    # warning is harmless in the container environment).
    apachectl configtest \
        || die "Apache config test failed — review ${dest}"

    # ── Graceful reload (existing :80 sites keep serving during the reload) ──
    systemctl reload apache2 \
        || systemctl restart apache2 \
        || die "apache2 reload/restart failed after enabling laranode.conf"

    # ── Assert Apache is running ──────────────────────────────────────────────
    svc_active apache2 \
        || die "apache2 is not active after reload"

    # ── Assert Apache is bound on HTTP_PORT ──────────────────────────────────
    # Full 200/302 app-response check belongs in phase_services (after
    # phase_app has bootstrapped Laravel + built assets).  Here we confirm the
    # network socket is open so port-fork bugs surface early.
    if ! ss -tlnH "( sport = :${HTTP_PORT} )" | grep -q .; then
        die "Apache is not listening on :${HTTP_PORT} after reload — check ${ports_conf:-ports.conf}"
    fi

    # ── Firewall (allow-only; never 'ufw enable' or set default policy) ──────
    # ufw may be absent on some hosts; suppress "command not found" silently.
    ufw allow "${HTTP_PORT}" >/dev/null 2>&1 || true   # panel HTTP
    ufw allow 8080           >/dev/null 2>&1 || true   # Reverb websockets
    ufw allow 443            >/dev/null 2>&1 || true   # HTTPS / certbot
    ufw allow 22             >/dev/null 2>&1 || true   # SSH

    log "Apache panel vhost active on :${HTTP_PORT}"
}
```

**4b — Wire into `main`.** Replace the existing `main` body (or add the call in the correct position per the shared contract phase order):

```bash
main() {
    preflight
    phase_packages
    phase_fetch_panel
    phase_database
    phase_webserver
    phase_php_node
    phase_app
    phase_services
    phase_summary
}
```

**4c — Remove the legacy clobber line.** Find and delete (or comment with a note) the existing line that overwrites `000-default.conf`:

```bash
# REMOVE this line — it clobbers the operator's existing default site:
# cp "${PANEL_PATH}/laranode-scripts/templates/apache2-default.template" \
#    /etc/apache2/sites-available/000-default.conf
```

Also remove or relocate the existing standalone `a2enmod` / `ufw allow` calls that were inline in the old script body (they are now owned by `phase_webserver`); leave only the `systemctl restart apache2` inside `phase_services` (Task 9) for the final service-start sweep.

Commit the implementation:

```bash
git add laranode-scripts/bin/laranode-installer.sh
git commit -m "$(cat <<'EOF'
feat(install): phase_webserver — no-clobber Apache vhost + :8080 fallback

Renders apache-panel.template to laranode.conf (000-default.conf is
never written). When :80 is free, a2dissite 000-default lets the panel
answer the default host; when :80 is occupied, appends Listen <port> to
ports.conf and leaves the existing server untouched.  Enables modules
idempotently, validates config before reload, asserts socket open, and
adds UFW allow-only rules for panel-port/8080/443/22.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JfCWbrFv5vKToujYJAbLyu
EOF
)"
```

---

- [ ] **Step 5: Run `nginx80` scenario — expect PASS**

```bash
bash local-dev/install-test/run.sh nginx80
```

Expected output (abridged; full run takes ~10–15 min):

```
[1/5] Booting clean jrei/systemd-ubuntu:24.04 with systemd...
[2/5] Injecting working tree (fresh — no host vendor/.env/cache)...
[pre] Running PRESETUP in container...
PRESETUP: nginx is listening on :80
[3/5] Running the REAL installer (installs everything; can take 10+ min)...
[4/5] Seeding an admin...
[5/5] Assertions:
   apache2                    active
   mysql                      active
   php8.4-fpm                 active
   laranode-reverb            active
   laranode-queue-worker      active
   GET /login (port 8080)     200
   admin login                yes
[post] Running scenario-specific assertions...
PASS: nginx still answers :80  (HTTP 200)
RESULT: PASS — nginx80 scenario complete.
```

If `GET /login (port 8080)` returns `000` (connection refused), the port-fork in `phase_webserver` did not write `Listen 8080` to `ports.conf` — inspect `/etc/apache2/ports.conf` in the kept container (`KEEP=1 bash local-dev/install-test/run.sh nginx80`).

If `PASS: nginx still answers :80` is missing and the post-assertion fails, the `a2dissite 000-default` call ran when `HTTP_PORT=8080` (it should not — the `if [ "$HTTP_PORT" -eq 80 ]` branch is the guard). Check that `HTTP_PORT` is exported correctly by preflight.

---

- [ ] **Step 6: Run `baseline` — expect no regression**

```bash
bash local-dev/install-test/run.sh baseline
```

Expected output (abridged):

```
[5/5] Assertions:
   apache2                    active
   mysql                      active
   php8.4-fpm                 active
   laranode-reverb            active
   laranode-queue-worker      active
   GET /login (port 80)       200
   admin login                yes
RESULT: PASS — clean from-scratch install works.
```

Confirms that on a clean host (`:80` free) the panel still answers `:80`, `a2dissite 000-default` removed the stock symlink correctly, and the `laranode.conf` with `__PORT__=80` rendered and validated cleanly.

---

**Design note — curl 200/302 assertion timing**

The spec calls for `curl -fsS http://localhost:HTTP_PORT/ → 200/302` inside `phase_webserver`. This assertion is deferred to `phase_services` (Task 9) because at `phase_webserver` time `phase_app` has not run yet: `vendor/autoload.php` does not exist, Laravel cannot bootstrap, and the response will be a PHP fatal (502 from FPM or 500 from Apache). `phase_webserver` instead asserts the network socket (`ss -tlnH | grep ":PORT"`) which proves the port-fork logic worked without depending on app readiness. `phase_services` runs after `phase_app` and owns the end-to-end `curl 200/302` gate.

---

Now I have full grounding. Let me write the complete plan.

---

### Task 8: PHP / Node — install php8.4 without flipping default; node warn+skip

**Files:**

| Action | Path |
|--------|------|
| Modify | `laranode-scripts/bin/laranode-installer.sh` — add `phase_php_node` function; wire into `main` |
| Modify | `laranode-scripts/templates/laranode-reverb.service` — pin `ExecStart` to `/usr/bin/php8.4` |
| Modify | `laranode-scripts/templates/laranode-queue-worker.service` — pin `ExecStart` to `/usr/bin/php8.4` |
| Modify | `local-dev/install-test/lib.sh` — add `extra_asserts` hook to `run_scenario` |
| Modify | `local-dev/install-test/scenarios/nginx80.sh` — extend PRESETUP (pre-install php8.3); add `extra_asserts` function asserting alternative is unchanged |
| Test   | `local-dev/install-test/scenarios/nginx80.sh` (integration, ~15 min) |

**Interfaces:**

_Consumes_
- `have_cmd NAME` — Task 3 helper; used to detect pre-existing `node`
- `version_ge HAVE WANT` — Task 3 helper; used to gate Node version
- `warn MSG`, `die MSG`, `log MSG` — Task 3 helpers
- `run_scenario` from `local-dev/install-test/lib.sh` — Task 1 harness; container name exported as `LN_CONTAINER`
- `LARANODE_UNATTENDED` global; `PANEL_PATH` global — both resolved by `preflight` (Task 2)

_Produces_
- `phase_php_node` — implements PHP 8.4 additive install + alternative guard + Node warn-or-install; registered as 6th call in `main`

---

- [ ] **Step 1: Extend `lib.sh` to call an `extra_asserts` hook**

After Task 1 builds `local-dev/install-test/lib.sh`, the `run_scenario` function runs built-in service/HTTP/login assertions then cleans up. This step adds a hook: if the calling scenario has defined an `extra_asserts` shell function, `run_scenario` calls it with the container name before the pass/fail gate. No existing scenario defines `extra_asserts`, so this change is backward-compatible.

Locate the section in `lib.sh` that sets `ok=1` and walks the service list, immediately before the final `if [ "$ok" = 1 ]` block, and insert:

```bash
# Optional hook: scenario scripts may define extra_asserts(container_name)
# to run additional checks inside the container before teardown.
if declare -f extra_asserts >/dev/null 2>&1; then
    extra_asserts "$LN_CONTAINER" || ok=0
fi
```

`LN_CONTAINER` must already be exported by `run_scenario` when the container is booted (e.g., `LN_CONTAINER="laranode-install-test-${SCENARIO}"`). Confirm that variable is set earlier in `run_scenario`:

```bash
LN_CONTAINER="laranode-install-test-${SCENARIO}"
export LN_CONTAINER
```

---

- [ ] **Step 2: Extend `scenarios/nginx80.sh` — PRESETUP installs php8.3 + adds `extra_asserts` (this is the failing test)**

Replace the full content of `local-dev/install-test/scenarios/nginx80.sh` with the version below. The PRESETUP installs nginx (holding :80) and php8.3 from Ubuntu 24.04's default repos; it does **not** call `update-alternatives --set`, leaving alternatives in auto mode pointing at php8.3. The `extra_asserts` function runs after the installer and checks that (a) the system `php` alternative still resolves to `/usr/bin/php8.3` and (b) `/usr/bin/php8.4` was installed.

```bash
#!/usr/bin/env bash
# Scenario: nginx already holds :80  → panel must land on :8080
#           php8.3 is the system default → installer must NOT flip it to 8.4
set -euo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

SCENARIO=nginx80
PRESETUP='
    apt-get update -qq
    apt-get install -y nginx php8.3
    systemctl enable --now nginx
'
INSTALLER_ENV="LARANODE_UNATTENDED=1"
EXPECT_PORT=8080
EXPECT_ENGINE=mysql

# Called by run_scenario (lib.sh) with the container name as $1, after built-in
# service/HTTP/login assertions and before teardown.
extra_asserts() {
    local cname="$1"
    local alt
    alt=$(docker exec "$cname" \
            update-alternatives --query php 2>/dev/null \
          | awk '/^Value:/{print $2}')
    printf "   %-26s %s\n" "php alternative" "${alt:-<unset>}"
    [ "$alt" = "/usr/bin/php8.3" ] \
        || { echo "FAIL: system php alternative was changed to '${alt}' (expected /usr/bin/php8.3)"; return 1; }
    docker exec "$cname" test -x /usr/bin/php8.4 \
        || { echo "FAIL: /usr/bin/php8.4 not found after install"; return 1; }
    printf "   %-26s %s\n" "/usr/bin/php8.4 exists" "ok"
}

# shellcheck source=../lib.sh
source "$(dirname "$0")/../lib.sh"
run_scenario
```

---

- [ ] **Step 3: Run the failing scenario — confirm it fails before the fix**

Run from the repo root (PowerShell/cmd; see CLAUDE.md Windows note):

```powershell
bash local-dev/install-test/run.sh nginx80
```

Expected result before the fix is applied:

```
[1/5] Booting clean jrei/systemd-ubuntu:24.04 with systemd...
[2/5] Injecting working tree...
[3/5] Running PRESETUP...
[4/5] Running the REAL installer...
[5/5] Assertions:
   apache2                    active
   mysql                      active
   php8.4-fpm                 active
   laranode-reverb            active
   laranode-queue-worker      active
   GET /login                 200
   admin login                yes
   php alternative            /usr/bin/php8.4      ← WRONG
FAIL: system php alternative was changed to '/usr/bin/php8.4' (expected /usr/bin/php8.3)
RESULT: FAIL — a check above did not pass.
```

This confirms the current installer flips the `php` alternative to 8.4 when `apt install php8.4` registers a higher-priority entry with `ppa:ondrej/php`.

---

- [ ] **Step 4: Implement `phase_php_node` in the installer**

Add the following function to `laranode-scripts/bin/laranode-installer.sh` after the helper definitions and before `main`. The function:
- Adds `ppa:ondrej/php` and dies loudly if the add-apt-repository call fails (network or GPG error).
- Captures the **pre-existing** `php` update-alternatives target before touching anything.
- Installs php8.4 and all required extensions (`apt-get install` is additive; extensions already installed are no-ops).
- After install, checks if APT auto-flipped the alternative to 8.4. If the operator's prior target was not 8.4, restores it with `update-alternatives --set` (forces manual mode back to the captured target) and emits a `warn`.
- Enables and starts php8.4-fpm.
- Node: if `have_cmd node`, warns and skips nodesource; requires `version_ge` major ≥ 20 or dies with an actionable message. If node is absent, runs the nodesource setup script and asserts the installed major is 22.

```bash
phase_php_node() {
    log "PHP 8.4 + Node"

    # ------------------------------------------------------------------
    # PHP
    # ------------------------------------------------------------------
    log "Adding ppa:ondrej/php"
    add-apt-repository -y ppa:ondrej/php \
        || die "add-apt-repository ppa:ondrej/php failed — check network/GPG"
    apt-get update -qq

    # Capture the current system php alternative BEFORE installing php8.4.
    # ppa:ondrej/php registers php8.4 at a higher priority than any Ubuntu-shipped
    # php, so auto mode would silently flip the default.  We record the target now
    # and restore it afterwards if it was changed.
    local sys_php=""
    sys_php=$(update-alternatives --query php 2>/dev/null \
              | awk '/^Value:/{print $2}') || true   # no alternatives yet → empty

    log "Installing php8.4 and extensions (additive)"
    apt-get install -y \
        php8.4 php8.4-fpm php8.4-cli php8.4-common \
        php8.4-curl php8.4-mbstring php8.4-xml php8.4-bcmath \
        php8.4-zip php8.4-mysql php8.4-sqlite3 php8.4-pgsql \
        php8.4-gd php8.4-imagick php8.4-intl php8.4-readline \
        php8.4-tokenizer php8.4-fileinfo php8.4-soap php8.4-opcache \
        unzip curl \
        || die "apt-get install php8.4 extensions failed"

    # Restore pre-existing alternative if apt auto-flipped it to 8.4.
    if [ -n "$sys_php" ] && [ "$sys_php" != "/usr/bin/php8.4" ]; then
        local after_php=""
        after_php=$(update-alternatives --query php 2>/dev/null \
                    | awk '/^Value:/{print $2}') || true
        if [ "$after_php" = "/usr/bin/php8.4" ]; then
            update-alternatives --set php "$sys_php" \
                || warn "could not restore php alternative to ${sys_php} — check manually"
        fi
        warn "System 'php' alternative left as ${sys_php}. Panel uses /usr/bin/php8.4 directly."
    fi

    systemctl enable php8.4-fpm \
        || die "systemctl enable php8.4-fpm failed"
    systemctl start php8.4-fpm \
        || die "systemctl start php8.4-fpm failed"

    # ------------------------------------------------------------------
    # Node
    # ------------------------------------------------------------------
    if have_cmd node; then
        local node_ver=""
        node_ver=$(node -v | tr -d 'v')
        warn "node already present (v${node_ver}); skipping nodesource setup"
        version_ge "${node_ver}" "20" \
            || die "panel build needs Node >=20; found v${node_ver} — install/upgrade and re-run"
    else
        log "Installing Node 22 via nodesource"
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
            || die "nodesource setup_22.x script failed"
        apt-get install -y nodejs \
            || die "apt-get install nodejs failed"
        local installed_ver=""
        installed_ver=$(node -v | tr -d 'v')
        local installed_major="${installed_ver%%.*}"
        [ "$installed_major" = "22" ] \
            || die "expected Node major 22 after nodesource install; got v${installed_ver}"
    fi
}
```

---

- [ ] **Step 5: Wire `phase_php_node` into `main` and remove the old inline PHP/Node block**

In the `main` function, call `phase_php_node` as the sixth phase after `phase_webserver`:

```bash
main() {
    preflight
    phase_packages
    phase_fetch_panel
    phase_database
    phase_webserver
    phase_php_node        # ← add this line
    phase_app
    phase_services
    phase_summary
}
```

Remove (or guard with `|| true`) any pre-existing inline `add-apt-repository`, `apt install php8.4`, and `curl … nodesource` lines that are now superseded by `phase_php_node`. If those lines were in the old flat installer body, delete them entirely — they are no longer called from `main`.

---

- [ ] **Step 6: Pin systemd service templates to `/usr/bin/php8.4`**

The two service templates currently use the generic `/usr/bin/php` symlink, which would follow the system alternative and break if the operator's default is a different version. Pin them to the explicit php8.4 binary.

`laranode-scripts/templates/laranode-reverb.service` — change `ExecStart` line:

```ini
ExecStart=/usr/bin/php8.4 /home/laranode_ln/panel/artisan reverb:start
```

`laranode-scripts/templates/laranode-queue-worker.service` — change `ExecStart` line:

```ini
ExecStart=/usr/bin/php8.4 /home/laranode_ln/panel/artisan queue:work
```

Full content of `laranode-scripts/templates/laranode-reverb.service` after edit:

```ini
[Unit]
Description=Laravel reverb websockets for Laranode Panel
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/php8.4 /home/laranode_ln/panel/artisan reverb:start
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

Full content of `laranode-scripts/templates/laranode-queue-worker.service` after edit:

```ini
[Unit]
Description=Laranode Queue Worker
After=network-online.target
Wants=network-online.target

[Service]
User=laranode_ln
Group=laranode_ln
ExecStart=/usr/bin/php8.4 /home/laranode_ln/panel/artisan queue:work
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

---

- [ ] **Step 7: Run nginx80 scenario — confirm it passes**

```powershell
bash local-dev/install-test/run.sh nginx80
```

Expected result after the fix:

```
[1/5] Booting clean jrei/systemd-ubuntu:24.04 with systemd...
[2/5] Injecting working tree...
[3/5] Running PRESETUP...
[4/5] Running the REAL installer...
[5/5] Assertions:
   apache2                    active
   mysql                      active
   php8.4-fpm                 active
   laranode-reverb            active
   laranode-queue-worker      active
   GET /login                 200
   admin login                yes
   php alternative            /usr/bin/php8.3      ← restored
   /usr/bin/php8.4 exists     ok
RESULT: PASS — nginx80 scenario complete.
```

Key signal: `php alternative /usr/bin/php8.3` confirms `phase_php_node` detected the auto-flip and restored it via `update-alternatives --set`.

---

- [ ] **Step 8: Run baseline — confirm no regression**

```powershell
bash local-dev/install-test/run.sh
```

Expected result (clean ubuntu, no pre-existing php):

```
[5/5] Assertions:
   apache2                    active
   mysql                      active
   php8.4-fpm                 active
   laranode-reverb            active
   laranode-queue-worker      active
   GET /login                 200
   admin login                yes
RESULT: PASS — clean from-scratch install works.
```

`sys_php` is empty on a clean container (no prior php), so `phase_php_node` skips the restore path entirely and goes straight to nodesource Node 22 install. The `extra_asserts` function is not defined in the baseline scenario so the lib.sh hook is a no-op.

---

- [ ] **Step 9: Commit**

```bash
git add \
    laranode-scripts/bin/laranode-installer.sh \
    laranode-scripts/templates/laranode-reverb.service \
    laranode-scripts/templates/laranode-queue-worker.service \
    local-dev/install-test/lib.sh \
    local-dev/install-test/scenarios/nginx80.sh

git commit -m "$(cat <<'EOF'
feat(installer): add phase_php_node with alternative guard and node warn+skip

Install php8.4 additively via ppa:ondrej/php; capture the pre-existing
update-alternatives php target before apt runs and restore it afterwards
if APT's auto-mode flipped the system default to 8.4 — the panel always
calls /usr/bin/php8.4 directly, so the system default must be left intact.
Node: warn+skip nodesource if node >=20 already present; die if <20; install
node 22 from nodesource and assert major==22 if absent.

Pin laranode-reverb and laranode-queue-worker ExecStart to /usr/bin/php8.4
so the services are immune to any system-default changes.

Extend nginx80 scenario PRESETUP to pre-install php8.3 and add an
extra_asserts hook that verifies the alternative is /usr/bin/php8.3 after
install; lib.sh gains the extra_asserts(container) call-if-defined hook.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JfCWbrFv5vKToujYJAbLyu
EOF
)"
```

---

Now I have all the context I need. Let me write the complete plan.

---

### Task 9: App provisioning guards + secrets + idempotent re-run

**Files:**

| Action | Path |
|--------|------|
| Modify | `laranode-scripts/bin/laranode-installer.sh` — add `phase_app()` and `phase_summary()`; slot both into `main` |
| Modify | `local-dev/install-test/lib.sh` — extend `run_scenario` with an optional `POST_ASSERT` hook (prerequisite for rerun extra assertions) |
| Create | `local-dev/install-test/scenarios/rerun.sh` |

**Interfaces:**

_Consumes (defined by other tasks):_

| Symbol | Source |
|--------|--------|
| `die`, `warn`, `log`, `env_set`, `persist_secret` | Task 3 helpers |
| `PANEL_PATH` | top-of-file constant (`/home/laranode_ln/panel`) |
| `DB_ENGINE` | resolved global set by Task 2 preflight |
| `LARANODE_APP_URL` | operator env var (may be empty string) |
| `LARANODE_DB_PASS` | global set by Task 6/7 `phase_database` |
| `PGSQL_READER_PASS` | global set by Task 8 pgsql phase (unset on mysql path) |
| `LARANODE_PG_PORT` | resolved global set by Task 2/8 (default 5432) |
| `run_scenario` | Task 1 `lib.sh`; this task adds `POST_ASSERT` hook |

_Produces:_

| Symbol | Description |
|--------|-------------|
| `phase_app()` | Guarded, idempotent PHP app provisioning |
| `phase_summary()` | Credential persistence + console print |
| `scenarios/rerun.sh` | Green double-run integration scenario |

---

- [ ] **Step 1: Extend `lib.sh` — add `POST_ASSERT` hook to `run_scenario`**

`run_scenario` in `local-dev/install-test/lib.sh` (built by Task 1) ends with an ok-check block. Add the following immediately before the final `if [ "$ok" = 1 ]` decision, so callers can inject extra in-container assertions:

```bash
# Optional hook: bash string evaluated in the container after standard assertions.
# A non-zero exit marks the scenario FAIL.  Callers set POST_ASSERT before sourcing.
if [ -n "${POST_ASSERT:-}" ]; then
    echo "   --- extra assertions (POST_ASSERT) ---"
    docker exec "$NAME" bash -c "${POST_ASSERT}" || ok=0
fi
```

Run the unit tests to confirm the existing helper suite is unaffected (no container needed):

```bash
bash local-dev/install-test/unit/test-helpers.sh
```

Expected: `ALL TESTS PASSED` in a few seconds on the host.

---

- [ ] **Step 2: Create the failing `rerun` scenario**

Create `local-dev/install-test/scenarios/rerun.sh` with the content below. Because the current installer re-generates `APP_KEY` on every run (`key:generate --force`) and overwrites `APP_URL` unconditionally, both `APP_KEY preserved` and `APP_URL preserved` checks will FAIL.

```bash
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
LARANODE_APP_URL=http://laranode.example.com LARANODE_UNATTENDED=1 \
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
INSTALLER_ENV="LARANODE_APP_URL=http://laranode.example.com LARANODE_UNATTENDED=1"
EXPECT_PORT=80
EXPECT_ENGINE=mysql

# ---- POST_ASSERT: extra idempotency checks after standard service/HTTP/login assertions ----
POST_ASSERT='
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
```

Make it executable:

```bash
chmod +x local-dev/install-test/scenarios/rerun.sh
```

---

- [ ] **Step 3: Verify the scenario FAILS before implementation**

Run the dispatcher:

```bash
bash local-dev/install-test/run.sh rerun
```

Expected (FAIL — current code):

```
[rerun] === Second installer run (run_scenario main) ===
...
   APP_KEY (run 1)               base64:AAAA...
   APP_KEY (run 2)               base64:BBBB...   ← different key
   APP_KEY preserved             FAIL (rotated!)
   APP_URL preserved             FAIL (got: http://1.2.3.4)
RESULT: FAIL
```

The second installer run may also exit non-zero because `CREATE USER 'laranode'` fails (user already exists) once `set -euo pipefail` is active. Either failure confirms the guard is needed before we proceed.

---

- [ ] **Step 4: Implement `phase_app` in the installer**

Add the following function to `laranode-scripts/bin/laranode-installer.sh` (after the `phase_php_node` function, before `phase_services`). Every guarded command either wraps the expected-idempotent failure with `|| true` (with an explanatory comment) or asserts exit 0 via `|| die`.

```bash
# ==============================================================================
# phase_app — guarded, idempotent application provisioning
# Depends on: PANEL_PATH (constant); phase_database (DB_* already in .env).
# ==============================================================================
phase_app() {
    log "App provisioning"

    # Hard guard: composer.json must exist — catches wrong PANEL_PATH or missing clone
    [ -f "${PANEL_PATH}/composer.json" ] \
        || die "composer.json not found at ${PANEL_PATH} — repo clone missing or PANEL_PATH wrong"

    cd "${PANEL_PATH}"

    log "Installing PHP dependencies (composer install)"
    composer install --no-interaction --optimize-autoloader

    # .env — copy example only when the file is absent; never clobber existing config
    if [ ! -f "${PANEL_PATH}/.env" ]; then
        cp "${PANEL_PATH}/.env.example" "${PANEL_PATH}/.env"
        log ".env created from .env.example"
    else
        log ".env already present — preserving existing configuration"
    fi

    # APP_KEY — generate ONLY when absent or blank.
    # key:generate --force rotates a valid key on every re-run; we never do that.
    if grep -q '^APP_KEY=base64:' "${PANEL_PATH}/.env"; then
        log "APP_KEY already set — preserving (idempotent re-run)"
    else
        log "APP_KEY not set — generating"
        /usr/bin/php8.4 artisan key:generate --force
    fi

    # ---- Resolve the canonical panel hostname ----
    # Priority: LARANODE_APP_URL env var > validated public IP from icanhazip.com
    local host_val=""
    if [ -n "${LARANODE_APP_URL:-}" ]; then
        host_val="${LARANODE_APP_URL%/}"   # strip any trailing slash
        log "Using LARANODE_APP_URL: ${host_val}"
    else
        local public_ip=""
        public_ip="$(curl -fsS icanhazip.com 2>/dev/null | tr -d '[:space:]')" || true
        [ -n "$public_ip" ] \
            || die "Public IP lookup failed (curl icanhazip.com returned empty). Set LARANODE_APP_URL=http://<host> to continue."
        host_val="http://${public_ip}"
        log "Resolved public IP: ${public_ip} → APP_URL=${host_val}"
    fi

    # Guard: host_val must be a proper URL, not a bare "http://" or empty scheme
    [[ "$host_val" =~ ^https?://.+$ ]] \
        || die "Resolved APP_URL '${host_val}' is not a valid URL. Set LARANODE_APP_URL=http://<hostname> and re-run."

    # Bare hostname (scheme stripped) — used for REVERB_HOST and VITE_REVERB_HOST
    local bare_host="${host_val#http://}"
    bare_host="${bare_host#https://}"

    # APP_URL — write only when absent or still the Laravel placeholder "http://localhost"
    local cur_app_url=""
    cur_app_url="$(grep -E '^APP_URL=' "${PANEL_PATH}/.env" | cut -d= -f2- | tr -d '"' | tr -d "'")"
    if [ -z "$cur_app_url" ] || [ "$cur_app_url" = "http://localhost" ]; then
        env_set APP_URL "$host_val" "${PANEL_PATH}/.env"
        log "APP_URL set to ${host_val}"
    else
        log "APP_URL already set to '${cur_app_url}' — preserving (re-run safe)"
    fi

    # ---- Database migrations — hard failure on exit != 0 ----
    log "Running database migrations"
    /usr/bin/php8.4 artisan migrate --force \
        || die "artisan migrate --force failed — verify DB_* in .env and check phase_database logs"

    # ---- One-time installs (explicitly tolerated idempotent failures) ----
    # storage:link: exits non-zero if the symlink already exists on re-run
    /usr/bin/php8.4 artisan storage:link          2>/dev/null || true
    # reverb:install: writes Reverb .env defaults (REVERB_HOST=localhost) on first run
    /usr/bin/php8.4 artisan reverb:install --no-interaction 2>/dev/null || true

    # REVERB_HOST — set only when absent or "localhost" (the default reverb:install writes)
    local cur_reverb=""
    cur_reverb="$(grep -E '^REVERB_HOST=' "${PANEL_PATH}/.env" | cut -d= -f2- | tr -d '"' | tr -d "'")"
    if [ -z "$cur_reverb" ] || [ "$cur_reverb" = "localhost" ]; then
        env_set REVERB_HOST "$bare_host" "${PANEL_PATH}/.env"
        log "REVERB_HOST set to ${bare_host}"
    else
        log "REVERB_HOST already set to '${cur_reverb}' — preserving"
    fi

    # VITE_REVERB_HOST — same logic as REVERB_HOST
    local cur_vite_reverb=""
    cur_vite_reverb="$(grep -E '^VITE_REVERB_HOST=' "${PANEL_PATH}/.env" | cut -d= -f2- | tr -d '"' | tr -d "'")"
    if [ -z "$cur_vite_reverb" ] || [ "$cur_vite_reverb" = "localhost" ]; then
        env_set VITE_REVERB_HOST "$bare_host" "${PANEL_PATH}/.env"
        log "VITE_REVERB_HOST set to ${bare_host}"
    else
        log "VITE_REVERB_HOST already set to '${cur_vite_reverb}' — preserving"
    fi

    # GPU detection — best-effort, non-fatal (command may not exist in all envs)
    /usr/bin/php8.4 artisan laranode:detect-gpu 2>/dev/null || true

    # ---- First-run seed sentinel: seed ONLY when no users exist ----
    # Uses the users table because it starts empty and is only populated by
    # laranode:create-admin (interactive, post-install). In the test harness
    # PRESETUP creates the admin before the second run, so user_count >= 1.
    log "Checking first-run seed sentinel (users table row count)"
    local user_count=1   # conservative default: don't reseed if count is unreadable
    user_count="$(/usr/bin/php8.4 artisan tinker \
        --execute="echo App\Models\User::count();" \
        2>/dev/null | tail -1 | tr -d ' \r\n')" || user_count=1

    if [ "$user_count" = "0" ]; then
        log "Users table empty — running db:seed (first install)"
        /usr/bin/php8.4 artisan db:seed --force \
            || die "artisan db:seed --force failed"
    else
        log "Users table has ${user_count} row(s) — skipping seed (idempotent re-run)"
    fi

    # ---- Front-end asset build ----
    log "Building front-end assets"
    npm install
    npm run build
}
```

---

- [ ] **Step 5: Implement `phase_summary` in the installer**

Add this function immediately after `phase_app` in the installer file:

```bash
# ==============================================================================
# phase_summary — persist all generated credentials + print operator summary
# Depends on: DB_ENGINE, LARANODE_DB_PASS, PGSQL_READER_PASS (may be unset),
#             LARANODE_PG_PORT (may be unset), PANEL_PATH, persist_secret helper.
# ==============================================================================
phase_summary() {
    log "Persisting credentials and printing install summary"

    # All generated secrets go to /root/.laranode-credentials (chmod 600 by persist_secret)
    persist_secret "# ===== Laranode install $(date -Iseconds) ====="
    persist_secret "Panel path:   ${PANEL_PATH}"
    local panel_url=""
    panel_url="$(grep -E '^APP_URL=' "${PANEL_PATH}/.env" | cut -d= -f2- | tr -d '"' | tr -d "'")"
    persist_secret "Panel URL:    ${panel_url}"
    persist_secret "DB engine:    ${DB_ENGINE}"

    if [ "${DB_ENGINE}" = "mysql" ]; then
        persist_secret "MySQL panel user:     laranode"
        persist_secret "MySQL panel password: ${LARANODE_DB_PASS}"
    else
        persist_secret "PgSQL panel user:     laranode"
        persist_secret "PgSQL panel password: ${LARANODE_DB_PASS}"
        persist_secret "PgSQL cluster port:   ${LARANODE_PG_PORT:-5432}"
    fi

    # PgSQL stats-reader role password (set only on pgsql path by Task 8)
    if [ -n "${PGSQL_READER_PASS:-}" ]; then
        persist_secret "PgSQL reader (laranode_pg_reader) password: ${PGSQL_READER_PASS}"
    fi

    persist_secret "# ============================================================"

    # Human-readable console output
    echo "========================================================================"
    echo "  Laranode install complete"
    echo "========================================================================"
    echo "  Panel URL:              ${panel_url}"
    echo "  DB engine:              ${DB_ENGINE}"
    if [ "${DB_ENGINE}" = "mysql" ]; then
        echo "  MySQL panel user:       laranode"
        echo "  MySQL panel password:   ${LARANODE_DB_PASS}"
    else
        echo "  PgSQL panel user:       laranode"
        echo "  PgSQL panel password:   ${LARANODE_DB_PASS}"
        echo "  PgSQL cluster port:     ${LARANODE_PG_PORT:-5432}"
    fi
    if [ -n "${PGSQL_READER_PASS:-}" ]; then
        echo "  PgSQL reader password:  ${PGSQL_READER_PASS}"
    fi
    echo ""
    echo "  All credentials saved to: /root/.laranode-credentials  (chmod 600)"
    echo ""
    echo "  Final step — create the panel admin account:"
    echo "    cd ${PANEL_PATH} && /usr/bin/php8.4 artisan laranode:create-admin"
    echo "========================================================================"
}
```

---

- [ ] **Step 6: Wire `phase_app` and `phase_summary` into `main`**

The `main` function in the installer (added by earlier tasks) calls phases in the contract order. Add the two new phases — `phase_app` after `phase_php_node` and `phase_summary` at the end — and ensure the source-guard is at the bottom of the file:

```bash
main() {
    preflight
    phase_packages
    phase_fetch_panel
    phase_database
    phase_webserver
    phase_php_node
    phase_app        # Task 9: guarded composer/env/.key/migrate/seed/build
    phase_services
    phase_summary    # Task 9: persist_secret + console print
}

# Source-guard: sourcing the file (unit tests) defines helpers without running install.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
```

Confirm the source-guard works (host, no container):

```bash
source laranode-scripts/bin/laranode-installer.sh
echo $?   # must be 0, no install runs
type phase_app | head -1   # must print: phase_app is a function
```

Expected:

```
0
phase_app is a function
```

---

- [ ] **Step 7: Run the `rerun` scenario — expect PASS**

```bash
bash local-dev/install-test/run.sh rerun
```

Expected (two full install runs, ~25 min total):

```
[1/5] Booting clean jrei/systemd-ubuntu:24.04...
[2/5] Injecting working tree...
[3/5] Running PRESETUP (first installer run)...
[rerun] === First installer run ===
== App provisioning ==
.env already present — preserving existing configuration
APP_KEY not set — generating
APP_URL set to http://laranode.example.com
...
[rerun] === Seeding admin after run 1 ===
[rerun] KEY1=base64:AAABBBCCC...
[rerun] URL1=http://laranode.example.com
[rerun] === PRESETUP done; run_scenario will now run the installer a second time ===
[3/5] Running main installer (second run)...
== App provisioning ==
.env already present — preserving existing configuration
APP_KEY already set — preserving (idempotent re-run)
APP_URL already set to 'http://laranode.example.com' — preserving (re-run safe)
...
Users table has 1 row(s) — skipping seed (idempotent re-run)
...
[4/5] Seeding admin (updateOrCreate — idempotent)...
[5/5] Assertions:
   apache2                    active
   mysql                      active
   php8.4-fpm                 active
   laranode-reverb            active
   laranode-queue-worker      active
   GET /login                 200
   admin login                yes
   --- extra assertions (POST_ASSERT) ---
   APP_KEY (run 1)               base64:AAABBBCCC...
   APP_KEY (run 2)               base64:AAABBBCCC...
   APP_KEY preserved             PASS
   APP_URL preserved             PASS (http://laranode.example.com)
RESULT: PASS — rerun scenario green.
```

If the run fails, keep the container for inspection:

```bash
KEEP=1 bash local-dev/install-test/run.sh rerun
docker exec -it laranode-install-test-rerun bash
# grep APP_KEY /home/laranode_ln/panel/.env
# cat /tmp/laranode-rerun-state
```

---

- [ ] **Step 8: Add `install-test-rerun` target to the Makefile**

In `local-dev/Makefile`, after the existing `install-test` target:

```makefile
install-test-rerun:
	bash local-dev/install-test/run.sh rerun
```

Also update the `.PHONY` line to include `install-test-rerun`:

```makefile
.PHONY: up provision sh verify test test-system build-assets sync-scripts logs nuke ssl-test install-test install-test-rerun
```

---

- [ ] **Step 9: Commit**

```bash
git add \
    laranode-scripts/bin/laranode-installer.sh \
    local-dev/install-test/lib.sh \
    local-dev/install-test/scenarios/rerun.sh \
    local-dev/Makefile

git commit -m "$(cat <<'EOF'
feat(installer): guarded phase_app + phase_summary, idempotent re-run

- composer install asserts composer.json exists first (die else)
- .env copied from .env.example only when absent; never clobbed
- APP_KEY generated only when absent/blank; --force never used on re-run
- APP_URL/REVERB_HOST/VITE_REVERB_HOST written only when absent or placeholder
  (http://localhost / localhost); LARANODE_APP_URL takes precedence over icanhazip
- migrate --force asserted exit 0 (die on failure)
- db:seed runs only when users table is empty (first-run sentinel)
- phase_summary persists all creds to /root/.laranode-credentials (chmod 600)
- scenarios/rerun.sh: boots one container, installs twice, asserts APP_KEY
  unchanged and custom APP_URL preserved across runs
- lib.sh run_scenario gains optional POST_ASSERT hook for extra in-container checks

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JfCWbrFv5vKToujYJAbLyu
EOF
)"
```

---

Now I have full context. Here is the plan section:

---

### Task 10: Full matrix gate + docs

**Files:**

- Modify: `local-dev/install-test/run.sh` — expand header comment to document dispatcher usage and list all scenario names
- Modify: `CLAUDE.md` — new "## Installer" section with env-var table, existing-services safety table, idempotency note, and install-test matrix commands
- Test: `local-dev/Makefile` — targets `install-test-unit`, `install-test`, `install-test-matrix` already in place from Task 1; exercised here as the hard gate (no Makefile changes)

**Interfaces:**

Consumes:
- `run_scenario` (defined in `local-dev/install-test/lib.sh`, Task 1) — invoked by all five scenario scripts
- Scenario files `local-dev/install-test/scenarios/{baseline,nginx80,mysql-rootpw,pgsql,rerun}.sh` — built across Tasks 2–9
- `local-dev/install-test/unit/test-helpers.sh` — host unit tests, Task 1
- Make targets `install-test-unit` / `install-test` / `install-test-matrix` — declared in `local-dev/Makefile`, Task 1
- Contract env vars: `SCENARIO`, `PRESETUP`, `INSTALLER_ENV`, `EXPECT_PORT`, `EXPECT_ENGINE`

Produces:
- All 5 scenarios green (matrix exits 0, "MATRIX: 5/5 PASS" in output)
- `CLAUDE.md` updated with Installer section (env-var table + existing-services table + matrix commands)
- `run.sh` header updated with dispatcher usage and scenario name list

---

- [ ] **Step 1: Preflight — host unit tests (no container, ~5 seconds)**

Verify the helper logic is sound before spending 30+ minutes on containers. Run from the repo root on the host machine:

```bash
make -f local-dev/Makefile install-test-unit
```

Expected output (exits 0):

```
ok: env_set add
ok: env_set replace
ok: version_ge true (3.1 >= 2.9)
ok: version_ge false (2.8 >= 2.9)
ok: choose env over default
ok: choose default in non-tty
6 tests, 0 failures.
```

If any assertion fails, open `local-dev/install-test/unit/test-helpers.sh` and diagnose before running containers.

---

- [ ] **Step 2: Full matrix gate (all 5 scenarios, ~30–60 min)**

```bash
make -f local-dev/Makefile install-test-matrix
```

This invokes `bash local-dev/install-test/run.sh matrix`, which runs all five scenario scripts sequentially with fail-fast disabled. Required terminal output (exits 0):

```
[matrix] running: baseline
...
[matrix] running: nginx80
...
[matrix] running: mysql-rootpw
...
[matrix] running: pgsql
...
[matrix] running: rerun
...

=== MATRIX RESULTS ===
  baseline      PASS
  nginx80       PASS
  mysql-rootpw  PASS
  pgsql         PASS
  rerun         PASS

MATRIX: 5/5 PASS
```

**Gate:** do not proceed to documentation steps until this exits 0.

**If a scenario fails:** rerun it in isolation with `KEEP=1` and inspect the container:

```bash
KEEP=1 bash local-dev/install-test/run.sh nginx80
docker exec -it laranode-install-test-nginx80 bash
# check logs
journalctl -xe
systemctl status apache2
cat /home/laranode_ln/panel/.env
```

Each scenario maps to the task that implemented it: `baseline` (Task 2), `nginx80` (Task 3), `mysql-rootpw` (Task 4), `pgsql` (Task 5 + Task 6), `rerun` (Task 7). Fix the root cause in the relevant task's deliverable (either `laranode-installer.sh` or the scenario file), re-run that single scenario until it passes, then re-run the full matrix.

---

- [ ] **Step 3: Update run.sh header to document dispatcher usage and scenario names**

The current header in `local-dev/install-test/run.sh` only describes the single-run baseline use. Replace the two usage-comment lines (currently lines 8–9) with the expanded block below. All other file content is unchanged — only the comment block in the file header is touched.

Current lines to replace:

```bash
#   bash local-dev/install-test/run.sh         # run + teardown
#   KEEP=1 bash local-dev/install-test/run.sh   # keep container for inspection
```

Replace with:

```bash
# Dispatcher:
#   bash local-dev/install-test/run.sh                        # baseline (default)
#   bash local-dev/install-test/run.sh <scenario>             # named scenario
#   bash local-dev/install-test/run.sh matrix                 # all 5; fail-fast off; summary at end
#   KEEP=1 bash local-dev/install-test/run.sh <scenario>      # keep container for inspection
#
# Scenarios: baseline | nginx80 | mysql-rootpw | pgsql | rerun
# Make shortcuts (run from repo root, not from inside local-dev/):
#   make -f local-dev/Makefile install-test-unit    # host helper tests, no container (~5 s)
#   make -f local-dev/Makefile install-test          # baseline only
#   make -f local-dev/Makefile install-test-matrix   # full 5-scenario matrix (~30-60 min)
```

---

- [ ] **Step 4: Add Installer section to CLAUDE.md**

In `CLAUDE.md`, locate the line `## Environment caveat` and its paragraph. Insert the following new section immediately after that paragraph closes and before the `## Architecture` heading. The text is complete — no placeholders.

```
## Installer

`laranode-scripts/bin/laranode-installer.sh` is a single-file, phased bash script
(`set -euo pipefail`; a source-guard at the bottom lets unit tests source it without
running `main`). It is **safe to run on hosts that already have services** — it never
rotates the system MySQL root password, never overwrites `000-default.conf`, and falls
back to `:8080` when `:80` is occupied.

### Env-var interface

| Variable | Default | Purpose |
|----------|---------|---------|
| `LARANODE_DB_ENGINE` | `mysql` | `mysql` or `pgsql` — only that engine's server package is installed |
| `LARANODE_HTTP_PORT` | auto (80 free → 80, else 8080) | Apache port the panel listens on |
| `LARANODE_MYSQL_ROOT_PASSWORD` | — | Required when existing MySQL root uses password auth (not `auth_socket`) |
| `LARANODE_PG_PORT` | auto (single cluster) | Disambiguate when multiple Postgres clusters exist on the same host |
| `LARANODE_APP_URL` | public IP via `icanhazip.com` | Sets `APP_URL`, `REVERB_HOST`, `VITE_REVERB_HOST` in `.env` |
| `LARANODE_REPO` | GitHub fork URL | Clone source; the install-test harness overrides this to the injected tree path |
| `LARANODE_UNATTENDED` | `0` | `1` = take all defaults, suppress all prompts and `confirm` gates |

### Safe on hosts with existing services

| Pre-existing condition | Installer behaviour |
|------------------------|---------------------|
| Apache / nginx on :80 | Panel vhost written to `laranode.conf` on :8080; existing server fully untouched |
| MySQL with a root password | Authenticates with `LARANODE_MYSQL_ROOT_PASSWORD`; root password **never changed** |
| Multiple Postgres clusters | `LARANODE_PG_PORT` required; only that cluster's socket is touched |
| System `php` symlink not 8.4 | `php8.4` packages installed additively; system default left unchanged; panel units use `/usr/bin/php8.4` |
| Node ≥ 20 already present | Warns and skips nodesource; existing Node binary used as-is |

Re-running the installer on an already-provisioned panel is **idempotent**: `APP_KEY` is
not regenerated if already set to a `base64:` value, `APP_URL` is not overwritten if
already a non-placeholder value, and `db:seed` is skipped when the `users` table is
non-empty.

### Install-test matrix

Clean-room integration tests in `local-dev/install-test/` boot one vanilla
`jrei/systemd-ubuntu:24.04` container per scenario, inject the repo, run the real
installer, and assert services active + HTTP 200 + admin login. Run from the repo root:

    make -f local-dev/Makefile install-test-unit    # host helper unit tests (no container, ~5 s)
    make -f local-dev/Makefile install-test          # baseline scenario only
    make -f local-dev/Makefile install-test-matrix   # all 5 scenarios (30–60 min)

Scenarios: `baseline` | `nginx80` | `mysql-rootpw` | `pgsql` | `rerun`.
Run or debug a single scenario:

    bash local-dev/install-test/run.sh pgsql
    KEEP=1 bash local-dev/install-test/run.sh pgsql   # keep container after run
```

---

- [ ] **Step 5: Re-run unit tests to confirm doc edit did not corrupt the file**

```bash
make -f local-dev/Makefile install-test-unit
```

Expected: same `6 tests, 0 failures.` output as Step 1. The unit tests source the installer file; if the CLAUDE.md edit accidentally truncated a shell file, this catches it immediately.

---

- [ ] **Step 6: Commit**

Stage only the two modified files:

```bash
git add local-dev/install-test/run.sh CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(installer): add env-var table, existing-service safety notes, and matrix usage

Updates CLAUDE.md with an Installer section covering the full LARANODE_* env-var
interface, a safety table for pre-existing services, idempotency guarantees, and
make targets for the 5-scenario install-test matrix. Expands the run.sh header
comment with dispatcher usage and all scenario names.

All 5 install-test scenarios (baseline, nginx80, mysql-rootpw, pgsql, rerun) PASS.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JfCWbrFv5vKToujYJAbLyu
EOF
)"
```

Verify the commit landed cleanly:

```bash
git show --stat HEAD
```

Expected: shows `CLAUDE.md` and `local-dev/install-test/run.sh` as the only changed files, no untracked leftovers.

---

**Acceptance criteria for Task 10:**

1. `make -f local-dev/Makefile install-test-unit` exits 0.
2. `make -f local-dev/Makefile install-test-matrix` exits 0 and prints `MATRIX: 5/5 PASS`.
3. `CLAUDE.md` contains an `## Installer` section with the full env-var table, the existing-services safety table, and the make target commands.
4. `local-dev/install-test/run.sh` header lists all five scenario names and the `matrix` dispatcher usage.
5. `git show --stat HEAD` shows exactly two files changed.
