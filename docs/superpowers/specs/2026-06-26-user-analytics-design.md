# Sub-project #13 — User-facing resource analytics (`user-analytics`)

- **Date:** 2026-06-26
- **Status:** Draft spec (ready for review)
- **Roadmap:** Phase 4, sub-project #13 of `docs/superpowers/specs/2026-06-25-laranode-feature-roadmap.md`
- **Branch:** `feature/user-analytics` (off `development`, after `platform-async-progress` merged)

## Goal

Today every stats view (`/dashboard/admin`, `/stats/history`, Reverb live channels) is gated behind `AdminMiddleware` — non-admin users see only their quota counts (`websitesCount`/`databasesCount` vs limits). This sub-project opens user-scoped historical analytics so a user can understand their own resource footprint: CPU/memory/disk/bandwidth over time, per-site disk usage and traffic, per-database size, and SSL cert status, all without exposing host-global figures or other tenants' data.

**Success criteria:**
- A logged-in non-admin user reaches `/analytics` and sees charts scoped strictly to their own homedir, websites, and databases.
- Rollup data is pre-computed by the scheduler; page loads do not shell out to `sar` or `du` on-request.
- An admin sees `/analytics` for their own account (not all users); the admin `/stats/history` page is unchanged.
- No cross-tenant data leakage: Pest tests assert policy at the service layer and via HTTP; `scopeMine()` guards every DB query.
- New scheduled rollup job is registered in the existing `withSchedule` hook in `bootstrap/app.php`.

## Architecture + Components

The feature composes three layers: a new **scheduled rollup job** that collects per-user snapshots on a cron cadence, a **set of services** that read from the snapshot table (fast, no on-request shelling), and **new Inertia pages + React charts** (reusing `chart.js`/`react-chartjs-2` already in the stack from `Stats/History.jsx`).

### 1. `user_resource_snapshots` table + `UserResourceSnapshot` model

Single denormalized table written by the rollup job, read by the analytics controller.

**Migration `create_user_resource_snapshots_table`:**
- `id`, `user_id` (FK users → cascade), `snapshotted_at` (timestamp, indexed with `user_id`)
- `disk_bytes` (bigInteger) — total `du -sb {user->homedir}` bytes
- `cpu_percent` (decimal 5,2, nullable) — from `sar -u` last interval; null if sar unavailable
- `mem_used_mb` (integer, nullable) — from `sar -r` last interval
- `net_rx_kb` (bigInteger, nullable) — cumulative host `/proc/net/dev` RX bytes at snapshot time (delta computed in JS/service layer)
- `net_tx_kb` (bigInteger, nullable) — cumulative TX bytes
- `timestamps`
- Index: `(user_id, snapshotted_at)`

**`UserResourceSnapshot` model (`app/Models/UserResourceSnapshot.php`):**
- `belongsTo(User::class)`, `$fillable` for all snapshot columns, casts `snapshotted_at` to datetime
- `MassPrunable` → `where('snapshotted_at', '<', now()->subDays(90))` (90-day retention, registered alongside `Operation` prune in `bootstrap/app.php`)
- `scopeMine(Builder): Builder` — mirrors `Website`/`Database`: filter `user_id` for non-admins

**`UserSiteStat` model (`app/Models/UserSiteStat.php`):**

Per-website disk usage is tracked separately (frequency: hourly rollup, retention: 90 days).

