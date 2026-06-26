# User-Facing Resource Analytics (`user-analytics`) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give non-admin Laranode users a `/analytics` page showing their own disk usage trends, per-site disk breakdown, quota consumption, and SSL cert status — all served from pre-computed snapshot rows so page loads never shell out.

**Architecture:** Two new DB tables (`user_resource_snapshots`, `user_site_stats`) written by rollup jobs dispatched by the scheduler. A read-only `UserAnalyticsService` queries those tables with explicit `where('user_id', $user->id)` and feeds an `AnalyticsController` that renders `Analytics/Index.jsx` via Inertia.

**Tech Stack:** Laravel 12, Pest 3, Inertia + React (JSX), `react-chartjs-2` (already installed), `Process` facade, MySQL/SQLite `:memory:`, Vitest + RTL.

## Global Constraints

- **No `AdminMiddleware` on `/analytics`** — `middleware('auth')` only. Admin sees their own data only.
- **NO `scopeMine()` on `UserResourceSnapshot` or `UserSiteStat`** — the admin passthrough returns all rows, leaking other tenants' data. All analytics queries use explicit `where('user_id', $user->id)`. Tests assert an admin sees exactly their own 1 row.
- **No new sudo scripts** — all rollup reads are unprivileged (`du`, `wc -l`). No new `sudoers` entries.
- **Rollup jobs extend `App\Jobs\OperationJob`** — audit row, live `$emit`, and lifecycle for free.
- **Apache log path is `/home/{username}_ln/logs/apache-access.log`** (confirmed from `laranode-scripts/templates/apache-vhost.template` — ONE shared log per user, not per-site under `/var/log/apache2/`).
- **sar is NOT used** — CPU/mem omitted from v1. This avoids the PHP double-quoted string / awk `$field` interpolation bug (PHP would expand `$3` to an empty string in `"awk '{print $3}'"`) that `Process::fake` masks in tests.
- **du failure = operation failed, no row written** — `UserResourceSnapshotService` throws on `du` failure. Tests assert `status === 'failed'` AND `count === 0`, not `toBeIn(['succeeded','failed'])`.
- **`User::databases()` relation MUST be added** — it does not exist on `app/Models/User.php`. `getQuotaSummary` calls `$user->databases()->count()` and fatals without it.
- **`ssl_expires_at` is nullable** — frontend guard required: `row.ssl_expires_at && (new Date(...) - Date.now()) < 14 * 86400 * 1000`. SSL-less sites must never show a false expiry warning.
- **Chunk users in scheduler** — use `chunkById(50, ...)`, not `->each()`, to avoid loading all users into memory.
- **Scheduler tests use `schedule:list`** — not `app(Schedule::class)->events()`, which is known flaky in full-suite isolation.
- **Every system-touching path has a `LARANODE_SYSTEM_TESTS=1` integration test** exercising real `du`/`wc -l` in the `local-dev` container.
- **`bootstrap/app.php` `withSchedule` closure is the single scheduler entrypoint** — extend it, do not add a second `->withSchedule()` call.
- **Branch:** `feature/user-analytics` (off `development`, after `platform-async-progress` merged).

---

> **Execution order:** Tasks 1–7 in sequence. Task 1 (models) is the foundation. Tasks 2 and 3 (services + jobs) in either order, both before Task 4 (scheduler). Task 5 (controller) depends on Task 2. Task 6 (frontend) depends on Task 5. Task 7 (nav link) depends on Task 6.

---

### Task 1: Migrations + `UserResourceSnapshot` + `UserSiteStat` models + `User::databases()` relation

**Files:**
- Create: `database/migrations/2026_06_26_000001_create_user_resource_snapshots_table.php`
- Create: `database/migrations/2026_06_26_000002_create_user_site_stats_table.php`
- Create: `app/Models/UserResourceSnapshot.php`
- Create: `app/Models/UserSiteStat.php`
- Modify: `app/Models/User.php` (add `databases()` hasMany)
- Create: `tests/Feature/Analytics/UserResourceSnapshotModelTest.php`

