# Sub-project #10 — Per-user crontab CRUD (`cron-tasks`)

- **Date:** 2026-06-26
- **Status:** Revised — security and correctness fixes applied
- **Roadmap:** Phase N, sub-project #10 of `docs/superpowers/specs/2026-06-25-laranode-feature-roadmap.md`
- **Branch:** `feature/cron-tasks` (off `development`)

## Goal

Let each Laranode user manage scheduled cron jobs for their `{username}_ln` system account via the panel UI. The panel DB is the source of truth; a new `laranode-cron.sh` script (set / remove / list) syncs to the real crontab on every write. All mutations write an audit `Operation` row using the shipped foundation from `feature/platform-async-progress`.

**Why:** cron is the standard per-user scheduling tool on Ubuntu 24.04. Exposing it through the panel (with a sanitised, allowlisted interface) lets users schedule PHP scripts and artisan commands without SSH access. The per-user crontab is isolated to `{username}_ln` — it never touches root's crontab or any other user's.

## Architecture

Pattern: **Controller → FormRequest → `CronJobService` (sync, fast) → `laranode-cron.sh` via `Process::run` → audit `Operation` row**. Not an `OperationJob` because crontab writes are sub-second; using `OperationJob` would be over-engineering. The controller creates the `Operation` row inline and drives its lifecycle directly (queued → running → succeeded/failed), matching the audit guarantee without queue latency.

```
CronJobsController → StoreCronJobRequest / DeleteCronJobRequest
  → (DB transaction) CronJob::create + Operation::create + CreateCronJobService::handle()
      → Process::run(['sudo', bin_path.'/laranode-cron.sh', 'set', systemUsername, tmpFile])
  ← redirect with flash.success / flash.error
```

The `CronJob` Eloquent model is the authoritative record. `laranode-cron.sh` is the effector: it writes the crontab file and never stores state itself.

## Data Model

### `cron_jobs` table (new migration)

| Column | Type | Notes |
|---|---|---|
| `id` | bigIncrements | |
| `user_id` | foreignId → `users.id` cascade | owner |
| `schedule` | string(100) | cron expression, e.g. `0 2 * * *` |
| `command` | string(500) | the shell command to run |
| `label` | string(255), nullable | human description |
| `active` | boolean, default true | whether to include in real crontab |
| `timestamps` | | |

Indexes:
- `['user_id', 'active']`
- `UNIQUE ['user_id', 'schedule', 'command']` — prevents accidental duplicates

**Per-user cap: 50 active cron jobs.** The `store()` action rejects with a validation error (422) when the user already has 50 `cron_jobs` rows.

No `status` column on the job itself — the crontab either has the entry or not. Execution outcomes live in system logs, not in the panel (out of scope).

### `CronJob` model — `App\Models\CronJob`

- `$fillable`: `user_id, schedule, command, label, active`.
- `$casts`: `active => boolean`.
- `belongsTo(User)`.
- `scopeMine(Builder): Builder` — mirrors `Database::scopeMine` exactly: `$query->when($user && !$user->isAdmin(), fn($q) => $q->where('user_id', $user->id))`. Non-admins see only their own rows; admins see all.
- **No** `MassPrunable` here — cron job records persist until the user deletes them.

### `Operation` row (reuse existing model)

Every write mutation (`store`, `destroy`, `toggleActive`) creates one `Operation` row with:
- `type`: `cron.create` | `cron.delete` | `cron.toggle`
- `target`: `{username_ln}` (the system user the crontab belongs to)
- `user_id`: the acting panel user

The controller drives the lifecycle directly:
```php
$op = Operation::create(['user_id' => $userId, 'type' => 'cron.create', 'target' => $systemUser, 'status' => 'queued']);
$op->markRunning();
// ... run service ...
$op->appendOutput($result->output());
$op->markFinished($exitCode);
```

## Components (real file names)

### `laranode-scripts/bin/laranode-cron.sh` (new)

Three sub-commands:
- `set <system_user> <tmp_file>` — reads newline-separated `schedule\tcommand` pairs from the tmp file, validates each line, rebuilds the managed block atomically.
- `remove <system_user>` — removes all `# laranode-managed` lines (used when a user has no active jobs).
- `list <system_user>` — prints the current crontab (diagnostic / test use).

