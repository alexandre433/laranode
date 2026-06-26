# Sub-project #10 — Per-user crontab CRUD (`cron-tasks`)

- **Date:** 2026-06-26
- **Status:** Draft — awaiting user review
- **Roadmap:** Phase N, sub-project #10 of `docs/superpowers/specs/2026-06-25-laranode-feature-roadmap.md`
- **Branch:** `feature/cron-tasks` (off `development`)

## Goal

Let each Laranode user manage scheduled cron jobs for their `{username}_ln` system account via the panel UI. The panel DB is the source of truth; a new `laranode-cron.sh` script (list / set / remove) syncs to the real crontab. All mutations write an audit `Operation` row using the shipped foundation from `feature/platform-async-progress`.

**Why:** cron is the standard per-user scheduling tool on Ubuntu 24.04. Exposing it through the panel (with a sanitized, allowlisted interface) lets users schedule PHP scripts, artisan commands, and wget/curl tasks without SSH access. The per-user crontab is isolated to `{username}_ln` — it never touches root's crontab or any other user's.

## Architecture

Pattern: **Controller → FormRequest → `CronJobService` (sync, fast) → `laranode-cron.sh` via `Process::run` → audit `Operation` row**. Not an `OperationJob` because crontab writes are sub-second; using `OperationJob` would be over-engineering. Instead, the controller creates the `Operation` row inline and immediately marks it `succeeded` or `failed`, matching the audit guarantee without queue latency.

```
CronJobsController → StoreCronJobRequest / DeleteCronJobRequest
  → App\Services\CronJobs\CreateCronJobService::handle()
      → Process::run(['sudo', laranode_bin_path.'/laranode-cron.sh', 'set', systemUsername, schedule, command])
      → Operation::create([...]) + operation->markRunning() + operation->markFinished($exit)
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

Index: `['user_id', 'active']`.

No `status` column on the job itself — the crontab either has the entry or not. Execution outcomes live in system logs, not in the panel (scope limit).

### `CronJob` model — `App\Models\CronJob`

- `$fillable`: `user_id, schedule, command, label, active`.
- `$casts`: `active => boolean`.
- `belongsTo(User)`.
- `scopeMine(Builder): Builder` — mirrors `Website::scopeMine` and `Database::scopeMine`: non-admins scoped to own `user_id`.
- **No** `MassPrunable` here — cron job records should persist until the user deletes them.

### `Operation` row (reuse existing model)

Every write mutation (`store`, `destroy`, `toggleActive`) creates one `Operation` row with:
- `type`: `cron.create` | `cron.delete` | `cron.toggle`
- `target`: `{username_ln}` (the system user the crontab belongs to)
- `user_id`: the acting panel user

Because these are synchronous, the controller drives the lifecycle directly:
```php
$op = Operation::create(['user_id' => $userId, 'type' => 'cron.create', 'target' => $systemUser, 'status' => 'queued']);
$op->markRunning();
// ... run script ...
$op->appendOutput($result->output());
$op->markFinished($result->exitCode());
```

## Components (real file names)

### `laranode-scripts/bin/laranode-cron.sh` (new)

Three sub-commands:
- `set <system_user> <escaped_cron_entry>` — replaces the user's crontab atomically by reading existing lines from `crontab -l -u $system_user`, removing any line tagged with the Laranode comment marker, prepending a fresh block of all active entries, and piping to `crontab -u $system_user -`.
- `remove <system_user> <escaped_cron_entry>` — same atomic replace, omitting the named entry.
- `list <system_user>` — runs `crontab -l -u $system_user`, used for read-only sync checks (optional / test-only in scope).

The script always operates as the Laranode service account (`www-data` via sudo) and never as root. It tags each managed line with a trailing comment `# laranode-managed` to distinguish panel entries from manually added lines — those manual lines are left untouched by `set`/`remove`.

> **Sync strategy:** the script rebuilds the block of managed lines on every write using all active `CronJob` rows for that user passed in from PHP — not a single-entry delta. This avoids stale state if a previous write partially failed. The PHP side passes all active jobs as a JSON array or newline-separated list via a temp file (see security note below on argument size limits).

### `etc/sudoers.d/laranode-cron` (new drop-in)

```
www-data ALL=(ALL) NOPASSWD: /path/to/laranode-scripts/bin/laranode-cron.sh
```

Added as a separate drop-in, not appended to the monolithic installer sudoers line (matches `laranode.laranode_bin_path` config). The installer script `laranode-scripts/bin/laranode-installer.sh` must copy this file during provisioning.