- `id`, `website_id` (FK websites → cascade), `user_id` (FK users → cascade), `snapshotted_at` (timestamp), `disk_bytes` (bigInteger), `apache_access_count` (bigInteger, nullable — parsed from access log byte-count or `wc -l` of the day's log)
- Index: `(website_id, snapshotted_at)`
- `belongsTo(Website::class)`, `belongsTo(User::class)`, `MassPrunable` (90 days), `scopeMine()`

### 2. Rollup jobs

Both extend the existing abstract `App\Jobs\OperationJob` so they get: queue isolation, `operations` audit row, live output via `$emit`, and `markFinished`/`failed` lifecycle for free.

**`App\Jobs\Analytics\RollupUserResourceSnapshotJob extends OperationJob`**

Constructed with `(Operation $operation, User $user)`. The `run(callable $emit): int` method:
1. Calls `(new UserResourceSnapshotService())->collect($user, $emit)`.
2. Returns 0; any exception bubbles to the base class `handle()` and marks the operation `failed`.

**`App\Jobs\Analytics\RollupSiteStatsJob extends OperationJob`**

Constructed with `(Operation $operation, User $user)`. Delegates to `UserSiteStatsService::collect($user, $emit)`.

**Scheduler registration** — extend the existing `withSchedule` closure in `bootstrap/app.php`:

```php
// dispatch a rollup for every non-admin user, hourly
$schedule->call(function () {
    \App\Models\User::where('role', 'user')->each(function ($user) {
        $op = \App\Models\Operation::create([
            'user_id' => $user->id,
            'type'    => 'analytics.rollup',
            'target'  => $user->username,
        ]);
        \App\Jobs\Analytics\RollupUserResourceSnapshotJob::dispatch($op, $user);

        $op2 = \App\Models\Operation::create([
            'user_id' => $user->id,
            'type'    => 'analytics.site-rollup',
            'target'  => $user->username,
        ]);
        \App\Jobs\Analytics\RollupSiteStatsJob::dispatch($op2, $user);
    })->daily(); // start daily; can be moved to hourly once verified stable
})->daily();
```

The prune for both models is also registered here:
```php
$schedule->command('model:prune', ['--model' => [
    \App\Models\Operation::class,
    \App\Models\UserResourceSnapshot::class,
    \App\Models\UserSiteStat::class,
]])->daily();
```

### 3. Services

**`App\Services\Analytics\UserResourceSnapshotService`**

Single `collect(User $user, callable $emit): void` method:
- Runs `du -sb {$user->homedir}` via `Process::run(...)` → extracts bytes → `$emit("disk: {$bytes} bytes")`
- Reads host CPU/mem from the most recent `sar` sample via the existing `SarHistory`-derived approach (`Process::pipe(['sar -u 1 1', 'awk ...'])`) — note: this is a host-global sample; it is stored per-user row only as a reference snapshot for that user's own view (not cross-tenant; each user's row holds the same host values but is accessed only through `scopeMine`)
- Reads `/proc/net/dev` cumulative counters (same approach as `SystemStatsService::getNetworkStats()`)
- Writes one `UserResourceSnapshot` row: `UserResourceSnapshot::create([...])`

**`App\Services\Analytics\UserSiteStatsService`**

Single `collect(User $user, callable $emit): void`:
- Iterates `Website::where('user_id', $user->id)->get()`
- Per site: `Process::run(['du', '-sb', $website->websiteRoot])` → disk bytes
- Per site: counts today's Apache access log lines: `Process::run(['wc', '-l', "/var/log/apache2/{$website->url}-access.log"])` → parse integer (null-safe: log may not exist)
- Writes one `UserSiteStat` row per site

**`App\Services\Analytics\UserAnalyticsService`**

Read-only service called from the controller. All queries go through `scopeMine()`:
```php
class UserAnalyticsService {
    public function getResourceHistory(User $user, int $days = 30): Collection { ... }
    public function getSiteStats(User $user, int $days = 30): Collection { ... }
    public function getQuotaSummary(User $user): array { ... }      // reads User + DB counts
    public function getSslOverview(User $user): Collection { ... }  // reads Website->ssl_*
}
```

`getQuotaSummary` reuses the same logic as `DashboardController::user()` (already present) plus total disk from the latest `UserResourceSnapshot::where('user_id', $user->id)->latest('snapshotted_at')->first()`.

`getSslOverview` reads `Website::where('user_id', $user->id)->get(['url','ssl_enabled','ssl_status','ssl_expires_at'])` — no system call needed.