The script tags each managed line with `# laranode-managed`. Lines without this marker (manual entries) are preserved unchanged.

**Full-rebuild strategy:** the script rebuilds the entire managed block on every write using all active jobs passed from PHP. This avoids stale state from partial failures.

**Input validation inside the script:** before writing any entry to crontab, the script validates that each line from the tmp file matches exactly 5 schedule fields plus a command (no embedded newlines, no shell metacharacters). Invalid lines cause the script to exit non-zero without modifying the crontab.

**Empty-crontab safety under `set -euo pipefail`:** the script must use `crontab -l -u "$user" 2>/dev/null || true` to avoid a non-zero exit when the crontab is empty. The `grep -v "$MARKER"` pipeline must be written as `grep -v "$MARKER" || true` to avoid failing when all lines match (empty manual section).

**User validation:** the script validates that `$SYSTEM_USER` ends in `_ln` and that the user exists (`id "$SYSTEM_USER"` succeeds). It refuses to operate on `root` or any user not matching the `_ln` suffix pattern. This check happens before any crontab operation.

### `etc/sudoers.d/laranode-cron` (new drop-in)

```
www-data ALL=(www-data) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-cron.sh
```

Key points:
- **`(www-data)` not `(ALL)`** — the script runs as `www-data`, not as root or any arbitrary user. The `crontab -u $user` call within the script is what modifies the target user's crontab; `sudo` does not grant run-as-target.
- Added as a separate drop-in, not appended to the monolithic installer line.
- The installer (`laranode-installer.sh`) must copy this file to `/etc/sudoers.d/laranode-cron` with mode `0440`.

### `App\Services\CronJobs\CreateCronJobService` (new)

`__construct(CronJob $cronJob, User $user)` + `handle(): void`. Writes all active jobs for `$user` to a temp file, calls `laranode-cron.sh set`. Throws `CreateCronJobException` on non-zero exit. The temp file is written with `chmod(0600)` and always deleted in a `finally` block.

```php
class CreateCronJobException extends \Exception {}
class CreateCronJobService { ... }
```

### `App\Services\CronJobs\DeleteCronJobService` (new)

`__construct(CronJob $cronJob, User $user)` + `handle(): void`. The controller wraps `store()`/`destroy()` in a DB transaction so that the DB row is only deleted if the script succeeds (save-last pattern). The service itself does NOT delete the DB row — the controller handles that after a successful `handle()` call so the transaction can be rolled back on script failure.

```php
class DeleteCronJobException extends \Exception {}
class DeleteCronJobService { ... }
```

### `App\Http\Controllers\CronJobsController` (new)

