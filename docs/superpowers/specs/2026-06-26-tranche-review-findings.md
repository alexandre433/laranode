# Tranche review findings — design+plan drafts (2026-06-26)

- **Source:** `review-tranche-plans` workflow — 5 adversarial reviewers (sonnet, high effort), one per feature, verifying each draft spec+plan against the live codebase, the architecture, and (for db) the fixed seam decisions.
- **Outcome:** db, backups, cron-tasks, user-analytics = **major-fixes**; notifications = **minor-fixes**. None are build-ready as drafted. The drafts remain useful as research input; this file drives the revision pass.
- **Convention below:** 🔴 security · 🟠 correctness · 🟡 missing/test gap · ❓ open design decision (needs user). Each ❓ carries a **recommended default**.

---

## #2 db-relational-engines — major-fixes

**Must-fix**
- 🔴 charset/collation are raw-interpolated into `CREATE/ALTER DATABASE` (MySQL can't bind these). Add an **allowlist** validation rule (validate against `information_schema.character_sets` / `collations`, or `regex:/^[A-Za-z0-9_]+$/`) in both Create/Update requests. The password fix alone is insufficient.
- 🔴 Postgres password passed as a positional `argv` to the sudo script → visible in `ps aux` / `/proc/<pid>/cmdline`. Pass via **stdin** (or a 0600 temp file), never argv.
- 🔴 `$$`-quoting in `laranode-postgres.sh` breaks for passwords containing `$$`. Use a unique tag (`$pw$`) or stdin via `psql`.
- 🟠 `mysql.*` back-compat must be **same-handler route aliases** (point the old URIs at `DatabasesController`), NOT `301` — a 301 on POST/PATCH/DELETE is converted to GET by clients. (Direct violation of the fixed decision.)
- 🟠 `pgsql` connection collision: `config/database.php` already defines `pgsql` on `DB_*` env. Add a **separate named connection** (e.g. `pgsql_admin`/`pgsql_stats` on `PGSQL_*`) instead of silently relying on / mutating the existing one.
- 🟠 Anti-injection test uses `DB::pretend()` + `listen()`, which logs nothing → vacuous pass. Capture real bound SQL another way.
- 🟠 `GetDatabasesWithStats` switching `where(user_id)` → `scopeMine()` silently changes admin behavior (admins see all DBs). Decide + test both paths.
- 🟡 `.env.example` not updated with the new `MYSQL_ADMIN_*` / `PGSQL_*` vars. No rollback on PostgresDriver partial create. No test for empty `available()` (no engine installed). Backfill test doesn't actually test pre-existing null rows.

**Open decisions**
- ❓ `mysql_admin` credentials source. **Default:** dedicated `MYSQL_ADMIN_*` env on a `mysql_admin` connection; fall back to the app connection only if unset, documented in `.env.example`.
- ❓ MariaDB service-name detection (Ubuntu MariaDB may register as `mysql`). **Default:** detect via `mysqld --version` string / `systemctl is-active mariadb OR mysql`, map both to the MySQL driver; treat them as one slot on :3306.
- ❓ Postgres DB-user isolation (`REVOKE CONNECT ... FROM PUBLIC`). **Default:** yes — revoke PUBLIC, grant the owning role explicitly (match MySQL's explicit-grant model); add an integration test.
- ❓ stats N+1 (per-row driver `stats()`). **Default:** acceptable for v1 (small DB counts); add a `// known: batch later` note + cache per request.

---

## #9 backups — major-fixes

**Must-fix**
- 🔴 restore `DB::statement("CREATE DATABASE \`{$newTarget}\`")` is backtick-injectable. Validate `new_target` as a strict identifier (`/^[A-Za-z0-9_]{1,64}$/`) in the FormRequest AND the job.
- 🔴 S3 creds land in the `jobs` table payload in plaintext (no at-rest encryption configured). Pass via config/encrypted-cast, not the job payload; or document + encrypt.
- 🔴 DB password passed as positional arg to `laranode-db-backup.sh` (ps-visible). Use `--defaults-extra-file` / `MYSQL_PWD` inside the script.
- 🟠 local disk: `Storage::disk('local')` = `storage/app/private`, not the homedir. Define a **`backups` disk** in `config/filesystems.php` (configurable root) and use it in job + download + delete.
- 🟠 `league/flysystem-aws-s3-v3` is **not** in `composer.json` — every S3 path throws. Add `composer require` as an explicit task.
- 🟠 S3 backups store `disk_name=null` → download/delete fall back to `local` and fail. Persist the resolved disk key on the `Backup` row.
- 🟠 Missing `ScheduledBackupPolicy` → `Gate::authorize('delete', $scheduledBackup)` is unguarded. Add it (or inline ownership check).
- 🟠 `RunScheduledBackupsJob` (everyMinute) can double-fire under a slow queue. Add `ShouldBeUnique` or a `last_run_at` guard.
- 🟡 Restored DB is orphaned (no `databases` row, no per-site user). `laranode-restore-files.sh` + its sudoers entry buried in a Task-6 note. No nav link. Redundant sudoers drop-in (existing `*.sh` wildcard already grants it) — narrow the wildcard or drop the theatre. Orphan-file cleanup on prune.

**Open decisions**
- ❓ File-backup scope: `websiteRoot` vs `fullDocumentRoot`. **Default:** `websiteRoot` (captures configs/includes outside docroot) — close the open question as decided.
- ❓ Restore should re-provision a panel-managed DB (row + per-site user) via `CreateDatabaseService`, not a bare `CREATE DATABASE`. **Default:** yes — route restore through the DB subsystem so the result is panel-manageable.
- ❓ Large-backup download (stream-through-PHP vs presigned S3 URL). **Default:** presigned URL for S3, streamed for local; no hard size cap v1.

---

## #10 cron-tasks — major-fixes

**Must-fix**
- 🔴 `AllowedCronCommand` permits `wget -O <path>` → arbitrary file write. Block flags that take a path (`-O`, `-P`, `--output-document`, …) or drop `wget` from the allowlist.
- 🔴 sudoers `www-data ALL=(ALL) NOPASSWD: …laranode-cron.sh` lets www-data run the script **as root** (`sudo -u root`). Restrict run-as to `(root)` only is still too broad — the script must itself refuse any target but the intended `{username}_ln`, and validate the target user is a panel-owned `_ln` account.
- 🔴 `laranode-cron.sh` appends unvalidated lines to the crontab. Validate each line is exactly `5-field schedule + command`, no embedded newlines, before install (the spec required this; the impl skipped it).
- 🟠 `DeleteCronJobService` deletes the row before the script runs → diverged state on failure. Delete only after script success (or restore on exception); wrap store() in a transaction (mirror `CreateWebsiteService` save-last).
- 🟠 `index()` adds `->where('user_id', …)` after `scopeMine()` → breaks admin impersonation (shows admin's own empty list). Remove it.
- 🟠 `grep -v "$MARKER" || true` inside `$(...)` under `set -euo pipefail` can silently drop all manual crontab lines. Restructure.
- 🟡 No DB transaction; no toggle/index 403 + scoping tests; no UNIQUE (user_id, schedule, command); local-dev `testuser_ln`/`testuser2_ln` accounts not provisioned; no edit/update path.

**Open decisions**
- ❓ Command allowlist breadth (php / node / python3 / bash / wget?). **Default:** `php` + `artisan` (homedir-scoped) only for v1; everything else opt-in later. Narrow surface beats broad.
- ❓ Per-user job cap. **Default:** cap at 50/user (cheap DoS guard).

---

## #12 notifications — minor-fixes

**Must-fix**
- 🔴 `webhook_url` SSRF: no scheme/IP validation. Validate `http(s)` only + reject RFC-1918/loopback in `WebhookChannel::send()`.
- 🔴 `webhook_url` leaked to the browser via the shared `auth.user` Inertia prop on every page. Add to `User::$hidden`.
- 🟠 `read-all` route registered after `{id}/read` → `markAllRead` unreachable (tests pass via named routes, masking it). Register literal segment first.
- 🟠 `Website::user()` selects `['id','username','role']` — omits `email`; mail channel sends to blank address. Add `email`.
- 🟠 `ProfileUpdateRequest` doesn't permit `webhook_url` → silently dropped on save. Add the rule (or a dedicated request).
- 🟠 `NotificationCreated` is `ShouldBroadcastNow`; a Reverb outage throws inside the queued notification → `failed_jobs`. Wrap dispatch in try/catch.
- 🟡 `SslIssuedNotification` declared a "live source" but never dispatched — wire it in `GenerateSslOperationJob` or mark it a stub. WebhookChannel FQCN leaked as external channel key — use a short alias. `.skip()`-ed mark-read test vs the "zero skips" gate. Missing index on `notifications(notifiable_type, notifiable_id, read_at)`.

**Open decisions**
- ❓ `webhook_url` encryption at rest. **Default:** encrypt (encrypted cast) — it's a user-controlled callback secret.

---

## #13 user-analytics — major-fixes

**Must-fix**
- 🟠 **Wrong Apache log path** — the vhost template logs one shared `/home/{user}_ln/logs/apache-access.log`, not `/var/log/apache2/{url}-access.log`. Read the shared log (attribute to the user), or change the template to per-domain. As drafted every count is null.
- 🟠 **`awk '/Average/ {print $3+$5}'` in a double-quoted PHP string** → PHP interpolates `$3`/`$5` to empty before the shell sees them. Single-quote or escape `\$`. `Process::fake()` masks this entirely.
- 🟠 `User::databases()` relation does **not** exist → `getQuotaSummary()` fatals at runtime. Required (not "if missing") edit + test.
- 🔴 `scopeMine()` admin-passthrough on `UserResourceSnapshot`/`UserSiteStat` is a multi-tenant footgun — analytics rows are private, but `mine()` returns all rows for admins. Use explicit `where('user_id', …)` in the service AND remove/guard the admin passthrough on these models; test `count===1` for admins.
- 🟠 Null `ssl_expires_at` → `new Date(null) - now()` is hugely negative → false "expiring" warning for every SSL-less site. Guard null in the component + add a test.
- 🟠 Vacuous failure test (`toBeIn(['succeeded','failed'])`). Decide du-failure semantics (throw→failed, no row) and assert exactly one outcome.
- 🟡 Scheduler `User::where('role','user')->each()` loads all users (no chunking); the `events()`-based scheduler test was already known-flaky in full-suite (use `schedule:list`); no system test exercises real du/sar/wc; per-DB size promised but absent.

**Open decisions**
- ❓ Include host-global CPU/mem for non-admins at all (it's host-wide, not per-user — misleading). **Default:** omit CPU/mem from the user view v1; keep disk/bandwidth/quota/SSL which are genuinely per-user-attributable.
- ❓ Rollup cadence daily vs hourly. **Default:** daily for resource snapshot, hourly for site disk/traffic (changes fast).
- ❓ Host-level `/proc/net/dev` bandwidth labelled as user bandwidth. **Default:** omit bandwidth v1 (can't attribute per-user) until per-vhog accounting exists.

---

## Cross-cutting

- **Plans are over-specified** — all five embed speculative implementation code instead of a concise phased task list with acceptance criteria (the template's shape). Revision should trim to tasks + acceptance, not full code.
- **Recurring real bugs:** secrets passed as process argv (db, backups, pg); raw SQL interpolation (db charset/collation, backups restore); `scopeMine()` admin-passthrough used where per-user isolation is required (user-analytics); the redundant sudoers drop-in vs the existing `*.sh` wildcard (backups, cron) — the wildcard should be narrowed once, project-wide.
- **Process::fake() / vacuous tests** masked several of the above — revised plans must include at least one real-system (LARANODE_SYSTEM_TESTS) integration test per system-touching path.

---

# Post-revision re-review (2026-06-26)

Revision pass applied the must-fixes + defaults and trimmed the plans. Re-review verdicts: **all five now `minor-fixes`** — no `major`, no critical security blockers (all original injection/SSRF/privilege/secret issues confirmed resolved). Remaining punch-list below — **resolve at build time** (each becomes a builder acceptance item). 🟠 = genuine bug, ▫ = spec clarification.

## #2 db-relational-engines
- ▫ Postgres password: spec lists TWO methods (`\password` stdin vs dollar-tag `ALTER ROLE`). Pick ONE (dollar-tag `ALTER ROLE` fed via stdin/0600 file); never pass via `psql` argv.
- 🟠 Provision the `laranode_pg_reader` stats role (CREATE ROLE + GRANT CONNECT + SELECT on `pg_stat_*`) in `laranode-installer.sh` AND `local-dev/entrypoint-setup.sh`, or `PostgresIntegrationTest` fails.
- 🟠 Postgres service detection: Ubuntu uses the versioned unit `postgresql@16-main`, not `postgresql` — `available()` must try both candidate names.
- ▫ `mariadb_admin` connection must set `driver=mariadb` (not `mysql`).
- ▫ Add `EngineManager::for(null|'')` → mysql guard test; cache `available()` per request (avoid 3× `systemctl` per FormRequest).
- ▫ Task 9: atomically REPLACE the old `mysql.*` route block (delete + add aliases in one commit) — avoid double-registration. Fix the "admin listing preserved" wording (it's a corrected bug: admins now see all rows).

## #9 backups
- 🟠 S3 disk in the queue worker: `BackupJob`/`RestoreJob` run in the worker where the request/scheduler-registered `backups_s3` disk does NOT exist. The job must re-register the disk at `run()` start from encrypted creds on the `ScheduledBackup`/`Backup` row. Make concrete or all S3 paths throw.
- ▫ Nav link goes in `resources/js/Layouts/Partials/SidebarNavi.jsx`, not `AuthenticatedLayout.jsx`.
- ▫ Spec says "3 scripts" but there are 4 backup scripts in the sudoers drop-in. Declare `dragonmantank/cron-expression` directly (or validate via native Schedule).

## #10 cron-tasks
- 🟠 Create the `Operation` row BEFORE `DB::transaction` (a rollback inside the txn destroys it and `markFinished` no-ops). Txn wraps only `CronJob::create` + sync.
- 🟠 `DeleteCronJobService` must EXCLUDE the job being deleted from the re-sync (delete row first, then re-sync; restore on failure).
- 🟠 `local-dev/entrypoint-setup.sh` must grant the `laranode-cron.sh` sudo (currently only the installer is updated) or system tests have no sudo.
- ▫ Wrap `toggleActive` in a transaction; remove the phantom `DeleteCronJobRequest` reference; document that the per-user cap check uses the actor id under impersonation.

## #12 notifications
- ▫ Document the DNS-rebinding TOCTOU caveat (low severity self-hosted) + optionally a socket-bound HTTP client; add an IPv6 `http://[::1]/` SSRF test case.
- ▫ Specify `SslExpiringNotification` payload (`toDatabase` keys); note the dual scheme-validation (controller 422 + channel guard) is intentional defence-in-depth.

## #13 user-analytics
- 🟠 `websiteRoot` null-path (revision regression): `UserSiteStatsService` must eager-load `->with('user')` OR build the path from `$user->homedir.'/domains/'.$site->url` — else `du` fails in prod (`Process::fake` masks it).
- ▫ Align test inventory (`RollupServiceTest` listed in spec); parse `wc -l` via `(int) trim($output)` (leading whitespace).