### 4. Controller + routes

**`App\Http\Controllers\AnalyticsController`**

```php
class AnalyticsController extends Controller
{
    public function index(Request $request): \Inertia\Response
    {
        $user = $request->user();
        $svc  = new UserAnalyticsService();

        return Inertia::render('Analytics/Index', [
            'resourceHistory' => $svc->getResourceHistory($user),
            'siteStats'       => $svc->getSiteStats($user),
            'quotaSummary'    => $svc->getQuotaSummary($user),
            'sslOverview'     => $svc->getSslOverview($user),
        ]);
    }
}
```

No `AdminMiddleware` — available to all authenticated users. Admin users see their own account data (not all users). The controller never calls `Process` directly; all data comes from the snapshot table or `Website`/`Database` model queries.

**Routes** (in `routes/web.php`, in the user-accessible section):
```php
Route::get('/analytics', [\App\Http\Controllers\AnalyticsController::class, 'index'])
    ->middleware(['auth'])->name('analytics.index');
```

### 5. Frontend

**`resources/js/Pages/Analytics/Index.jsx`**

Inertia page accepting `{ resourceHistory, siteStats, quotaSummary, sslOverview }` props.

Sections:
- **Resource trends** — reuses the `CPUChart`/`MemoryChart` pattern from `resources/js/Pages/Stats/Components/CPUChart.jsx` / `MemoryChart.jsx`. Renders `<Line>` charts from `react-chartjs-2` for CPU%, memory MB, disk GB, and net RX/TX over the selected period (last 7/14/30 days toggle).
- **Per-site breakdown** — `<Bar>` chart for disk bytes per website; table for access-log counts (same data, different presentation).
- **Quota consumption** — two progress bars: websites (count/limit) and databases (count/limit), plus total disk used. Mirrors the widget already on `UserDashboard.jsx`.
- **SSL overview** — compact table: domain, status badge, expiry date. Reuses the SSL status colour/text helpers from `Website` model serialization; highlights certs expiring within 14 days.

No websocket subscription on this page — it reads from the snapshot table (pre-computed). No `useOperation` hook needed here; analytics is not a live-streaming view.

**Nav link** — add "Analytics" entry to `AuthenticatedLayout` sidebar for non-admin users (and for admin when viewing their own account), below "File Manager".

## Data Model (summary)

```
user_resource_snapshots
  id | user_id | snapshotted_at | disk_bytes | cpu_percent | mem_used_mb | net_rx_kb | net_tx_kb

user_site_stats
  id | website_id | user_id | snapshotted_at | disk_bytes | apache_access_count
```

Both tables are written by rollup jobs, never by HTTP requests. The `UserResourceSnapshot` CPU/mem columns hold host-global samples (same sample written per user) — this is intentional; they represent the shared host context visible in that user's view but are read only through `scopeMine()`.

## Request / Data Flow

```
Scheduler (daily/hourly)
  └─> RollupUserResourceSnapshotJob::dispatch(op, user)
        └─> OperationJob::handle()
              └─> UserResourceSnapshotService::collect(user, $emit)
                    ├─> Process::run(['du', '-sb', user->homedir])
                    ├─> Process::pipe(['sar -u 1 1', 'awk ...'])
                    ├─> /proc/net/dev read
                    └─> UserResourceSnapshot::create([...])
                         └─> Operation::appendOutput($line)  → OperationUpdated broadcast

User visits /analytics
  └─> AnalyticsController::index
        └─> UserAnalyticsService (reads snapshot table via scopeMine)
              └─> Inertia::render('Analytics/Index', [...])
                    └─> React: Line/Bar charts + SSL table
```

The operation row created by the scheduler rollup is visible in `/admin/operations` (admin only) and shows output lines from the rollup for debugging. Users do not see rollup operations on their own operations page (operations are type-filtered in a future iteration; for now they appear in the admin audit log only).

