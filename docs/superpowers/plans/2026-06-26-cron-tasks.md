# Cron Tasks — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each Laranode user a UI to manage scheduled cron jobs for their `{username}_ln` system account. The panel DB is the authoritative record; `laranode-cron.sh` syncs to the real crontab on every write. All mutations write an audit `Operation` row using the shipped foundation from `feature/platform-async-progress`.

**Architecture:** Controller (thin) → FormRequest (validation + cap check) → DB::transaction(CronJob create + Operation create + Service) → `laranode-cron.sh` via `Process::run`. Operations are synchronous (sub-second). Flash messages are sufficient feedback; no `OperationProgress` live UI.

**Key constraints:**
- `AllowedCronCommand` allows only `php /home/{username}_ln/...` (and artisan as a subset). No `wget`, no `curl` in v1.
- `laranode-cron.sh` validates each line (5-field schedule + command) AND validates `$SYSTEM_USER` ends in `_ln` and exists. It runs as `www-data` (sudoers: `(www-data)` not `(ALL)`).
- `store()` and `destroy()` are wrapped in `DB::transaction` (save-last pattern): DB row is only committed if the script succeeds.
- `index()` uses `CronJob::mine()->orderBy('id')->get()` — no extra `->where('user_id', ...)` after `scopeMine()` (that breaks admin impersonation).
- Per-user cap: 50 jobs, enforced in `StoreCronJobRequest::withValidator()`.
- `UNIQUE(user_id, schedule, command)` on the migration.
- System tests provision `testuser_ln` / `testuser2_ln` in `local-dev/entrypoint-setup.sh`.

**Tech stack:** Laravel 12, Pest 3, Inertia + React (JSX), `Process` facade, MySQL (prod) / SQLite `:memory:` (tests).
**Branch:** `feature/cron-tasks` (off `development`).
**Suite:** `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test'` (PowerShell for `make`/`docker compose`; any shell for `docker exec`).

---

> **Execution order:** Task 1 → Task 2 → Task 3 → Task 4 → Task 5 → Task 6 → Task 7. Each task depends on the previous.

---

### Task 1: `cron_jobs` migration + `CronJob` model

**Files:**
- Create: `database/migrations/XXXX_create_cron_jobs_table.php`
- Create: `app/Models/CronJob.php`
- Create: `tests/Feature/CronJobs/CronJobModelTest.php`

**Acceptance criteria:**
- Migration creates table with columns `id, user_id (FK→users, cascade), schedule(100), command(500), label(255 nullable), active(bool default true), timestamps`; index on `[user_id, active]`; unique on `[user_id, schedule, command]`.
- `CronJob` model: `$fillable = ['user_id', 'schedule', 'command', 'label', 'active']`; `$casts = ['active' => 'boolean']`; `belongsTo(User)`; `scopeMine` mirrors `Database::scopeMine` exactly (admins see all, non-admins see own `user_id`).
- Test: `php artisan test --filter=CronJobModelTest` passes — verifies `belongsTo`, `scopeMine` (non-admin sees 1, admin sees 2), `active` default, and that inserting a duplicate `[user_id, schedule, command]` throws a DB exception.

- [ ] Write failing test
- [ ] Write migration + model
- [ ] Verify test passes
- [ ] Commit: `feat(cron): cron_jobs migration + CronJob model`

---

### Task 2: Validation rules — `ValidCronExpression` + `AllowedCronCommand`

**Files:**
- Create: `app/Rules/ValidCronExpression.php`
- Create: `app/Rules/AllowedCronCommand.php`
- Create: `tests/Unit/ValidCronExpressionRuleTest.php`
- Create: `tests/Unit/AllowedCronCommandRuleTest.php`

