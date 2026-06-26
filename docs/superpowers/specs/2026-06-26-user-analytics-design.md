# Sub-project #13 — User-facing resource analytics (`user-analytics`)

- **Date:** 2026-06-26
- **Status:** Draft spec (revised — all open questions resolved)
- **Roadmap:** Phase 4, sub-project #13 of `docs/superpowers/specs/2026-06-25-laranode-feature-roadmap.md`
- **Branch:** `feature/user-analytics` (off `development`, after `platform-async-progress` merged)

## Goal

Today every stats view is gated behind `AdminMiddleware` — non-admin users see only their quota counts. This sub-project opens user-scoped historical analytics so a user can understand their own resource footprint: disk usage, per-site disk and traffic, per-database count, and SSL cert status, all without exposing host-global figures or other tenants' data.

**Success criteria:**
- A logged-in non-admin user reaches `/analytics` and sees charts scoped strictly to their own homedir, websites, and databases.
- Rollup data is pre-computed by the scheduler; page loads do not shell out to `du` or `wc` on-request.
- An admin sees `/analytics` for their own account (not all users); the admin `/stats/history` page is unchanged.
- No cross-tenant data leakage: Pest tests assert policy at the service layer and via HTTP; every analytics query uses explicit `where('user_id', $user->id)`, NOT `scopeMine()`.
- New scheduled rollup job is registered in the existing `withSchedule` hook in `bootstrap/app.php`.

## Resolved Decisions (formerly open questions)

1. **CPU/mem in user view:** OMITTED in v1. The host-level CPU/mem figures are not attributable per user. `UserResourceSnapshot` stores only disk. No `cpu_percent`, `mem_used_mb`, `net_rx_kb`, `net_tx_kb` columns.
2. **Bandwidth/network:** OMITTED in v1. `/proc/net/dev` gives host-level counters unattributable per user. Deferred.
3. **Apache log path:** ONE shared log per user at `/home/{username}_ln/logs/apache-access.log` (confirmed from `laranode-scripts/templates/apache-vhost.template`). The `CustomLog` directive is `CustomLog /home/{user}/logs/apache-access.log combined`. Traffic for all of a user's sites is in one file. `wc -l` on that file gives a total request count for the user, not per-site. Per-site disk via `du` on each site's directory is still meaningful.
4. **Rollup cadence:** daily for `UserResourceSnapshot` (disk + per-user log count); hourly for `UserSiteStat` (per-site disk).
5. **90-day retention:** confirmed for both tables.
6. **Admin analytics:** admins reach `/analytics` and see their own account data (disk, their own sites, SSL). No cross-user aggregation in v1.

## Architecture + Components

Three layers: a **scheduled rollup job** that collects per-user snapshots, **services** that read from the snapshot table (no on-request shelling), and **Inertia pages + React charts** (reusing `chart.js`/`react-chartjs-2`).

### 1. `user_resource_snapshots` table + `UserResourceSnapshot` model

**Migration `create_user_resource_snapshots_table`:**
- `id`, `user_id` (FK users → cascade), `snapshotted_at` (timestamp)
- `disk_bytes` (unsignedBigInteger) — total `du -sb {user->homedir}` bytes
- `apache_request_count` (unsignedBigInteger, nullable) — `wc -l` of `/home/{username}_ln/logs/apache-access.log`; null if log absent
- `timestamps`
- Index: `(user_id, snapshotted_at)`

**`UserResourceSnapshot` model (`app/Models/UserResourceSnapshot.php`):**
- `belongsTo(User::class)`, `$fillable` for all columns, casts `snapshotted_at` to datetime
- `MassPrunable` → `where('snapshotted_at', '<', now()->subDays(90))`
- **NO `scopeMine()`** — see security section below

**`UserSiteStat` model (`app/Models/UserSiteStat.php`):**

Per-website disk usage is tracked separately (frequency: hourly rollup, retention: 90 days).