**Produces:**
- `UserResourceSnapshot`: `id, user_id (FK cascade), snapshotted_at, disk_bytes (unsignedBigInteger), apache_request_count (unsignedBigInteger nullable), timestamps`; index `(user_id, snapshotted_at)`; `belongsTo(User)`; `MassPrunable` → `where('snapshotted_at', '<', now()->subDays(90))`; **no `scopeMine()`**.
- `UserSiteStat`: `id, website_id (FK cascade), user_id (FK cascade), snapshotted_at, disk_bytes (unsignedBigInteger), timestamps`; index `(website_id, snapshotted_at)`; `belongsTo(Website)`, `belongsTo(User)`; `MassPrunable` (90 days); **no `scopeMine()`**.
- `User::databases()` `hasMany(Database::class)` relation.

**Acceptance criteria:**
- [ ] Tests written first (TDD); verified to fail before implementation.
- [ ] `UserResourceSnapshot::prunable()->count()` returns 1 (old row) and not the fresh row.
- [ ] Admin user: `UserResourceSnapshot::where('user_id', $admin->id)->count()` returns 1 when admin has 1 row and another user has 1 row (no bleed from scopeMine).
- [ ] `$user->databases()->count()` does not throw a `BadMethodCallException`.
- [ ] `UserSiteStat::prunable()->count()` returns 1 (old row).
- [ ] Suite: `php artisan test --filter=UserResourceSnapshotModelTest` — PASS.

---

### Task 2: Rollup services (`UserResourceSnapshotService` + `UserSiteStatsService`)

**Files:**
- Create: `app/Services/Analytics/UserResourceSnapshotService.php`
- Create: `app/Services/Analytics/UserSiteStatsService.php`
- Create: `tests/Feature/Analytics/RollupServiceTest.php`
- Create: `tests/Feature/Analytics/RollupSystemTest.php` (LARANODE_SYSTEM_TESTS gated)

**Produces:**
- `UserResourceSnapshotService::collect(User $user, callable $emit): void`
  - `Process::run(['du', '-sb', $user->homedir])` → on failure (exit ≠ 0): throw `\RuntimeException`. On success: extract bytes from `"12345\t/path"` output.
  - `Process::run(['wc', '-l', $user->homedir . '/logs/apache-access.log'])` → on failure: `$requestCount = null` (not an error).
  - Writes exactly one `UserResourceSnapshot` row. No row is written if `du` throws.
- `UserSiteStatsService::collect(User $user, callable $emit): void`
  - Queries `Website::where('user_id', $user->id)->get()`.
  - Per site: `Process::run(['du', '-sb', $site->websiteRoot])` → throws on failure. Writes one `UserSiteStat` per site.

**Acceptance criteria:**
- [ ] `Process::fake(['du *' => Process::result("98765\t/home/u_ln", 0), 'wc *' => Process::result("77 /home/u_ln/logs/apache-access.log", 0)])` → one row, `disk_bytes=98765`, `apache_request_count=77`.
- [ ] `du` success + `wc -l` failure → one row, `apache_request_count=null`, no exception.
- [ ] `du` exit code 1 → `RuntimeException` thrown, zero `UserResourceSnapshot` rows.
- [ ] `UserSiteStatsService`: one site → one row with correct `disk_bytes`.
- [ ] `UserSiteStatsService`: `du` exit code 1 → `RuntimeException` thrown, zero rows.
- [ ] `[LARANODE_SYSTEM_TESTS]` real `du` on container user homedir → row with `disk_bytes > 0`.
- [ ] `[LARANODE_SYSTEM_TESTS]` real `du` on a real website directory → `UserSiteStat` row with `disk_bytes > 0`.
- [ ] Suite: `php artisan test --filter=RollupServiceTest` — PASS.

---

### Task 3: Rollup jobs (`RollupUserResourceSnapshotJob` + `RollupSiteStatsJob`)

**Files:**
- Create: `app/Jobs/Analytics/RollupUserResourceSnapshotJob.php`
- Create: `app/Jobs/Analytics/RollupSiteStatsJob.php`
- Create: `tests/Feature/Analytics/RollupJobTest.php`

**Produces:**
- `RollupUserResourceSnapshotJob extends OperationJob`: constructor `(Operation $operation, User $user)`; `run(callable $emit): int` delegates to `UserResourceSnapshotService::collect` and returns 0.
- `RollupSiteStatsJob extends OperationJob`: same pattern, delegates to `UserSiteStatsService::collect`.