**Acceptance criteria:**
- `ValidCronExpression` — accepts 5-field expressions with valid ranges (minute 0–59, hour 0–23, dom 1–31, month 1–12, dow 0–7), wildcards `*`, steps `*/n`, ranges `n-m`, comma lists. Rejects 4-field, 6-field, out-of-range values, non-numeric garbage.
- `AllowedCronCommand($user)` — accepts only commands starting with `php /home/{username}_ln/` (path must be within the user's own homedir). Rejects:
  - `wget` and `curl` (not in v1 allowlist)
  - `php -r`, `php -f` and any other flags that take a path argument
  - any shell metacharacter: `;`, `&&`, `||`, `|`, `>`, `<`, `` $(...) ``, backtick
  - PHP paths outside the user's homedir (e.g. `/home/other_ln/...`, `/etc/...`)
- Tests: `php artisan test --filter="ValidCronExpressionRuleTest|AllowedCronCommandRuleTest"` passes all dataset variants. Blocked dataset must include: `wget https://...`, `curl https://...`, `php -r 'echo 1;'`, `php /home/other_ln/a.php`, `php /home/alice_ln/a.php; rm -rf /`, `rm -rf /`.

- [ ] Write failing tests (with datasets for allowed and blocked)
- [ ] Write `ValidCronExpression` rule
- [ ] Write `AllowedCronCommand` rule (constructor takes `User $user`)
- [ ] Verify tests pass
- [ ] Commit: `feat(cron): ValidCronExpression + AllowedCronCommand rules (php-only v1)`

---

### Task 3: `StoreCronJobRequest` + `CronJobPolicy`

**Files:**
- Create: `app/Http/Requests/StoreCronJobRequest.php`
- Create: `app/Policies/CronJobPolicy.php`
- Create: `tests/Feature/CronJobs/CronJobPolicyTest.php`

**Acceptance criteria:**
- `StoreCronJobRequest::rules()` — `schedule` (required, max:100, `ValidCronExpression`), `command` (required, max:500, `AllowedCronCommand($this->user())`), `label` (nullable, string, max:255).
- `StoreCronJobRequest::withValidator()` — after-hook adds error on `command` if `CronJob::where('user_id', $this->user()->id)->count() >= 50`.
- `CronJobPolicy` — `delete(User, CronJob)` and `update(User, CronJob)` both return `allow()` when `$user->isAdmin() || $user->id === $cronJob->user_id`, `deny(...)` otherwise. Mirrors `WebsitePolicy` exactly.
- Tests: admin can delete any job; non-admin can delete their own, not another user's.
- Policy is discoverable automatically (no explicit `$policies` registration needed — verify `AuthServiceProvider` before adding).

- [ ] Write failing policy tests
- [ ] Write `CronJobPolicy` (register if needed)
- [ ] Write `StoreCronJobRequest`
- [ ] Verify tests pass
- [ ] Commit: `feat(cron): StoreCronJobRequest + CronJobPolicy`

---

### Task 4: `laranode-cron.sh` + sudoers drop-in + Services

**Files:**
- Create: `laranode-scripts/bin/laranode-cron.sh`
- Create: `etc/sudoers.d/laranode-cron`
- Modify: `laranode-scripts/bin/laranode-installer.sh` (add sudoers copy step)
- Modify: `local-dev/entrypoint-setup.sh` (provision `testuser_ln` + `testuser2_ln`)
- Create: `app/Services/CronJobs/CreateCronJobService.php` (includes `CreateCronJobException`)
- Create: `app/Services/CronJobs/DeleteCronJobService.php` (includes `DeleteCronJobException`)
- Create: `tests/Feature/CronJobs/StoreCronJobTest.php` (service-level tests via `Process::fake`)

**Acceptance criteria for `laranode-cron.sh`:**
- `set -euo pipefail` at top.
- User validation: rejects `$SYSTEM_USER` that does not end in `_ln`, does not exist (`id "$SYSTEM_USER"`), or is `root`. Exits non-zero without touching crontab.
- Sub-command `set <system_user> <tmp_file>`: reads lines from tmp file; validates each as `<5 fields> <TAB> <command>` with no embedded newlines — invalid lines abort with non-zero exit; strips old `# laranode-managed` lines using `grep -v "$MARKER" || true` (the `|| true` prevents non-zero exit on all-managed crontab); prepends fresh managed block; pipes to `crontab -u "$SYSTEM_USER" -`.
- Sub-command `remove <system_user>`: strips all managed lines; handles empty crontab via `crontab -l -u "$SYSTEM_USER" 2>/dev/null || true`.
- Sub-command `list <system_user>`: prints crontab (diagnostic only).

**Acceptance criteria for `etc/sudoers.d/laranode-cron`:**
- Content: `www-data ALL=(www-data) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-cron.sh`
- Run-as is `(www-data)` not `(ALL)` — the script itself uses `crontab -u $user`; sudo only elevates to www-data.

**Acceptance criteria for `local-dev/entrypoint-setup.sh`:**
- After the admin seeding block, add: `useradd -m -s /bin/bash testuser_ln 2>/dev/null || true` and the same for `testuser2_ln`. These accounts must exist before system tests run.

**Acceptance criteria for services:**
- `CreateCronJobService::handle()`: queries `CronJob::where('user_id', $user->id)->where('active', true)->get()`; writes `schedule\tcommand` lines to a `chmod(0600)` temp file; calls `Process::run(['sudo', bin_path.'/laranode-cron.sh', 'set', $user->systemUsername, $tmpFile])`; deletes temp file in `finally`; throws `CreateCronJobException` on `$result->failed()`.
- `DeleteCronJobService::handle()`: re-syncs crontab using remaining active jobs (the controller deletes the DB row after calling this service, inside the transaction). Does NOT delete the DB row itself.
- Tests (`Process::fake`): `CreateCronJobService` calls script with correct args (system username, tmp file); fails → throws `CreateCronJobException`; `DeleteCronJobService` calls `set` with the remaining job list.

- [ ] Write `laranode-cron.sh` (set/remove/list with user validation + line validation + pipefail-safe grep)
- [ ] Write `etc/sudoers.d/laranode-cron` (run-as www-data)
- [ ] Add sudoers copy step to `laranode-installer.sh`
- [ ] Add `testuser_ln` / `testuser2_ln` provisioning to `local-dev/entrypoint-setup.sh`
- [ ] Write failing service tests
- [ ] Write `CreateCronJobService` + `DeleteCronJobService`
- [ ] Verify tests pass
- [ ] Commit: `feat(cron): laranode-cron.sh + sudoers drop-in + Create/DeleteCronJobService`

---

### Task 5: `CronJobsController` + routes + HTTP feature tests

**Files:**
- Create: `app/Http/Controllers/CronJobsController.php`
- Modify: `routes/web.php`
- Create: `tests/Feature/CronJobs/CronJobControllerTest.php`

**Acceptance criteria:**
- `index()`: `CronJob::mine()->orderBy('id')->get()` — NO extra `->where('user_id', ...)` after `scopeMine()`. Returns Inertia `CronJobs/Index` with `cronJobs` prop.
- `store()`: wrapped in `DB::transaction`. Creates `CronJob`, creates `Operation` (type `cron.create`), calls `markRunning()`, calls `CreateCronJobService::handle()`, calls `markFinished(0)`, flashes success. On `CreateCronJobException`: `markFinished(1)`, flash error, transaction rolls back `CronJob` row (Operation row must be saved outside transaction or before rollback — save `$op->markFinished(1)` after the transaction catches the exception, not inside it).
- `destroy()`: `Gate::authorize('delete', $cronJob)`. In `DB::transaction`: creates `Operation` (type `cron.delete`), `markRunning()`, calls `DeleteCronJobService::handle()`, `$cronJob->delete()`, `markFinished(0)`. On exception: `markFinished(1)`, flash error, transaction rolls back (DB row preserved).
- `toggleActive()`: `Gate::authorize('update', $cronJob)`. Flips `$cronJob->active`, calls `CreateCronJobService` to re-sync. Creates `Operation` (type `cron.toggle`). On failure, reverts `active` to original value.
- Routes: resource `/cron-jobs` (except create/edit/show) + `POST /cron-jobs/{cronJob}/toggle` named `cron-jobs.toggle`.

**Tests (all using `Process::fake()`):**
- `index` → renders `CronJobs/Index` with `cronJobs` prop (Inertia assert).
- `store` valid → DB row created + `Operation` `type=cron.create` `status=succeeded` → redirect.
- `store` invalid schedule → 422.
- `store` disallowed command (`wget`, `curl`, metachar) → 422.
- `store` cap exceeded (51st job) → 422.
- `store` script failure → `Operation.status=failed`; no `CronJob` row in DB.
- `destroy` own job → DB row gone + `Operation` `type=cron.delete` `status=succeeded`.
- `destroy` non-owner → 403; DB row untouched.
- `toggleActive` own job → `active` flipped + `Operation` `type=cron.toggle` `status=succeeded`.
- `toggleActive` non-owner → 403.
- `index` as non-admin sees only own jobs (not other users').

- [ ] Write failing HTTP tests
- [ ] Add routes to `routes/web.php`
- [ ] Write `CronJobsController`
- [ ] Verify tests pass
- [ ] Run Pint on new PHP files
- [ ] Commit: `feat(cron): CronJobsController (index/store/destroy/toggleActive) + routes`

---

### Task 6: React UI — `Index.jsx` + `CreateCronJobForm.jsx` + nav link + Vitest

**Files:**
- Create: `resources/js/Pages/CronJobs/Index.jsx`
- Create: `resources/js/Pages/CronJobs/Partials/CreateCronJobForm.jsx`
- Modify: `resources/js/Layouts/Partials/SidebarNavi.jsx`
- Create: `resources/js/Pages/CronJobs/CronJobs.test.jsx`

**Acceptance criteria:**
- `Index.jsx` receives `cronJobs` prop (array). Table columns: schedule, command, label, active toggle button (green "Active" / grey "Paused"), delete button. Uses `AuthenticatedLayout`. Inline form at top via `<CreateCronJobForm />`.
- `CreateCronJobForm.jsx` — preset `<select>` (`* * * * *`, `0 * * * *`, `0 2 * * *`, `0 0 * * 1`, `0 0 1 * *`, `Custom…`); when Custom selected, shows free-text input. Command text input. Label text input. Submit calls `router.post(route('cron-jobs.store'), { schedule, command, label })`.
- Nav link in `SidebarNavi.jsx` — "Cron Jobs" using an existing icon from the already-imported `react-icons` set. Visible to all auth'd users. Placed after MySQL DBs entry.
- Vitest tests: (1) renders cron job rows and the add-form button; (2) submitting the form calls `router.post` with the correct data.
- `npm run build` succeeds with no import errors.

- [ ] Write failing Vitest tests
- [ ] Write `CreateCronJobForm.jsx`
- [ ] Write `Index.jsx`
- [ ] Add nav link to `SidebarNavi.jsx`
- [ ] Verify Vitest tests pass (`npm run test`)
- [ ] Build assets (`npm run build`)
- [ ] Commit: `feat(cron): CronJobs UI (Index + CreateCronJobForm) + nav link + Vitest`

---

### Task 7: System test (`LARANODE_SYSTEM_TESTS=1`) + final gate

**Files:**
- Create: `tests/Feature/CronJobs/CronJobSystemTest.php`

**Acceptance criteria:**
- System test is gated: `if (!env('LARANODE_SYSTEM_TESTS')) $this->markTestSkipped(...)`.
- Test 1 (`testuser` / `testuser_ln`): `CreateCronJobService::handle()` → `crontab -l -u testuser_ln` contains the entry + `# laranode-managed`.
- Test 2 (`testuser2` / `testuser2_ln`): create then delete → entry removed from crontab.
- Test 3 (empty crontab): run `laranode-cron.sh set testuser_ln <empty_tmp_file>` directly; assert exit 0 and crontab is empty (no crash on fresh user with no crontab).
- Test 4 (invalid user): run `laranode-cron.sh set notanln_user <tmp_file>`; assert exit non-zero (user validation fires).
- Standard suite (no flag): `php artisan test` → all green, zero failures, system tests marked skipped.
- System suite: `LARANODE_SYSTEM_TESTS=1 php artisan test --filter=CronJobSystemTest` → 4 passing inside container.
- Pint clean on all new PHP.
- `php artisan schedule:list` still shows the existing `model:prune --model=App\Models\Operation` daily entry.

- [ ] Write `CronJobSystemTest.php`
- [ ] Run standard suite: all green
- [ ] Run system suite inside container: 4 passing
- [ ] Run Pint on all new PHP files
- [ ] Verify `schedule:list` unchanged
- [ ] Commit: `test(cron): system test for real crontab create/delete (LARANODE_SYSTEM_TESTS=1)`

---

## Back-compat / Migration Notes

- No changes to existing models (`User`, `Website`, `Database`, `Operation`).
- `Operation` rows with `type=cron.*` render automatically in `/admin/operations` via the generic table.
- `bootstrap/app.php` scheduler hook already in place from `feature/platform-async-progress` — no change.
- Existing `{username}_ln` crontab entries added manually are preserved: `laranode-cron.sh` only touches `# laranode-managed` lines.
- The `create_cron_jobs_table` migration is purely additive.