## Error Handling

- **Rollup job fails** (e.g. `du` errors on a deleted homedir): `OperationJob` base catches the exception, appends `ERROR: ...` to the operation output, marks it `failed`, rethrows to `failed_jobs`. No snapshot row is written for that run; the page shows the last successful snapshot. Gap is visible in the chart as missing data points (no error thrown to the user).
- **sar unavailable** (host without sysstat): `UserResourceSnapshotService::collect` detects the null/failed `Process` result, stores `cpu_percent = null`, `mem_used_mb = null`. Charts omit those data points (Chart.js treats `null` as a gap by default).
- **Apache log missing** for a site (new site with no traffic yet): `wc -l` on a non-existent file returns an error; catch and store `apache_access_count = null`.
- **No snapshots yet** (user just created; rollup hasn't run): `UserAnalyticsService::getResourceHistory` returns an empty Collection; the Inertia page renders a "No data yet — stats are collected daily" notice.
- **Controller**: No `try/catch` in the controller — service reads are safe SQL queries. 404/403 handled by standard Laravel middleware.

## Security + Multi-tenancy

The central invariant: **a user must never see another tenant's data or host-global figures presented as their own.**

1. **`scopeMine()` on every query** — `UserResourceSnapshot` and `UserSiteStat` both implement `scopeMine()` matching `Website`/`Database`. `UserAnalyticsService` always calls `->mine()` on its queries; tests assert that a non-admin user cannot retrieve another user's rows.
2. **Disk reads stay in `{user->homedir}`** — `du -sb {$user->homedir}` is scoped to the user's homedir. No `su` or cross-user traversal.
3. **Apache log path** — `"/var/log/apache2/{$website->url}-access.log"` is read-only, not executed. The website row belongs to the requesting user (verified via `where('user_id', $user->id)` before passing to the service — no path traversal possible via URL because URL is stored in the DB, not taken from user input at query time).
4. **CPU/mem columns** — host-global samples stored per-user row. This is the same trade-off the admin dashboard already makes; the user sees their resource context on the shared host, not a per-process breakdown of their work. No other tenant's row is returned.
5. **Controller auth** — `middleware('auth')` only; no `AdminMiddleware`. Admin users reach the same page and see their own account's data through `scopeMine()` (which passes through all rows for admins) — but `UserAnalyticsService` explicitly queries `where('user_id', $user->id)` not the `scopeMine()` admin passthrough, so admin sees their own data only on this page.
6. **No privileged scripts** — all rollup reads are unprivileged reads (`du`, `/proc/net/dev`, `sar`) or SQL queries. No new `sudoers` entries required.

## Interfaces / Contracts

`UserResourceSnapshotService` and `UserSiteStatsService` do not need a formal contract interface (single concrete implementations). If a second stats source is added later (e.g. Nginx logs), introduce a `UserSiteTrafficContract` at that point — YAGNI now.

`UserAnalyticsService` is instantiated directly in the controller (matches `SystemStatsService` usage in `DashboardController` — no DI binding needed).

## Testing Strategy

### Pest (backend)

**`tests/Feature/Analytics/UserResourceSnapshotModelTest.php`**
- `scopeMine` returns only the authenticated user's rows; admin query returns all.
- `prunable()` targets rows older than 90 days.

**`tests/Feature/Analytics/AnalyticsControllerTest.php`**
- A non-admin user reaches `/analytics` (200) and receives the four Inertia props.
- The response data contains only rows belonging to the authenticated user.
- A user cannot see another user's `resourceHistory` or `siteStats` rows.
- Admin user reaches `/analytics` and sees their own data (not all users' data).

**`tests/Feature/Analytics/RollupJobTest.php`**
- `Process::fake(['du *' => Process::result('12345\t/home/user1_ln', exitCode: 0), 'sar *' => ..., ...])`.
- Dispatch `RollupUserResourceSnapshotJob` (QUEUE_CONNECTION=sync); assert one `UserResourceSnapshot` row created with correct `user_id` and `disk_bytes`.
- Dispatch for two users; assert each gets their own row (no cross-contamination).
- Failing `du` (exit code 1): assert operation marked `failed`, no snapshot row written.

**`tests/Feature/Analytics/SchedulerTest.php`**
- Extend the existing `SchedulerTest` pattern: assert `analytics.rollup` job class appears in `Schedule::events()`.

### Vitest (frontend)

**`resources/js/Pages/Analytics/Index.test.jsx`**
- Render with mocked props (`resourceHistory = [{ snapshotted_at, disk_bytes, cpu_percent, ... }]`, etc.)
- Assert `<Line>` chart renders (check canvas element exists or chart container).
- Assert SSL table shows domain + expiry date.
- Assert "No data yet" notice renders when `resourceHistory` is empty.

## Back-compat / Migration

- **No existing routes or controllers changed.** `/stats/history` admin page and `StatsHistoryController` are untouched.
- **`bootstrap/app.php` `withSchedule` closure extended** — new models added to the `model:prune` array; rollup jobs added. Non-breaking: existing `Operation` prune entry stays.
- **`UserDashboard.jsx` unchanged** — quota counts already on that page; the new `/analytics` page is additive, linked from the dashboard's "Manage Websites" / "Manage MySQL DBs" area or the nav sidebar.
- **No existing model changes** — `User`, `Website`, `Database` are read-only from this feature.
- **Migration rollback** — both new tables have `down()` with `dropIfExists`.

## File Inventory

```
database/migrations/XXXX_create_user_resource_snapshots_table.php   (new)
database/migrations/XXXX_create_user_site_stats_table.php            (new)
app/Models/UserResourceSnapshot.php                                   (new)
app/Models/UserSiteStat.php                                           (new)
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
tests/Feature/Analytics/SchedulerTest.php                              (extend existing pattern)
resources/js/Pages/Analytics/Index.test.jsx                            (new, Vitest)
```

## Out of Scope (later sub-projects / deferred)

- Real-time / live analytics via Reverb (no `useOperation` hook on this page — pre-computed snapshots are the design choice).
- Per-process CPU attribution per user (would require `ps aux --user {username}_ln` parsing and a privileged read).
- Export / download of analytics data (CSV etc.).
- Admin view of analytics for arbitrary users (that would belong to a future "admin user drill-down" feature under `teams-rbac` or a monitoring expansion).
- Bandwidth at Apache request level (full access-log parsing with bytes-per-request) — `wc -l` (request count) is the v1 proxy; upgrade to `awk` sum of bytes field if needed.
- Alerting/thresholds on resource analytics — that is `monitoring-alerts` (#11).

## Open Questions

1. **Rollup frequency** — daily is proposed to keep queue load low. Should it be hourly for disk/traffic (site stats change quickly), keeping the host CPU/mem rollup daily? Confirm before implementation.
2. **CPU/mem per-user or host-global?** — The current design stores the host's overall CPU/mem in each user's snapshot row. An alternative is to omit CPU/mem for non-admin users entirely (they share the host; the number is not "theirs"). Which is preferred?
3. **Apache log path** — assumes `/var/log/apache2/{website->url}-access.log`. Confirm this matches the actual vhost template in `laranode-scripts/templates/`.
4. **90-day retention** — same as `Operation` (30 days) or longer? The spec uses 90 days; confirm whether the operator wants a config knob.
5. **Admin analytics page** — current spec sends admin to `/analytics` showing their own account data. Should admins instead land on a cross-user aggregated view (e.g., all users' disk usage ranked)? If yes, that's a separate route/page.
6. **`net_rx_kb` / `net_tx_kb` scope** — `/proc/net/dev` gives host-level cumulative counters, not per-user bandwidth. Is this acceptable for v1, or should v1 omit bandwidth entirely and leave it for a future `sar -n DEV` per-vhost approach?