- `id`, `website_id` (FK websites → cascade), `user_id` (FK users → cascade), `snapshotted_at` (timestamp), `disk_bytes` (unsignedBigInteger), `timestamps`
- Index: `(website_id, snapshotted_at)`
- `belongsTo(Website::class)`, `belongsTo(User::class)`, `MassPrunable` (90 days)
- **NO `scopeMine()`** — all queries use explicit `where('user_id', $user->id)`

### 2. Rollup jobs

Both extend `App\Jobs\OperationJob` for queue isolation, `operations` audit row, live `$emit` output, and `markFinished`/`failed` lifecycle.

**`App\Jobs\Analytics\RollupUserResourceSnapshotJob extends OperationJob`**

Constructed with `(Operation $operation, User $user)`. The `run(callable $emit): int` method delegates to `UserResourceSnapshotService::collect($user, $emit)` and returns 0. Any exception bubbles to the base class `handle()`, marks the operation `failed`, and rethrows. No snapshot row is written when `du` fails.

**`App\Jobs\Analytics\RollupSiteStatsJob extends OperationJob`**

Constructed with `(Operation $operation, User $user)`. Delegates to `UserSiteStatsService::collect($user, $emit)`.

**Scheduler registration** — extend the existing `withSchedule` closure in `bootstrap/app.php`:

```php
// Dispatch rollup for non-admin users in chunks to avoid loading all users at once
$schedule->call(function () {
    \App\Models\User::where('role', 'user')->chunkById(50, function ($users) {
        foreach ($users as $user) {
            $op = \App\Models\Operation::create([
                'user_id' => $user->id,
                'type'    => 'analytics.rollup',
                'target'  => $user->username,
            ]);
            \App\Jobs\Analytics\RollupUserResourceSnapshotJob::dispatch($op, $user);
        }
    });
})->daily()->name('analytics.resource-rollup');

$schedule->call(function () {
    \App\Models\User::where('role', 'user')->chunkById(50, function ($users) {
        foreach ($users as $user) {
            $op = \App\Models\Operation::create([
                'user_id' => $user->id,
                'type'    => 'analytics.site-rollup',
                'target'  => $user->username,
            ]);
            \App\Jobs\Analytics\RollupSiteStatsJob::dispatch($op, $user);
        }
    });
})->hourly()->name('analytics.site-rollup');
```

Prune for both models is added to the existing `model:prune` entry:
```php
$schedule->command('model:prune', ['--model' => [
    \App\Models\Operation::class,
    \App\Models\UserResourceSnapshot::class,
    \App\Models\UserSiteStat::class,
]])->daily();
```

### 3. Services

**`App\Services\Analytics\UserResourceSnapshotService`**

`collect(User $user, callable $emit): void`:
- Runs `du -sb {$user->homedir}` via `Process::run(...)`. If the process fails (exit code ≠ 0), throws a `\RuntimeException` — the base `OperationJob::handle()` catches it, marks the operation `failed`, rethrows. No snapshot row is written on failure.
- Counts requests: `wc -l /home/{username}_ln/logs/apache-access.log`. If process fails or log is absent, stores `null` (not an error — new users have no log yet).
- Writes one `UserResourceSnapshot` row on success only.

**Sar:** NOT used. CPU/mem omitted from v1. This removes the PHP-string awk interpolation bug entirely for this feature.

**`App\Services\Analytics\UserSiteStatsService`**

`collect(User $user, callable $emit): void`:
- Iterates `Website::where('user_id', $user->id)->get()`
- Per site: `Process::run(['du', '-sb', $site->websiteRoot])` → disk bytes. If `du` fails, throws `\RuntimeException` (same fail-fast pattern — no row written for that site, operation marked `failed`).
- Writes one `UserSiteStat` row per site (no Apache log per-site — all traffic is in the user-level log).

**`App\Services\Analytics\UserAnalyticsService`**

Read-only service called from the controller. All queries use explicit `where('user_id', $user->id)`:

```php
class UserAnalyticsService {
    public function getResourceHistory(User $user, int $days = 30): Collection { ... }
    public function getSiteStats(User $user, int $days = 30): Collection { ... }
    public function getQuotaSummary(User $user): array { ... }
    public function getSslOverview(User $user): Collection { ... }
}
```

`getQuotaSummary` uses `$user->websites()->count()` (relation exists on `User`) and `$user->databases()->count()`. The `databases()` `hasMany` relation does **not** currently exist on `User` and MUST be added as part of this feature. Without it `getQuotaSummary` will throw a fatal error.

`getSslOverview` reads `Website::where('user_id', $user->id)->get(['id','url','ssl_enabled','ssl_status','ssl_expires_at'])`. The `ssl_expires_at` column is nullable; the frontend SSL-expiry warning check MUST guard against null (a site with no SSL should never trigger an expiry warning).

### 4. Controller + routes

**`App\Http\Controllers\AnalyticsController`** — no `AdminMiddleware`. Admin users see their own account data. The controller never calls `Process` directly.

Route in `routes/web.php`:
```php
Route::get('/analytics', [\App\Http\Controllers\AnalyticsController::class, 'index'])
    ->middleware(['auth'])->name('analytics.index');
```

### 5. Frontend

**`resources/js/Pages/Analytics/Index.jsx`**

Inertia page accepting `{ resourceHistory, siteStats, quotaSummary, sslOverview }` props.

Sections:
- **Resource trends** — `<Line>` charts for disk GB and request count over the selected period (7/14/30 day toggle). If `resourceHistory` is empty, render "No data yet — stats are collected daily."
- **Per-site breakdown** — `<Bar>` chart for disk bytes per website. If `siteStats` is empty, render a notice.
- **Quota consumption** — two progress bars: websites (count/limit) and databases (count/limit), plus total disk used.
- **SSL overview** — compact table: domain, status badge, expiry date. Rows where `ssl_expires_at` is within 14 days are highlighted. **Guard:** only check expiry when `ssl_expires_at` is non-null: `row.ssl_expires_at && (new Date(row.ssl_expires_at) - Date.now()) < 14 * 86400 * 1000`.

No websocket subscription on this page.

**Nav link** — add "Analytics" entry to `AuthenticatedLayout` sidebar for all authenticated users, after "File Manager".

## Data Model (summary)

```
user_resource_snapshots
  id | user_id | snapshotted_at | disk_bytes | apache_request_count

user_site_stats
  id | website_id | user_id | snapshotted_at | disk_bytes
```

Both tables are written by rollup jobs, never by HTTP requests.

## Request / Data Flow

```
Scheduler (daily)
  └─> RollupUserResourceSnapshotJob::dispatch(op, user)
        └─> OperationJob::handle()
              └─> UserResourceSnapshotService::collect(user, $emit)
                    ├─> Process::run(['du', '-sb', user->homedir])  → throws on failure
                    ├─> Process::run(['wc', '-l', access.log])      → null-safe on failure
                    └─> UserResourceSnapshot::create([...])          → only on success

Scheduler (hourly)
  └─> RollupSiteStatsJob::dispatch(op, user)
        └─> UserSiteStatsService::collect(user, $emit)
              ├─> du per site  → throws on failure
              └─> UserSiteStat::create([...])

User visits /analytics
  └─> AnalyticsController::index
        └─> UserAnalyticsService (all queries: where user_id = $user->id)
              └─> Inertia::render('Analytics/Index', [...])
```

## Error Handling

- **du fails** (deleted homedir): `UserResourceSnapshotService::collect` throws; `OperationJob` marks operation `failed`, no snapshot row written. The analytics page shows the last successful snapshot. This is deterministic — the test MUST assert `status === 'failed'` and `UserResourceSnapshot::count() === 0`, not use `toBeIn(['succeeded','failed'])`.
- **wc -l fails** (no access log yet): stored as `null`; not an error. Charts skip null data points.
- **No snapshots yet**: `getResourceHistory` returns an empty Collection; page renders "No data yet" notice.
- **ssl_expires_at is null**: frontend checks `row.ssl_expires_at &&` before computing delta; SSL-less sites never show a false expiry warning. Backend sends null as-is.