### `App\Services\CronJobs\CreateCronJobService` (new)

`__construct(CronJob $cronJob, User $user)` + `handle(): void`. Steps:
1. Pass the full active job list for `$user->systemUsername` to `laranode-cron.sh set`.
2. Throws `CreateCronJobException` on non-zero exit.

```php
class CreateCronJobException extends \Exception {}

class CreateCronJobService { ... }
```

### `App\Services\CronJobs\DeleteCronJobService` (new)

`__construct(CronJob $cronJob, User $user)` + `handle(): void`. Deletes the DB row first, then re-syncs the remaining active jobs via `laranode-cron.sh set` (full rebuild strategy).

### `App\Http\Controllers\CronJobsController` (new)

- `index(Request $request): Response` — `CronJob::mine()->where('user_id', $user->id)->orderBy('id')->get()` → Inertia `CronJobs/Index`.
- `store(StoreCronJobRequest $request): RedirectResponse` — create model, call `CreateCronJobService`, write audit `Operation`, flash success/error.
- `destroy(Request $request, CronJob $cronJob): RedirectResponse` — `Gate::authorize('delete', $cronJob)`, call `DeleteCronJobService`, write audit `Operation`.
- `toggleActive(Request $request, CronJob $cronJob): RedirectResponse` — flip `active`, re-sync crontab via `laranode-cron.sh set`, write audit `Operation` with type `cron.toggle`.

`CronJob` route model binding respects `scopeMine` implicitly once the policy is in place (or explicit `Gate::authorize`).

### `App\Http\Requests\StoreCronJobRequest` (new)

```php
public function rules(): array {
    return [
        'schedule' => ['required', 'string', 'max:100', new ValidCronExpression],
        'command'  => ['required', 'string', 'max:500', new AllowedCronCommand],
        'label'    => ['nullable', 'string', 'max:255'],
    ];
}
```

Two custom rules (see Security section).

### React UI

- `resources/js/Pages/CronJobs/Index.jsx` (new) — table of cron jobs with add form inline (same pattern as `Websites/Index.jsx` + `CreateWebsiteForm`). Columns: schedule, command, label, active toggle, delete. Uses `react-data-table-component` matching the Mysql/Firewall pages, or a plain `<table>` matching `Operations/Index.jsx`. Reuses `AuthenticatedLayout` from `@/Layouts/AuthenticatedLayout`.
- `resources/js/Pages/CronJobs/Partials/CreateCronJobForm.jsx` (new) — schedule builder: either a set of 5 `<select>` dropdowns (minute/hour/day/month/weekday) for common presets, plus a free-text input for advanced expressions. This keeps the UX approachable for users without cron knowledge. On submit, calls `router.post(route('cron-jobs.store'), {...})`.

No live `OperationProgress` needed — the ops are synchronous and return before the redirect. The flash message (`flash.success` / `flash.error` via `HandleInertiaRequests`) is sufficient feedback.

## Request / Data Flow (store as example)

```
POST /cron-jobs
  StoreCronJobRequest::authorize() + rules() (validated, including ValidCronExpression + AllowedCronCommand)
  CronJobsController::store()
    CronJob::create([user_id, schedule, command, label, active=true])
    Operation::create([user_id, type='cron.create', target=$systemUser, status='queued'])
    $op->markRunning()                                    // OperationUpdated broadcast on operations.{userId}
    CreateCronJobService::handle()
      $activeJobs = CronJob::where('user_id', $user->id)->where('active', true)->get()
      // write to tmp file, pass path to script (not shell args)
      Process::run(['sudo', bin_path.'/laranode-cron.sh', 'set', $systemUser, $tmpFile])
      if ($result->failed()) throw CreateCronJobException
    $op->appendOutput($result->output())
    $op->markFinished($result->exitCode())               // OperationUpdated broadcast
    session()->flash('success', '...')
  redirect()->route('cron-jobs.index')
```

Because `markRunning` / `markFinished` broadcast on `operations.{userId}`, the admin audit page at `/admin/operations` will show these rows live — for free, no extra code.

## Routes (modify `routes/web.php`)

```php
// Cron Jobs [Admin | User]
Route::resource('/cron-jobs', CronJobsController::class)
    ->middleware(['auth'])
    ->except(['create', 'edit', 'show']);
Route::post('/cron-jobs/{cronJob}/toggle', [CronJobsController::class, 'toggleActive'])
    ->middleware(['auth'])
    ->name('cron-jobs.toggle');
```