**Acceptance criteria:**
- [ ] `Process::fake` with successful `du` + `wc` → one `UserResourceSnapshot` row, `$op->fresh()->status === 'succeeded'`.
- [ ] Two users dispatched separately → two rows, each scoped to correct `user_id`, total count = 2.
- [ ] `Process::fake` with `du` exit code 1 → `$op->fresh()->status === 'failed'` (exactly, not `toBeIn`) AND `UserResourceSnapshot::count() === 0`.
- [ ] `wc -l` exit code 1 (log missing) → `$op->fresh()->status === 'succeeded'` AND `apache_request_count === null`.
- [ ] `RollupSiteStatsJob` with one site → one `UserSiteStat` row, operation `succeeded`.
- [ ] Suite: `php artisan test --filter=RollupJobTest` — PASS.

---

### Task 4: Scheduler registration + prune extension

**Files:**
- Modify: `bootstrap/app.php` (extend `withSchedule` closure)
- Create: `tests/Feature/Analytics/SchedulerTest.php`

**Produces:**
- `schedule:list` shows `analytics.resource-rollup` (daily) and `analytics.site-rollup` (hourly) named entries.
- `model:prune` command includes `UserResourceSnapshot` and `UserSiteStat` alongside the existing `Operation`.
- Users loaded with `chunkById(50, ...)`, not `->each()`.

**Acceptance criteria:**
- [ ] `$this->artisan('schedule:list')->expectsOutputToContain('analytics.resource-rollup')->assertExitCode(0)`.
- [ ] `$this->artisan('schedule:list')->expectsOutputToContain('analytics.site-rollup')->assertExitCode(0)`.
- [ ] `$this->artisan('schedule:list')->expectsOutputToContain('model:prune')->assertExitCode(0)`.
- [ ] Existing `SchedulerTest` (Operations) still passes — `withSchedule` is extended, not replaced.
- [ ] Suite: `php artisan test --filter=SchedulerTest` — PASS (all analytics + existing operations tests).

---

### Task 5: `User::databases()` relation + `UserAnalyticsService` + `AnalyticsController` + route

**Files:**
- Create: `app/Services/Analytics/UserAnalyticsService.php`
- Create: `app/Http/Controllers/AnalyticsController.php`
- Modify: `routes/web.php` (add `GET /analytics`)
- Create: `tests/Feature/Analytics/AnalyticsControllerTest.php`

Note: `User::databases()` is added in Task 1. Task 5 writes the controller tests that call `getQuotaSummary`, validating the relation works end-to-end via HTTP.

**Produces:**
- `UserAnalyticsService`: `getResourceHistory(User, int $days=30): Collection`, `getSiteStats(User, int $days=30): Collection`, `getQuotaSummary(User): array`, `getSslOverview(User): Collection`. All queries: `where('user_id', $user->id)`. `getSslOverview` returns `ssl_expires_at` as-is (nullable); no computation in the service.
- `AnalyticsController::index(Request): Inertia\Response` — instantiates `UserAnalyticsService` directly; renders `Analytics/Index` with props `resourceHistory`, `siteStats`, `quotaSummary`, `sslOverview`.
- Route `analytics.index` at `GET /analytics`, `middleware(['auth'])`.