## Security + Multi-tenancy

The central invariant: **a user must never see another tenant's data.**

1. **Explicit `where('user_id', $user->id)` on every analytics query** — `UserAnalyticsService` never uses `scopeMine()`. The `scopeMine()` admin-passthrough pattern (returning all rows for admins) is a multi-tenant leak on these analytics tables: an admin viewing their own `/analytics` would see every user's data. Analytics queries are always explicitly scoped to the requesting user regardless of role.
2. **`UserResourceSnapshot` and `UserSiteStat` do NOT implement `scopeMine()`** — removing the temptation to use it incorrectly. Tests assert that an admin user sees exactly their own 1 row (not all rows).
3. **Disk reads stay in `{user->homedir}`** — `du -sb {$user->homedir}` is scoped to the user's homedir.
4. **Apache log path** — `/home/{username}_ln/logs/apache-access.log` is a user-owned read-only file. The path is constructed from `$user->homedir` (a computed accessor, not user input).
5. **Controller auth** — `middleware('auth')` only. Admin users reach the same page and see their own account's data via explicit `where('user_id', $user->id)` — NOT through `scopeMine()` admin passthrough.
6. **No privileged scripts** — all rollup reads are unprivileged (`du`, `wc -l`). No new `sudoers` entries required.

## Interfaces / Contracts

No formal contracts — single concrete implementations. `UserAnalyticsService` is instantiated directly in the controller (matches `SystemStatsService` usage in `DashboardController`).

## Testing Strategy

### Pest (backend)

**`tests/Feature/Analytics/UserResourceSnapshotModelTest.php`**
- Prunable targets rows older than 90 days.
- Admin sees exactly their own 1 row when queried via `where('user_id', $admin->id)` — not all rows (asserts the model has no scopeMine admin passthrough).