- `index(Request $request): Response` — `CronJob::mine()->orderBy('id')->get()` → Inertia `CronJobs/Index`. **No additional `->where('user_id', ...)` after `scopeMine()`** — `scopeMine()` already handles user scoping for non-admins. Adding a redundant `where(user_id)` would break admin impersonation (the admin would see only their own jobs instead of the impersonated user's jobs when viewing the page on behalf of a user).
- `store(StoreCronJobRequest $request): RedirectResponse` — wrapped in `DB::transaction`: create `CronJob`, create `Operation`, `markRunning()`, call `CreateCronJobService::handle()`, `markFinished(0)`, flash success. On `CreateCronJobException`: `markFinished(1)`, flash error, transaction rolls back (CronJob row deleted).
- `destroy(Request $request, CronJob $cronJob): RedirectResponse` — `Gate::authorize('delete', $cronJob)`. Wrapped in `DB::transaction`: create `Operation`, `markRunning()`, call `DeleteCronJobService::handle()` (which re-syncs crontab without the deleted job), then `$cronJob->delete()`, `markFinished(0)`. On exception: `markFinished(1)`, flash error, transaction rolls back (CronJob row preserved).
- `toggleActive(Request $request, CronJob $cronJob): RedirectResponse` — `Gate::authorize('update', $cronJob)`. Flip `active`, re-sync, create audit `Operation` with type `cron.toggle`. On script failure, revert `active` in DB.

Route model binding for `CronJob` uses the global policy (`CronJobPolicy`) for authorization — non-admins that try to act on another user's job are rejected by `Gate::authorize`.

### `App\Http\Requests\StoreCronJobRequest` (new)

```php
public function rules(): array {
    return [
        'schedule' => ['required', 'string', 'max:100', new ValidCronExpression],
        'command'  => ['required', 'string', 'max:500', new AllowedCronCommand($this->user())],
        'label'    => ['nullable', 'string', 'max:255'],
    ];
}
```

Also validates the per-user cap:
```php
public function withValidator($validator): void {
    $validator->after(function ($v) {
        if (CronJob::where('user_id', $this->user()->id)->count() >= 50) {
            $v->errors()->add('command', 'You have reached the maximum of 50 cron jobs.');
        }
    });
}
```

### React UI

- `resources/js/Pages/CronJobs/Index.jsx` (new) — table of cron jobs: schedule, command, label, active toggle, delete. Inline form at top for adding a new job. Uses `AuthenticatedLayout` matching the other pages.
- `resources/js/Pages/CronJobs/Partials/CreateCronJobForm.jsx` (new) — preset `<select>` for common schedules (every minute, hourly, daily, weekly, monthly, custom) plus a free-text input for custom expressions. Command and label text inputs. Submit calls `router.post(route('cron-jobs.store'), {...})`.

No live `OperationProgress` needed — the ops are synchronous and return before the redirect. The flash message (`flash.success` / `flash.error`) is sufficient feedback.

## Request / Data Flow (store as example)

```
POST /cron-jobs
  StoreCronJobRequest::authorize() + rules() (ValidCronExpression + AllowedCronCommand + cap check)
  CronJobsController::store()
    DB::transaction():
      CronJob::create([user_id, schedule, command, label, active=true])
      Operation::create([user_id, type='cron.create', target=$systemUser, status='queued'])
      $op->markRunning()
      CreateCronJobService::handle()
        writes active jobs to 0600 tmp file
        Process::run(['sudo', bin_path.'/laranode-cron.sh', 'set', $systemUser, $tmpFile])
        if ($result->failed()) throw CreateCronJobException  ← transaction rolls back
      $op->markFinished(0)
      flash('success', ...)
  redirect()->route('cron-jobs.index')
```

On `CreateCronJobException`, the transaction rolls back the `CronJob` row. The `Operation` row's status is updated to `failed` before the rollback — the operation uses `markFinished(1)` which saves separately (outside the transaction's scope, because the Operation row needs to persist as an audit record of the failure).

Because `markRunning()` and `markFinished()` broadcast on `operations.{userId}`, the admin audit page at `/admin/operations` shows these rows live — for free, no extra code.

## Routes (modify `routes/web.php`)

```php
// Cron Jobs [Admin | User]
Route::resource('/cron-jobs', \App\Http\Controllers\CronJobsController::class)
    ->middleware(['auth'])
    ->except(['create', 'edit', 'show']);
Route::post('/cron-jobs/{cronJob}/toggle', [\App\Http\Controllers\CronJobsController::class, 'toggleActive'])
    ->middleware(['auth'])
    ->name('cron-jobs.toggle');
```

Route name prefix `cron-jobs.*` matches Laravel resource convention and Ziggy.

## Navigation

Add "Cron Jobs" link to `resources/js/Layouts/Partials/SidebarNavi.jsx` alongside Websites, MySQL, Filemanager — visible to both admin and regular users.

## Error Handling

- **Invalid cron expression** → `ValidCronExpression` rule rejects at FormRequest; 422 returned.
- **Disallowed command** → `AllowedCronCommand` rule rejects at FormRequest; never reaches the script.
- **Per-user cap exceeded** → 422 with a validation error on `command`.
- **Script non-zero exit** → `CreateCronJobService` throws; controller calls `$op->markFinished(1)`, flashes error; transaction rolls back the `CronJob` row.
- **User not owner** → `Gate::authorize('delete'/'update', $cronJob)` → 403.
- **Empty crontab** → script handles via `crontab -l -u $user 2>/dev/null || true`.

## Security

This feature executes user-controlled commands as the site user. Mitigations:

1. **`AllowedCronCommand` rule — v1 allowlist (php and artisan only):**
   - `php /home/{username}_ln/...` — path must start with the user's own homedir
   - Artisan is a subset: `php /home/{username}_ln/.../artisan ...`
   - **No `wget`, no `curl`** in v1 — `wget -O` is an arbitrary file-write; curl to arbitrary URLs is an exfiltration vector. Expanding the allowlist is a future decision.
   - **Reject any flag that takes a path argument** (e.g., `php -r`, `php -f` followed by a path outside homedir).
   - Reject all shell metacharacters: `;`, `&&`, `||`, `|`, `>`, `<`, `` $(...) ``, backtick.
   - Implementation: regex + explicit prefix checks in `AllowedCronCommand::validate()`.

2. **Path confinement** — all file paths in commands must start with `$user->homedir` (`/home/{username}_ln`). Absolute paths to system directories are rejected.

3. **The cron runs as `{username}_ln`**, not `www-data` or `root`. The script calls `crontab -u {username}_ln`; any scheduled command runs under that user's identity.

4. **Arguments via temp file, not shell args** — PHP writes active jobs to a temp file (`chmod 0600`), passes the path to the script, deletes it in `finally`. The script reads the file without `eval`-ing it.

5. **Script-level input validation** — `laranode-cron.sh` validates each line from the tmp file: exactly 5 schedule fields + a non-empty command, no embedded newlines. Invalid lines abort the script without touching the crontab.

6. **Script-level user validation** — the script refuses `$SYSTEM_USER` values that don't end in `_ln`, don't exist on the system, or are `root`. This prevents a compromised PHP layer from targeting arbitrary system users even if sudoers were misconfigured.

7. **Sudoers drop-in** — `www-data` is permitted to run only the specific `laranode-cron.sh` binary as `www-data` (not `ALL`). No `SETENV` permitted.

8. **No UI for admin to create jobs for another user** — admins can see all users' jobs (read) but create/delete/toggle only for themselves or via impersonation.

## Testing Strategy

### Pest feature tests (new `tests/Feature/CronJobs/`)

- **`CronJobModelTest`** — `scopeMine` returns own jobs for non-admin, all for admin; `belongsTo(User)`; unique constraint on `[user_id, schedule, command]`.
- **`StoreCronJobTest`** — valid request creates DB row + `Operation` row (`type=cron.create`, `status=succeeded`); invalid cron expression → 422; disallowed command → 422; `wget`/`curl` commands → 422 (blocked in v1); PHP path outside homedir → 422; shell metacharacters → 422; per-user cap (50) → 422; script failure → `Operation.status=failed` + no DB row (transaction rollback).
- **`DeleteCronJobTest`** — deletes DB row + creates `Operation` (`type=cron.delete`); non-owner → 403; script failure → DB row preserved (transaction rollback).
- **`ToggleActiveTest`** — flips `active`; `Operation` row `type=cron.toggle`; non-owner → 403; script failure → `active` reverted.
- **`CronJobPolicyTest`** — admin can delete/toggle any job; non-admin only their own.
- **Script interaction:** `Process::fake()` to assert `laranode-cron.sh set` called with correct args (system username, temp file path); verify script not called with shell-arg injection.

### `tests/Unit/AllowedCronCommandRuleTest.php` (Pest)

Table-driven: allowed patterns pass (php path in own homedir, artisan); blocked patterns fail (metacharacters, paths outside homedir, `wget`, `curl`, `php -r`, paths to `/etc`, `/root`).

### `tests/Feature/CronJobs/CronJobSystemTest.php` — `LARANODE_SYSTEM_TESTS=1`

Runs inside the `local-dev` container against the real script and real crontab. Requires `testuser_ln` and `testuser2_ln` Linux accounts to exist — the `local-dev/entrypoint-setup.sh` must provision them (via `useradd -m -s /bin/bash testuser_ln` etc.) before the system test runs.

Tests:
1. Create a job → assert `crontab -l -u testuser_ln` contains the entry with `# laranode-managed`.
2. Delete a job → assert the entry is removed.
3. Empty crontab does not crash the script (`crontab -l` exits 1 for new users).
4. Invalid user (no `_ln` suffix) → script exits non-zero without touching crontab.