Route name prefix `cron-jobs.*` matches Laravel resource convention and Ziggy (`route('cron-jobs.store')` in JSX).

## Navigation

Add "Cron Jobs" link to `resources/js/Layouts/AuthenticatedLayout.jsx` alongside Websites, MySQL, Filemanager — visible to both admin and regular users (non-admin scoped to own jobs via `scopeMine`).

## Error Handling

- **Invalid cron expression** → `ValidCronExpression` rule rejects at FormRequest; 422 returned; user sees inline validation error.
- **Disallowed command** → `AllowedCronCommand` rule rejects at FormRequest; never reaches the script.
- **Script non-zero exit** → `CreateCronJobService` throws `CreateCronJobException`; controller catches it, calls `$op->markFinished(1)` (row `failed`), flashes error. The `CronJob` row is rolled back (delete it on failure) or never persisted (if exception before `save()`).
- **User not owner** → `Gate::authorize('delete', $cronJob)` → 403. Policy (`CronJobPolicy`) mirrors `WebsitePolicy`: admin passes all, user only their own.
- **`crontab -l` returns exit 1 for empty crontab** → script must handle this: `crontab -l -u $user 2>/dev/null || true` before rebuild.

## Security

This feature has the highest risk surface in the codebase: it executes arbitrary commands as the site user. Mitigations:

1. **`AllowedCronCommand` validation rule** — allowlist of safe command prefixes/patterns. Suggested initial set:
   - PHP: `php /home/{username}_ln/...` (path must start with user's homedir)
   - Artisan: same pattern, `php /home/{username}_ln/.../artisan ...`
   - curl / wget to http/https URLs
   - Reject shell metacharacters: `;`, `&&`, `||`, `|`, `>`, `<`, `$(...)`
   - Implementation: regex + explicit prefix checks in the `Rule` class `passes()` method.

2. **Path confinement** — the `AllowedCronCommand` rule ensures file paths in commands stay within `$user->homedir`. Never allow absolute paths to system directories.

3. **The cron runs as `{username}_ln`**, not `www-data` or `root`. The script runs `crontab -u {username}_ln`; any scheduled command runs under that identity. Lateral movement to other users is blocked by Unix permissions.

4. **Arguments via temp file, not shell args** — passing the full job list as shell arguments risks injection via schedule/command values containing spaces, quotes, or escape sequences. Write jobs to a temp file owned by `www-data` with `0600` permissions, pass the path to the script, and delete the temp file after the script exits. The script reads the file (never `eval`s it) and constructs crontab lines internally.

5. **`laranode-cron.sh` internal escaping** — the script must validate that each line it writes to crontab is a syntactically valid cron entry (5 time fields + command) before installing. Reject entries that don't match the expected format.

6. **Sudoers drop-in** — `www-data` is permitted to run only the specific `laranode-cron.sh` binary, not a wildcard. No `SETENV` permitted.

7. **No UI for admin to create jobs for another user** — admins can see all users' jobs (read, `scopeMine` returns all for admins) but can only create/delete/toggle for themselves. Admin impersonation covers the "manage on behalf of user" case without adding a separate code path.

## Testing Strategy

### Pest feature tests (new `tests/Feature/CronJobs/`)

- **`CronJobModelTest`** — `scopeMine` returns own jobs for non-admin, all for admin; `belongsTo(User)`.
- **`StoreCronJobTest`** — valid request creates DB row + `Operation` row (`type=cron.create`, `status=succeeded`); invalid cron expression rejected 422; disallowed command rejected 422; non-owner cannot delete another's job (403).
- **`DeleteCronJobTest`** — deletes DB row + creates `Operation` row; attempts by non-owner 403.
- **`ToggleActiveTest`** — flips `active`; `Operation` row `type=cron.toggle` created.
- **Script interaction:** `Process::fake()` to assert `laranode-cron.sh` called with correct args; failure path asserts `Operation.status = failed` and flash.error.
- **`LARANODE_SYSTEM_TESTS=1`** — a separate system test hits the real script inside the `local-dev` container: create a job, assert `crontab -l -u testuser_ln` contains the entry; delete it, assert removed.

### Vitest unit tests

- `ValidCronExpression` logic extracted to a pure JS helper used by the schedule builder dropdowns — test valid/invalid expressions without mounting the component.
- `CreateCronJobForm` — render with RTL; fill schedule + command; assert submit triggers `router.post`.

### AllowedCronCommand rule unit test (Pest)

Separate `tests/Unit/AllowedCronCommandRuleTest.php` — table-driven: allowed patterns pass, disallowed (semicolons, subshells, paths outside homedir) fail.

## File Inventory

```
database/migrations/XXXX_create_cron_jobs_table.php           (new)
app/Models/CronJob.php                                        (new)
app/Services/CronJobs/CreateCronJobService.php                (new, includes CreateCronJobException)
app/Services/CronJobs/DeleteCronJobService.php                (new)
app/Rules/ValidCronExpression.php                             (new)
app/Rules/AllowedCronCommand.php                              (new)
app/Http/Controllers/CronJobsController.php                   (new)
app/Http/Requests/StoreCronJobRequest.php                     (new)
app/Policies/CronJobPolicy.php                                (new)
laranode-scripts/bin/laranode-cron.sh                         (new)
etc/sudoers.d/laranode-cron                                   (new, deployed by installer)
routes/web.php                                                (modify: add cron-jobs resource + toggle routes)
resources/js/Layouts/AuthenticatedLayout.jsx                  (modify: add Cron Jobs nav link)
resources/js/Pages/CronJobs/Index.jsx                         (new)
resources/js/Pages/CronJobs/Partials/CreateCronJobForm.jsx    (new)
bootstrap/app.php                                             (no change — scheduler hook already in place)
tests/Feature/CronJobs/CronJobModelTest.php                   (new)
tests/Feature/CronJobs/StoreCronJobTest.php                   (new)
tests/Feature/CronJobs/DeleteCronJobTest.php                  (new)
tests/Feature/CronJobs/ToggleActiveTest.php                   (new)
tests/Unit/AllowedCronCommandRuleTest.php                     (new)
resources/js/Pages/CronJobs/CronJobs.test.jsx                 (new, Vitest)
```

## Back-compat / Migration

- No changes to existing models (`User`, `Website`, `Database`, `Operation`).
- `Operation` rows with `type=cron.*` are new; the existing `/admin/operations` page renders them automatically via the generic table.
- The `withSchedule` hook in `bootstrap/app.php` is already in place — no change needed.
- Existing crontab entries for `{username}_ln` that were added manually (before this feature) are preserved: `laranode-cron.sh` only touches lines tagged `# laranode-managed`.

## Out of Scope

- Output capture of executed cron jobs (cron stdout/stderr goes to system mail, not the panel — out of scope).
- Cron job run history / last-ran timestamps (requires a sidecar process or log tailing — defer).
- Admin creating cron jobs for other users directly (use impersonation instead).
- Environment variable injection per-job (future: `CRON_ENV` column + script support).
- Per-job enable/disable of crontab output mailing (`MAILTO=` header — note for later).

## Open Questions

1. **`AllowedCronCommand` allowlist breadth** — the initial set (php, curl, wget) is conservative. Should users also be allowed to run arbitrary binaries in `/usr/bin/` (e.g., `node`, `python3`, `bash /home/x_ln/...`)? Expanding the allowlist widens the attack surface; confirm the intended scope before implementation.

2. **Sync strategy on toggle** — `toggleActive` currently re-syncs the full crontab. If a user has 50+ jobs, this is fine. Is there a row count cap (e.g., 20 jobs per user) that should be enforced via a `domain_limit`-style column, or is per-user row count left unlimited?

3. **Temp file location** — writing job lists to a temp file in `/tmp` is straightforward but needs a writable, cleanup-safe path inside the container. Confirm `/tmp` is acceptable, or whether a dedicated `/var/lib/laranode/` directory should be used.

4. **Schedule builder UI depth** — the spec calls for preset dropdowns (common intervals: every minute, hourly, daily, weekly, monthly) plus a free-text advanced mode. Confirm whether a full 5-field visual builder (like crontab.guru) is in scope or whether the preset + free-text combination is sufficient for the first version.

5. **`toggleActive` route** — a POST to `/cron-jobs/{cronJob}/toggle` is used (not a PATCH on the resource) to keep the resource routes clean. Confirm this is acceptable, or whether a PATCH with `{ active: bool }` on the resource `update` route is preferred.

6. **Audit visibility for non-admins** — the shipped `/admin/operations` page is admin-only. Should regular users be able to see their own `cron.*` operation history (e.g., a per-user operations tab), or is the admin page sufficient for now?