**`tests/Feature/Analytics/AnalyticsControllerTest.php`**
- Non-admin user reaches `/analytics` (200) and receives the four Inertia props.
- Response data contains only rows belonging to the authenticated user.
- A user cannot see another user's `resourceHistory` or `siteStats`.
- Admin user reaches `/analytics` and sees exactly their own 1 row (not all users' data).
- Unauthenticated visitor is redirected to login.
- Empty `resourceHistory` when no snapshots exist.

**`tests/Feature/Analytics/RollupJobTest.php`**
- `Process::fake(['du *' => ..., 'wc *' => ...])`.
- Dispatch `RollupUserResourceSnapshotJob` (sync); assert one `UserResourceSnapshot` row with correct `user_id` and `disk_bytes`.
- Dispatch for two users; assert each gets their own row.
- **Failing `du` (exit code 1):** assert operation status is exactly `'failed'` AND `UserResourceSnapshot::count() === 0` — no `toBeIn`.
- `wc -l` fails (missing log): assert `apache_request_count === null`, operation succeeds.
- `RollupSiteStatsJob` writes one `UserSiteStat` per website.
- **`User::databases()` relation missing:** add to `app/Models/User.php` as part of this feature; add a regression test asserting `$user->databases()->count()` does not throw.

**`tests/Feature/Analytics/SchedulerTest.php`**
- Extend `tests/Feature/Operations/SchedulerTest.php` pattern: use `$this->artisan('schedule:list')->expectsOutputToContain('analytics')` — not `Schedule::events()` (known flaky in full-suite).
- Assert `model:prune` entry still present.

**`tests/Feature/Analytics/RollupSystemTest.php`** (gated `LARANODE_SYSTEM_TESTS=1`)
- Real `du` against the container user's homedir; assert a `UserResourceSnapshot` row is written with a plausible `disk_bytes` (> 0).
- Real `wc -l` on the access log (may be null if no log yet — assert it is either a positive integer or null).
- Real `du` on a real website directory; assert `UserSiteStat` row with `disk_bytes > 0`.
- These run in `local-dev` container only; skipped in standard CI.

### Vitest (frontend)

**`resources/js/Pages/Analytics/Index.test.jsx`**
- Render with mocked props; assert `<Line>` chart renders.
- Assert SSL table shows domain + expiry date.
- Assert "No data yet" notice renders when `resourceHistory` is empty.
- Assert SSL row with null `ssl_expires_at` does NOT render an expiry warning.
- Assert SSL row expiring in 10 days renders a warning indicator.
- Assert quota progress bars show counts.

## Required Code Change: `User::databases()` relation

`app/Models/User.php` does not have a `databases()` `hasMany` relation. `UserAnalyticsService::getQuotaSummary` calls `$user->databases()->count()`. This MUST be added:

```php
public function databases(): \Illuminate\Database\Eloquent\Relations\HasMany
{
    return $this->hasMany(\App\Models\Database::class);
}
```

This is a REQUIRED edit (not optional/conditional). A test must assert it does not throw.

## Back-compat / Migration

- **No existing routes or controllers changed.** `/stats/history` and `StatsHistoryController` are untouched.
- **`bootstrap/app.php` `withSchedule` closure extended** — new models added to `model:prune`; rollup jobs added. The existing `Operation` prune entry stays.
- **`UserDashboard.jsx` unchanged** — the new `/analytics` page is additive.
- **`User::databases()` relation added** — backward-compatible addition; no existing call sites are affected.
- **Migration rollback** — both new tables have `down()` with `dropIfExists`.

## File Inventory

```
database/migrations/XXXX_create_user_resource_snapshots_table.php   (new)
database/migrations/XXXX_create_user_site_stats_table.php            (new)
app/Models/UserResourceSnapshot.php                                   (new)
app/Models/UserSiteStat.php                                           (new)
app/Models/User.php                                                   (modify: add databases() relation)
app/Services/Analytics/UserResourceSnapshotService.php                (new)
app/Services/Analytics/UserSiteStatsService.php                       (new)
app/Services/Analytics/UserAnalyticsService.php                       (new)
app/Jobs/Analytics/RollupUserResourceSnapshotJob.php                  (new)
app/Jobs/Analytics/RollupSiteStatsJob.php                             (new)
app/Http/Controllers/AnalyticsController.php                          (new)
routes/web.php                                                         (modify: add /analytics route)
bootstrap/app.php                                                      (modify: extend withSchedule)
resources/js/Pages/Analytics/Index.jsx                                 (new)
resources/js/Layouts/AuthenticatedLayout.jsx                           (modify: add nav link)
tests/Feature/Analytics/UserResourceSnapshotModelTest.php              (new)
tests/Feature/Analytics/AnalyticsControllerTest.php                    (new)
tests/Feature/Analytics/RollupJobTest.php                              (new)
tests/Feature/Analytics/SchedulerTest.php                              (new, extends SchedulerTest pattern)
tests/Feature/Analytics/RollupSystemTest.php                           (new, LARANODE_SYSTEM_TESTS gated)
resources/js/Pages/Analytics/Index.test.jsx                            (new, Vitest)
```

## Out of Scope (later sub-projects / deferred)

- Real-time / live analytics via Reverb.
- Per-process CPU attribution per user.
- Host-level CPU/mem in user view (deferred — not attributable per user).
- Per-user bandwidth (deferred — `/proc/net/dev` is host-level).
- Per-site traffic counts (deferred — Apache logs all sites to one shared file per user; per-site attribution would require log parsing with `grep` on the URL field).
- Export / download of analytics data.
- Admin view of analytics for arbitrary users.
- Alerting/thresholds — that is `monitoring-alerts` (#11).