### Vitest unit tests

- `CreateCronJobForm` — render with RTL; fill schedule + command; assert submit triggers `router.post`.
- `CronJobs/Index` — renders job rows and the add form with correct column data.

## File Inventory

```
database/migrations/XXXX_create_cron_jobs_table.php           (new)
app/Models/CronJob.php                                        (new)
app/Services/CronJobs/CreateCronJobService.php                (new, includes CreateCronJobException)
app/Services/CronJobs/DeleteCronJobService.php                (new, includes DeleteCronJobException)
app/Rules/ValidCronExpression.php                             (new)
app/Rules/AllowedCronCommand.php                              (new)
app/Http/Controllers/CronJobsController.php                   (new)
app/Http/Requests/StoreCronJobRequest.php                     (new)
app/Policies/CronJobPolicy.php                                (new)
laranode-scripts/bin/laranode-cron.sh                         (new)
etc/sudoers.d/laranode-cron                                   (new, deployed by installer)
laranode-scripts/bin/laranode-installer.sh                    (modify: copy sudoers drop-in)
local-dev/entrypoint-setup.sh                                 (modify: provision testuser_ln + testuser2_ln)
routes/web.php                                                (modify: add cron-jobs resource + toggle routes)
resources/js/Layouts/Partials/SidebarNavi.jsx                 (modify: add Cron Jobs nav link)
resources/js/Pages/CronJobs/Index.jsx                         (new)
resources/js/Pages/CronJobs/Partials/CreateCronJobForm.jsx    (new)
tests/Feature/CronJobs/CronJobModelTest.php                   (new)
tests/Feature/CronJobs/StoreCronJobTest.php                   (new)
tests/Feature/CronJobs/DeleteCronJobTest.php                  (new)
tests/Feature/CronJobs/ToggleActiveTest.php                   (new)
tests/Feature/CronJobs/CronJobPolicyTest.php                  (new)
tests/Feature/CronJobs/CronJobSystemTest.php                  (new, LARANODE_SYSTEM_TESTS=1)
tests/Unit/AllowedCronCommandRuleTest.php                     (new)
resources/js/Pages/CronJobs/CronJobs.test.jsx                 (new, Vitest)
```

## Back-compat / Migration

- No changes to existing models (`User`, `Website`, `Database`, `Operation`).
- `Operation` rows with `type=cron.*` are new; the existing `/admin/operations` page renders them automatically.
- The `withSchedule` hook in `bootstrap/app.php` is already in place — no change needed.
- Existing crontab entries for `{username}_ln` added manually before this feature are preserved: `laranode-cron.sh` only touches lines tagged `# laranode-managed`.

## Decided Defaults (no longer open questions)

- **Command allowlist v1:** `php` (homedir-scoped) and artisan (subset of php) only. `wget` and `curl` are excluded from v1 (`wget -O` = arbitrary file write; curl = exfiltration risk). Expanding the allowlist is a future decision.
- **Per-user cap:** 50 cron jobs. Enforced in `StoreCronJobRequest::withValidator()`.
- **Edit = delete + recreate:** no `update` route in v1. Noted as out of scope; users delete and re-add to change a job.
- **Schedule builder UI:** preset dropdown + free-text custom mode. A full 5-field visual builder is out of scope for v1.
- **`toggleActive` route:** `POST /cron-jobs/{cronJob}/toggle` (not a `PATCH` on the resource).
- **Audit visibility for non-admins:** admin page only in v1. Regular users see flash messages; no per-user operations tab.
- **Temp file location:** `/tmp` (system default). The script consumes the file and PHP deletes it in `finally`.

## Out of Scope

- Output capture of executed cron jobs (cron stdout/stderr goes to system mail — defer).
- Cron job run history / last-ran timestamps (requires log tailing — defer).
- Admin creating cron jobs for other users directly (use impersonation instead).
- `curl` / `wget` commands (v1 security decision — defer).
- Environment variable injection per-job (`CRON_ENV` column — future).
- Per-job `MAILTO=` header — future.
- Edit (update) route — delete + recreate in v1.