**Acceptance criteria:**
- [ ] Non-admin user → `/analytics` returns 200, Inertia component `Analytics/Index`, all four props present.
- [ ] `resourceHistory` contains only the auth user's rows (other user's row absent).
- [ ] `siteStats` is empty when the auth user has no sites with stats (other user's site stat absent).
- [ ] Admin user → sees exactly 1 `resourceHistory` row (their own), not 2, when one other user also has a row.
- [ ] Unauthenticated → redirect to login.
- [ ] No snapshots → `resourceHistory` is empty collection (no 500).
- [ ] Suite: `php artisan test --filter=AnalyticsControllerTest` — PASS.

---

### Task 6: Frontend — `Analytics/Index.jsx` + Vitest tests

**Files:**
- Create: `resources/js/Pages/Analytics/Index.jsx`
- Create: `resources/js/Pages/Analytics/Index.test.jsx`

**Produces:**
- Inertia page with four sections: Resource trends (`<Line>` charts for disk GB + request count), Per-site breakdown (`<Bar>` chart for site disk), Quota consumption (progress bars), SSL overview (table).
- "No data yet" notice when `resourceHistory` is empty.
- SSL expiry warning for certs expiring within 14 days, guarded: `row.ssl_expires_at && (new Date(row.ssl_expires_at) - Date.now()) < 14 * 86400 * 1000`.
- Imports follow `resources/js/Pages/Stats/Components/CPUChart.jsx` pattern for `react-chartjs-2`.

**Acceptance criteria:**
- [ ] `Line` chart container renders when `resourceHistory` has data.
- [ ] `Bar` chart renders when `siteStats` has data.
- [ ] "No data yet" text renders when `resourceHistory` is empty.
- [ ] SSL table shows domain and expiry date.
- [ ] Row with `ssl_expires_at = null` does NOT render an expiry warning element.
- [ ] Row with `ssl_expires_at` 10 days from now renders a warning indicator.
- [ ] Quota bars show counts.
- [ ] `npm run test` — all Vitest tests PASS.
- [ ] `npm run build` — succeeds with no import errors.

---

### Task 7: Nav link in `AuthenticatedLayout`

**Files:**
- Modify: `resources/js/Layouts/AuthenticatedLayout.jsx`

**Produces:**
- "Analytics" nav entry in sidebar for all authenticated users, after "File Manager", using `route('analytics.index')`.
- Matches the exact element type and CSS classes of adjacent nav items.

**Acceptance criteria:**
- [ ] `npm run build` succeeds.
- [ ] In the running container, visiting `/analytics` after login shows the page (sidebar link is present and navigates correctly).

---

### Task 8: Final verification gate

- [ ] `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test'` — full Pest suite passes, zero failures.
- [ ] `./vendor/bin/pint --test` exits 0. If not, run `./vendor/bin/pint` and re-run suite.
- [ ] `npm run test` — all Vitest tests pass.
- [ ] `php artisan schedule:list` in the container shows `analytics.resource-rollup`, `analytics.site-rollup`, and `model:prune` (with snapshot models).
- [ ] Manually trigger rollup: `php artisan schedule:run` → `/admin/operations` shows `analytics.rollup` and `analytics.site-rollup` rows.
- [ ] `/analytics` renders for a non-admin user with no cross-tenant data (confirm via Inertia DevTools network tab — `resourceHistory` items all have the auth user's `user_id`).
- [ ] `/stats/history` admin page unchanged.
- [ ] `[LARANODE_SYSTEM_TESTS]` `php artisan test --filter=RollupSystemTest` in container — PASS.

---

## File Inventory

```
database/migrations/2026_06_26_000001_create_user_resource_snapshots_table.php  (new — Task 1)
database/migrations/2026_06_26_000002_create_user_site_stats_table.php           (new — Task 1)
app/Models/UserResourceSnapshot.php                                               (new — Task 1)
app/Models/UserSiteStat.php                                                       (new — Task 1)
app/Models/User.php                                                               (modify: add databases() — Task 1)
app/Services/Analytics/UserResourceSnapshotService.php                            (new — Task 2)
app/Services/Analytics/UserSiteStatsService.php                                   (new — Task 2)
app/Jobs/Analytics/RollupUserResourceSnapshotJob.php                              (new — Task 3)
app/Jobs/Analytics/RollupSiteStatsJob.php                                         (new — Task 3)
bootstrap/app.php                                                                  (modify — Task 4)
app/Services/Analytics/UserAnalyticsService.php                                   (new — Task 5)
app/Http/Controllers/AnalyticsController.php                                      (new — Task 5)
routes/web.php                                                                     (modify — Task 5)
resources/js/Pages/Analytics/Index.jsx                                             (new — Task 6)
resources/js/Layouts/AuthenticatedLayout.jsx                                       (modify — Task 7)
tests/Feature/Analytics/UserResourceSnapshotModelTest.php                          (new — Task 1)
tests/Feature/Analytics/RollupServiceTest.php                                      (new — Task 2)
tests/Feature/Analytics/RollupSystemTest.php                                       (new — Task 2, system-gated)
tests/Feature/Analytics/RollupJobTest.php                                          (new — Task 3)
tests/Feature/Analytics/SchedulerTest.php                                          (new — Task 4)
tests/Feature/Analytics/AnalyticsControllerTest.php                                (new — Task 5)
resources/js/Pages/Analytics/Index.test.jsx                                        (new — Task 6)
```
