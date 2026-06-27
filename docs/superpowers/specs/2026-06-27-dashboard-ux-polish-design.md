# Sub-project — dashboard-ux-polish (batched UX improvements + bug fixes)

- **Date:** 2026-06-27
- **Status:** Draft
- **Branch:** `feature/dashboard-ux-polish` (off `development`)

## Goal

A single sweep of discrete UX, polish, and bug-fix items across the admin dashboard, sidebar, file manager, PHP manager, accounts, databases, and operations pages. No new backend domain models or migrations are required for most items; all changes are targeted and surgical.

Items are lettered by their original tracking ID (D1, D2, …). Each section identifies the real file(s) involved, the change, and its test layer.

---

## Architecture overview

No new domain models or migrations. No new bash scripts or sudoers entries unless noted per item. No `OperationJob` usage (none of these items are long-running privileged ops).

Patterns used:
- Dashboard stats: `SystemStatsService::getAllStats()` in `app/Services/Dashboard/SystemStatsService.php`, broadcast via `SystemStatsEvent` → `private-systemstats` channel, listened in `AdminDashboard.jsx` and `TopProcesses.jsx` via `window.Echo`.
- Engine awareness: `App\Databases\EngineManager::available()` checks `config('laranode.db_engines')` (`config/laranode.php`) via `Process::run(['systemctl', 'is-active', ...])`.
- Layout: `AuthenticatedLayout.jsx` hosts `SidebarNavi.jsx`; main content sits in `<div className="h-full ml-14 mt-14 mb-10 md:ml-64">`.
- Impersonation: `lab404/laravel-impersonate`; route `accounts.impersonate` handled in `AccountsController::impersonate()`.
- PHP detection: `PHPManagerController::list()` calls `laranode-scripts/bin/laranode-php-list.sh` (reads `dpkg -l` + `systemctl`) and returns JSON to `PHP/Index.jsx`.

---

## D1 — Dashboard stats blank-on-refresh

### Problem

`AdminDashboard.jsx` starts with `liveStats` as an empty array (`useState([])`). The dashboard only populates once the Reverb whisper-poll cycle fires (every ~2 seconds after mount). On page load or hard refresh, all stat widgets show spinners until the first websocket response arrives.

### Solution

**Server-side last-known cache** with a short TTL (90 seconds). On every `SystemStatsEvent` dispatch (in `SystemStatsEvent::__construct()`), after computing stats, write them to `Cache::put('dashboard_stats_last_known', $stats, 90)`. The `DashboardController::admin()` method passes the cached value as an initial Inertia prop. The React page seeds `liveStats` from that prop on mount, so widgets render immediately.

### Real files

| File | Change |
|------|--------|
| `app/Events/SystemStatsEvent.php` | After calling `SystemStatsService::getAllStats()`, add `Cache::put('dashboard_stats_last_known', $this->stats, 90)` |
| `app/Http/Controllers/DashboardController.php` | In `admin()`, read `$initialStats = Cache::get('dashboard_stats_last_known', [])` and pass it to `Inertia::render('Dashboard/Admin/AdminDashboard', compact('initialStats'))` |
| `resources/js/Pages/Dashboard/Admin/AdminDashboard.jsx` | Accept `initialStats` prop; pass to `useState(initialStats ?? [])` instead of `useState([])`. The existing `useEffect`/whisper/`setLiveStats` logic is unchanged — live updates continue to overwrite the seed |

### No migration, no new scripts, no sudoers.

### Testing

- **Pest (unit):** `tests/Feature/Dashboard/DashboardStatsTest.php` — assert that dispatching `SystemStatsEvent` writes `dashboard_stats_last_known` to Cache; assert `DashboardController::admin()` passes `initialStats` in the Inertia response (using `Inertia::assertRendered`).
- **Vitest:** `resources/js/Pages/Dashboard/Admin/AdminDashboard.test.jsx` — render with `initialStats` prop containing sample data; assert that CPU stat text appears immediately without waiting for an echo event (i.e., not showing a spinner on first render).

---

## D2 — Top-processes pie/donut chart

### Problem

`TopProcesses.jsx` shows a table of 20 processes sorted by CPU or memory but has no visual summary of which processes are consuming the most resources.

### Solution

Add a `<TopProcessesChart />` component above the existing table inside `TopProcesses.jsx`. It renders a react-chartjs-2 `Doughnut` chart using the existing `topStats` array that is already managed in `TopProcesses.jsx`'s local state via the `private-topstats` Reverb channel.

- The chart aggregates `cpu` (or `mem` depending on `sortBy`) per `mainCmd`. Processes with less than 1% each are merged into an "Other" slice.
- Hovering a slice shows a tooltip: `process.mainCmd — X% CPU / Y% MEM`.
- Toggle (CPU / Memory) is driven by the existing `sortBy` state — switching sort also switches which metric is visualised.
- Chart is only shown when `topStats.length > 0`.

Chart.js and react-chartjs-2 are already present in the project (used by `CPULive`, `MemoryLive` etc.).

### Real files

| File | Change |
|------|--------|
| `resources/js/Pages/Dashboard/Admin/Components/TopProcesses.jsx` | Import `Doughnut` from `react-chartjs-2`; build chart data from `topStats`; render `<TopProcessesChart />` (can be a local const component or extracted to `Components/TopProcessesChart.jsx`) above the existing `<table>` |

Optionally extract to `resources/js/Pages/Dashboard/Admin/Components/TopProcessesChart.jsx` (new) for testability.

### No backend change. No migration. No script.

### Data shape

`topStats` items already have: `{ user, cpu, mem, pid, mainCmd, restOfCmd }`. The chart reads `cpu` (string, e.g. `"3.5"`) or `mem` and converts to float.

### Testing

- **Vitest:** `resources/js/Pages/Dashboard/Admin/Components/TopProcesses.test.jsx` (new) — render with `topStats` sample data; assert the canvas element is present; assert "Other" slice appears when many small processes exist; assert chart does not render when `topStats` is empty.

---

## D3 — Surface PostgreSQL (and MariaDB) in the DB service widget

### Problem

`MySQLLive.jsx` hardcodes the label "MySQL" and `TbBrandMysql` icon regardless of which engines are installed. `SystemStatsService::getMysqlStatus()` only queries `systemctl status mysql`. If PostgreSQL or MariaDB is the primary engine, those services are not reflected on the dashboard.

### Solution

**Backend:** Extend `SystemStatsService::getAllStats()` to include status for all engines reported as active by `EngineManager::available()`. Rename the key from `mysql` to `dbEngines` (a map of `engineKey → status`). Each entry is produced by the same `systemctl status` pipe pattern already in `getMysqlStatus()`. Extract a private `getServiceStatus(string $service): array` method to avoid code duplication.

**Config:** `config('laranode.db_engines')` already maps `mysql → mysql`, `mariadb → mariadb`, `postgres → postgresql`; `EngineManager::available()` handles detection. `SystemStatsService` should inject or `new` an `EngineManager` instance to call `available()`.

**Frontend:** Replace `MySQLLive.jsx` with a new generic `DbEnginesLive.jsx` component. It receives a `dbEngines` prop (a map of `engineKey → { pid, memory, cpuTime, uptime }`). It renders one card per active engine, using a neutral database icon (`TbDatabase` from `react-icons/tb`, already imported in `Databases/Index.jsx`) for unknown engines, `TbBrandMysql` for `mysql`/`mariadb`, and a `BiLogoPostgresql` or `FaDatabase` icon for `postgres`.

**`AdminDashboard.jsx`:** Replace `<MySQLLive mysqlStats={liveStats.mysql} />` with `<DbEnginesLive dbEngines={liveStats.dbEngines} />`.

**`SystemStatsEvent`** broadcasts the full stats array including the new `dbEngines` key — no change to the event class itself, since it calls `getAllStats()`.

### Real files

| File | Change |
|------|--------|
| `app/Services/Dashboard/SystemStatsService.php` | Add `getServiceStatus(string $service): array`; add `getDbEnginesStatus(): array` (iterates `EngineManager::available()`); replace `'mysql' => $this->getMysqlStatus()` with `'dbEngines' => $this->getDbEnginesStatus()` in `getAllStats()` |
| `app/Events/SystemStatsEvent.php` | No change — already calls `getAllStats()` |
| `resources/js/Pages/Dashboard/Admin/Components/MySQLLive.jsx` | Rename/replace with `DbEnginesLive.jsx` |
| `resources/js/Pages/Dashboard/Admin/Components/DbEnginesLive.jsx` | New component accepting `dbEngines` prop |
| `resources/js/Pages/Dashboard/Admin/AdminDashboard.jsx` | Swap `MySQLLive` import+usage for `DbEnginesLive`, pass `liveStats.dbEngines` |
| `resources/js/Pages/PHP/Index.jsx` | PHP page also subscribes to `systemstats` and reads `data.phpFpm`; no change needed here since `phpFpm` key is unchanged |

### Back-compat note

The `mysql` key in `getAllStats()` is removed and replaced with `dbEngines`. Both the frontend and the cache (`dashboard_stats_last_known`) are owned by this codebase; there is no external consumer of the `mysql` key. `PHP/Index.jsx` reads `data.phpFpm` (unchanged).

### Testing

- **Pest (unit):** `tests/Feature/Dashboard/DbEnginesStatusTest.php` — mock `EngineManager::available()` to return `['mysql' => 'mysql']`; assert `SystemStatsService::getDbEnginesStatus()` returns a map with `mysql` key containing the expected shape; mock `available()` to return `['postgres' => 'postgresql', 'mysql' => 'mysql']`; assert both keys present.
- **Vitest:** `resources/js/Pages/Dashboard/Admin/Components/DbEnginesLive.test.jsx` (new) — render with `dbEngines = { mysql: { memory: '64M', cpuTime: '0h1m', uptime: '2 days' } }`; assert "MySQL" label and memory appear; render with `dbEngines = { postgres: { ... } }`; assert "Postgres" label appears.

---

## D4 — Center the main panel content

### Problem

`AuthenticatedLayout.jsx` wraps children in `<div className="ml-3 pr-3">` inside `<div className="h-full ml-14 mt-14 mb-10 md:ml-64">`. Pages that themselves use `max-w-7xl` sit left-aligned within their container; there is no horizontal centering.

### Solution

Add `mx-auto` to the inner children wrapper in `AuthenticatedLayout.jsx`:

```jsx
// before:  <div className="ml-3 pr-3">
// after:   <div className="ml-3 pr-3 mx-auto max-w-screen-xl">
```

Alternatively, keep `ml-3 pr-3` for pages that intentionally span full width (file manager, operations) and apply centering at the page level. The cleaner option is a class on the layout wrapper so all pages benefit without touching every page.

Because pages like `AdminDashboard.jsx` already cap their content with `max-w-7xl` and `Filemanager.jsx` also uses `max-w-7xl`, the layout-level cap of `max-w-screen-xl` (≈1280px) is consistent and safe.

### Real files

| File | Change |
|------|--------|
| `resources/js/Layouts/AuthenticatedLayout.jsx` | Inner div: add `mx-auto` (and optionally `max-w-screen-xl`) to the children wrapper |

### No backend change. No tests required (pure layout CSS class). Visual regression is the verification.

---

## D5 — Collapsible sidebar with persisted state

### Problem

`SidebarNavi.jsx` currently has a mobile toggle (`isSidebarOpen` state) that collapses the sidebar to `w-14` on small screens. On desktop (`md:w-64`) the sidebar is always expanded. There is no way to collapse the sidebar on desktop and no persistence of the user's preference.

### Solution

- Move collapse state to `localStorage` (key: `laranode_sidebar_collapsed`). On mount, read from `localStorage`; default to `false` (expanded).
- Replace the current dual-width logic (`${isSidebarOpen ? 'w-64' : 'w-14'} md:w-64`) with a single width driven by `isCollapsed`: `${isCollapsed ? 'w-14' : 'w-64'}`.
- Add a toggle button (hamburger / chevron icon) visible on all breakpoints, positioned at the top of the sidebar.
- When collapsed (`w-14`), item labels are hidden (existing `truncate` + hidden span approach is already in place on mobile).
- `AuthenticatedLayout.jsx`'s `ml-14` / `md:ml-64` margin must adapt: pass `isCollapsed` down from `SidebarNavi` to the parent, or lift state up into `AuthenticatedLayout`. The simplest approach is a shared context or a CSS variable on `<body>`.

**Recommended approach:** Lift collapsed state into `AuthenticatedLayout.jsx` (passes `isCollapsed` + `setIsCollapsed` as props to `SidebarNavi`). `AuthenticatedLayout` switches `ml-14` vs `ml-64` based on `isCollapsed`. This avoids a global context.

### Real files

| File | Change |
|------|--------|
| `resources/js/Layouts/AuthenticatedLayout.jsx` | Add `isCollapsed` state (seeded from `localStorage`); pass to `SidebarNavi`; switch content margin (`ml-14` vs `md:ml-64`) based on state |
| `resources/js/Layouts/Partials/SidebarNavi.jsx` | Accept `isCollapsed` + `setIsCollapsed` props; on mount, sync with `localStorage`; write to `localStorage` on toggle; update width classes to use `isCollapsed` |

### Testing

- **Vitest:** `resources/js/Layouts/Partials/SidebarNavi.test.jsx` (new) — render collapsed sidebar; assert nav labels are hidden; click toggle; assert sidebar expands; assert `localStorage.setItem` called with `laranode_sidebar_collapsed`.

---

## D6 — Operations page dark-mode styles

### Problem

`resources/js/Pages/Operations/Index.jsx` uses minimal Tailwind classes with no `dark:` variants. In dark mode: the table header `border-b` and text are unthemed, the `pre` output block (`bg-black text-green-300`) is hard-coded and may clash with the dark layout, pagination links use `border rounded` with no dark treatment, and the page title has no dark text class.

### Solution

Apply `dark:` variants throughout `Operations/Index.jsx` to match the style used in other pages (`Databases/Index.jsx`, `Accounts/Index.jsx`):

- Table header: add `dark:text-gray-300 dark:border-gray-700`.
- Table rows: `dark:bg-gray-850 dark:border-gray-700 dark:text-gray-200`.
- Pre block: already `bg-black text-green-300` — acceptable but add `rounded` (already present). No change needed.
- Pagination links: add `dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-700`.
- Page container `p-6`: add `dark:text-gray-100`.
- Page title: add `dark:text-gray-100`.
- Badge map already uses Tailwind utility classes — no change.

Also wrap the page in a container matching other pages: `<div className="max-w-7xl px-4 my-8">` replacing the bare `<div className="p-6">`.

### Real files

| File | Change |
|------|--------|
| `resources/js/Pages/Operations/Index.jsx` | Add `dark:` variants throughout; wrap in `max-w-7xl px-4 my-8` container |

### Testing

- **Vitest:** `resources/js/Pages/Operations/Index.test.jsx` (new) — render with sample operations; assert table headers and rows render; assert pagination prev/next links render with correct state (opacity for disabled).

---

## D7 — Databases page: engine-agnostic icon in sidebar

### Problem

`SidebarNavi.jsx` uses `TbBrandMysql` (line 7, `from 'react-icons/tb'`) for the "Databases" nav link. The databases feature now supports MySQL, MariaDB, and PostgreSQL. The MySQL-branded icon misleads users who use Postgres-only installs.

### Solution

Replace `TbBrandMysql` on the Databases nav entry with `TbDatabase` (already used as the page header icon in `resources/js/Pages/Databases/Index.jsx`, line 3). `TbDatabase` is a generic database cylinder — brand-neutral.

Note: `TbBrandMysql` may still be used elsewhere (e.g. `MySQLLive.jsx` / the new `DbEnginesLive.jsx` for MySQL-specific engine cards) — only the sidebar nav entry changes.

### Real files

| File | Change |
|------|--------|
| `resources/js/Layouts/Partials/SidebarNavi.jsx` | Import `TbDatabase` from `'react-icons/tb'` (keep existing `TbBrandMysql` import if still used elsewhere in the file — in the current code it is only used for Databases; remove if unused after this change); replace `<TbBrandMysql>` on the Databases `<li>` with `<TbDatabase>` |

### Testing

No automated test needed for an icon swap. The `SidebarNavi.test.jsx` added in D5 can assert `TbDatabase` is rendered for Databases link if desired.

---

## D10 — File manager: double-click hint

### Problem

`Filemanager.jsx` navigates into directories and opens files on double-click (`onDoubleClick` handler, lines 97–115). New users do not know they must double-click — there is no visible affordance.

### Solution

Add a dismissable hint banner at the top of the file listing. Options (choose one for implementation):

**Option A (first-visit banner):** Show a one-line info banner: "Double-click a folder to enter it, or a file to edit it." Dismiss by clicking an X. Persist dismissal in `localStorage` key `laranode_fm_hint_dismissed`. Once dismissed, never shown again.

**Option B (persistent static text):** Add a small `<p>` below the toolbar with `ℹ️ Double-click to enter folders or open files.` — no dismiss needed, always visible.

Recommendation: Option A (dismissable). It's non-intrusive and matches UX patterns used for first-time guidance.

### Real files

| File | Change |
|------|--------|
| `resources/js/Pages/Filemanager/Filemanager.jsx` | Add `hintDismissed` state (seeded from `localStorage('laranode_fm_hint_dismissed')`); render hint banner below the toolbar (`mb-5` div) when not dismissed; clicking X sets state + writes `localStorage` |

### Testing

- **Vitest:** `resources/js/Pages/Filemanager/Filemanager.test.jsx` (new) — mock fetch to return empty file list; render; assert hint text is present; click dismiss X; assert hint no longer in DOM; assert `localStorage.setItem` called.

---

## D11 — PHP manager: detect installed versions and block reinstall

### Problem

`InstallPHPForm.jsx` always shows all versions in `availableVersions = ['8.4', '8.3', '8.2', '8.1', '8.0', '7.4']` as installable, regardless of whether they are already installed. `PHPManagerController::list()` calls `laranode-scripts/bin/laranode-php-list.sh`, which uses `dpkg -l | grep -E 'php[0-9]+\.[0-9]+-fpm'` to find installed versions and returns their `status` and `enabled` state. The bug: the returned list only contains installed versions — but `InstallPHPForm` renders a static list and never cross-references what's installed. Result: PHP 8.4 (or any already-installed version) is offered as installable.

### Root cause

`PHP/Index.jsx` fetches `/php/list` into `phpVersions` state (the installed list), but `InstallPHPForm.jsx` is a separate component that does not receive `phpVersions` as a prop and maintains its own static `availableVersions` list.

### Solution

Pass the installed versions into `InstallPHPForm`. In `PHP/Index.jsx`, pass `phpVersions` as a prop to `<InstallPHPForm installedVersions={phpVersions} />`. In `InstallPHPForm.jsx`, filter `availableVersions` to exclude any version that appears in `installedVersions`. Installed versions either:
- Are hidden from the select, OR
- Are shown as disabled options with a label "(installed)" — disabled options are better UX because they confirm what's there.

Recommendation: show disabled with "(installed)" label.

**Server-side guard (mandatory):** `PHPManagerController::install()` already validates `version` with regex `/^\d+\.\d+$/`. Add a check: before calling the install script, call `laranode-php-list.sh` (or inline a `dpkg -l` check) to see if the version is already installed. If it is, return a 409 (Conflict) JSON response. This prevents re-installation even if the frontend is bypassed.

The server-side check must not use `shell_exec` inline — it already calls `shell_exec("sudo bash {$scriptPath}")` in `list()`. The same pattern is acceptable for the guard check since `list()` is already doing it.

### Real files

| File | Change |
|------|--------|
| `app/Http/Controllers/PHPManagerController.php` | In `install()`: after validating `version`, call `$this->list()` style check (extract a private `isVersionInstalled(string $version): bool` that runs `laranode-php-list.sh` and parses the JSON); if installed, return `response()->json(['success' => false, 'message' => "PHP {$version} is already installed"], 409)` |
| `resources/js/Pages/PHP/Partials/InstallPHPForm.jsx` | Accept `installedVersions` prop (array of `{ version, status, enabled }`); in the select, mark versions that appear in `installedVersions` as `disabled` with label `PHP X.Y (installed)` |
| `resources/js/Pages/PHP/Index.jsx` | Pass `installedVersions={phpVersions}` to `<InstallPHPForm>` |

### Testing

- **Pest (feature):** `tests/Feature/PHP/PHPManagerInstallTest.php` (new) — mock `shell_exec` / `Process::fake` for the list and install scripts; POST to `php.install` with an already-installed version (version present in mocked list output) → assert 409 with correct message; POST with a genuinely new version → assert 200.
- **Vitest:** `resources/js/Pages/PHP/Partials/InstallPHPForm.test.jsx` (new) — render with `installedVersions=[{ version: '8.4', status: 'active', enabled: true }]`; assert the `<option>` for `8.4` has `disabled` attribute and label includes "(installed)".

---

## D13 — Accounts page: hide impersonate on own row + server-side guard

### Problem

`Accounts/Index.jsx` renders the `<Link href={route('accounts.impersonate', { user: account.id })}>` impersonate action for every row, including the currently authenticated admin's own account. `AccountsController::impersonate()` calls `auth()->user()->impersonate($user)` without checking whether `$user->id === auth()->id()`. Impersonating yourself is a no-op at best and confusing at worst.

### Solution

**Server-side guard (hard block):** In `AccountsController::impersonate()`, add:

```php
if ($user->id === auth()->id()) {
    abort(403, 'Cannot impersonate yourself.');
}
```

This must be the first check, before calling `impersonate()`.

**Frontend:** In `Accounts/Index.jsx`, read the authenticated user's ID from `auth.user.id` (already available via `usePage().props.auth`). Conditionally render the impersonate link only when `account.id !== auth.user.id`.

```jsx
{account.id !== auth.user.id && (
    <Link href={route('accounts.impersonate', { user: account.id })} ...>
        <RiLoginCircleLine className='w-4 h-4' />
    </Link>
)}
```

### Real files

| File | Change |
|------|--------|
| `app/Http/Controllers/AccountsController.php` | Add `if ($user->id === auth()->id()) abort(403, ...)` at the top of `impersonate()` |
| `resources/js/Pages/Accounts/Index.jsx` | Wrap impersonate link in `account.id !== auth.user.id &&` conditional |

### Testing

- **Pest (feature):** `tests/Feature/Accounts/ImpersonateSelfTest.php` (new) — authenticate as admin; GET `/accounts/impersonate/{own_id}` → assert 403; GET `/accounts/impersonate/{other_user_id}` → assert redirect (succeeds); non-admin → assert 403 (already blocked by `AdminMiddleware`).
- **Vitest:** `resources/js/Pages/Accounts/Index.test.jsx` (new, or extend existing) — render with `accounts = [{ id: 1, ... }, { id: 2, ... }]` and `auth.user.id = 1`; assert impersonate link rendered for account id 2; assert impersonate link NOT rendered for account id 1.

---

## D14 — File manager: breadcrumb path navigation

### Problem

`Filemanager.jsx` shows the current path as static text (`Path: {path}`, line 287) only when `goBack` is set. There is no clickable breadcrumb to navigate up multiple levels at once. Users must double-click "Back" repeatedly to traverse back to a parent directory.

### Solution

Replace the static `Path: {path}` text with a clickable breadcrumb. Split `path` on `/`, build an array of `{ label, fullPath }` segments, render them as clickable spans separated by `/`. Clicking any segment calls `cdIntoPath(segment.fullPath)`.

Example: path `/home/alice_ln/domains/example.com/public_html` → renders:
`/ home / alice_ln / domains / example.com / public_html`

Each segment (including the root `/`) is a `<button>` calling `cdIntoPath`. The current/last segment is non-clickable (or styled differently as the active segment).

The root segment always navigates to `/`. The user's homedir is the Flysystem sandbox root, so the user can only see paths within their home anyway.

### Real files

| File | Change |
|------|--------|
| `resources/js/Pages/Filemanager/Filemanager.jsx` | Replace the `<div>Path: {path}</div>` block (lines 286–288) with a `<Breadcrumb path={path} onNavigate={cdIntoPath} />` inline component or extract to `Components/Breadcrumb.jsx` (new, preferred for testability) |

Optionally: `resources/js/Pages/Filemanager/Components/Breadcrumb.jsx` (new).

### Testing

- **Vitest:** `resources/js/Pages/Filemanager/Components/Breadcrumb.test.jsx` (new) — render with `path="/home/alice_ln/domains"` and a mock `onNavigate`; assert 4 clickable segments (`/`, `home`, `alice_ln`, `domains`); click `home` → assert `onNavigate` called with `/home`; click root `/` → assert called with `/`.

---

## Data model / migrations

None. All items are frontend UX changes, CSS fixes, or minor PHP controller/service logic — no new tables.

---

## Privileged scripts + sudoers

None. No new bash scripts. No sudoers additions. D11's detection reuses the existing `laranode-php-list.sh` call pattern already in `PHPManagerController::list()`.

---

## OperationJob / EngineManager / dashboard stack usage

| Item | Stack interaction |
|------|------------------|
| D1 | `SystemStatsEvent` constructor (calls `SystemStatsService::getAllStats()`) + `Cache` facade + `DashboardController::admin()` |
| D2 | `TopStatsEvent` / `private-topstats` channel — `topStats` already in `TopProcesses.jsx` state; no new backend |
| D3 | `EngineManager::available()` called from `SystemStatsService`; `SystemStatsEvent` broadcast unchanged |
| D4–D7, D10, D14 | Pure frontend; no backend stack involvement |
| D11 | `PHPManagerController` + `laranode-php-list.sh` (existing); no `OperationJob` (check is fast) |
| D13 | `AccountsController::impersonate()` guard; lab404 impersonate package |

---

## Security

- **D13:** The server-side `abort(403)` guard in `AccountsController::impersonate()` is the mandatory hard block. The frontend conditional is a UX-only improvement; the server must never rely on it alone.
- **D11:** The server-side "already installed" check prevents duplicate `apt-get install` calls which could mask a compromised frontend bypassing the UI guard. The response is 409 (not 403) to signal a logical conflict, not an authorization failure.
- **D3:** `EngineManager::available()` calls `systemctl is-active` (read-only, no shell injection risk). The `SystemStatsService` constructs engine names from the configuration array (`config/laranode.php`), not from user input.
- **D5 (sidebar collapse):** State is stored in `localStorage` (client-side), not server-side. No authentication token or sensitive data is persisted.
- **D10, D14 (file manager hints/breadcrumb):** Breadcrumb segments are built from the `path` state already returned by the Flysystem-sandboxed `FilemanagerController`. Calling `cdIntoPath` with a segment value is equivalent to the user navigating there manually; the backend sandboxing remains unchanged.

---

## Testing strategy

### Backend Pest

| Test file | Items | What it covers |
|-----------|-------|----------------|
| `tests/Feature/Dashboard/DashboardStatsTest.php` (new) | D1, D3 | Cache write on SystemStatsEvent dispatch; `admin()` passes `initialStats` prop; `getDbEnginesStatus()` returns correct map for mock engine set |
| `tests/Feature/PHP/PHPManagerInstallTest.php` (new) | D11 | 409 on reinstall attempt; 200 on genuine new install (mocked list) |
| `tests/Feature/Accounts/ImpersonateSelfTest.php` (new) | D13 | 403 when admin impersonates own ID; success for another user |

### Frontend Vitest

| Test file | Items | What it covers |
|-----------|-------|----------------|
| `resources/js/Pages/Dashboard/Admin/AdminDashboard.test.jsx` (new) | D1 | Renders stat widgets from `initialStats` prop without spinner on first render |
| `resources/js/Pages/Dashboard/Admin/Components/TopProcesses.test.jsx` (new) | D2 | Chart canvas present; "Other" aggregation; no chart when empty |
| `resources/js/Pages/Dashboard/Admin/Components/DbEnginesLive.test.jsx` (new) | D3 | Correct label per engine key; renders one card per engine |
| `resources/js/Layouts/Partials/SidebarNavi.test.jsx` (new) | D5, D7 | Collapse toggle writes localStorage; TbDatabase on Databases link |
| `resources/js/Pages/Operations/Index.test.jsx` (new) | D6 | Table renders; badges present; pagination links render |
| `resources/js/Pages/PHP/Partials/InstallPHPForm.test.jsx` (new) | D11 | Installed version option is disabled with "(installed)" label |
| `resources/js/Pages/Accounts/Index.test.jsx` (new) | D13 | Impersonate link absent for own row; present for other rows |
| `resources/js/Pages/Filemanager/Filemanager.test.jsx` (new) | D10 | Hint banner renders; dismiss writes localStorage; dismissed hint hidden |
| `resources/js/Pages/Filemanager/Components/Breadcrumb.test.jsx` (new) | D14 | Segments render; click calls onNavigate with correct path |

### System integration

No new system-touching code in this batch. D11's `isVersionInstalled()` check calls the same `laranode-php-list.sh` already exercised by existing PHP manager system tests (if any). No new `LARANODE_SYSTEM_TESTS=1` tests are required.

---

## Back-compat

- **D3:** Removes the `mysql` key from `SystemStatsService::getAllStats()` and replaces it with `dbEngines`. Both consumers (`AdminDashboard.jsx` and any code reading `dashboard_stats_last_known` from Cache) are updated in the same branch. No external API contract. If a MySQL-only install deploys this, `dbEngines` will contain `{ mysql: { ... } }` — identical information, different structure.
- **D1:** `initialStats` is a new optional Inertia prop. If the cache is cold (e.g. first boot, cache flushed), `Cache::get('dashboard_stats_last_known', [])` returns `[]`, seeding `useState([])` — identical to the current behaviour.
- **D5:** `AuthenticatedLayout.jsx` gains a new prop (`isCollapsed`/`setIsCollapsed`) passed to `SidebarNavi`. All existing callers of `AuthenticatedLayout` pass only `header` and `children` — this is an internal prop between the layout and its sidebar child, not a public API. No page component is affected.
- **D11:** `InstallPHPForm` gains a new optional `installedVersions` prop. If not passed (old call sites), the prop is `undefined`; filtering against `undefined` is safely handled with `installedVersions ?? []`.
- All other items (D2, D4, D6, D7, D10, D13, D14) are additive or pure style changes with no back-compat risk.

---

## File inventory

```
# Backend
app/Events/SystemStatsEvent.php                                         (modify: cache stats on dispatch — D1)
app/Http/Controllers/DashboardController.php                            (modify: pass initialStats prop — D1)
app/Services/Dashboard/SystemStatsService.php                           (modify: getDbEnginesStatus(), refactor — D3)
app/Http/Controllers/PHPManagerController.php                           (modify: isVersionInstalled guard — D11)
app/Http/Controllers/AccountsController.php                             (modify: self-impersonate abort — D13)

# Frontend — Dashboard
resources/js/Pages/Dashboard/Admin/AdminDashboard.jsx                   (modify: seed liveStats from initialStats prop — D1; swap DbEnginesLive — D3)
resources/js/Pages/Dashboard/Admin/Components/TopProcesses.jsx          (modify: add Doughnut chart — D2)
resources/js/Pages/Dashboard/Admin/Components/TopProcessesChart.jsx     (new, optional extract — D2)
resources/js/Pages/Dashboard/Admin/Components/MySQLLive.jsx             (replaced by DbEnginesLive — D3)
resources/js/Pages/Dashboard/Admin/Components/DbEnginesLive.jsx         (new — D3)

# Frontend — Layout & Sidebar
resources/js/Layouts/AuthenticatedLayout.jsx                            (modify: centered layout — D4; pass collapse state — D5)
resources/js/Layouts/Partials/SidebarNavi.jsx                           (modify: collapse+persist — D5; engine-agnostic DB icon — D7)

# Frontend — Operations
resources/js/Pages/Operations/Index.jsx                                 (modify: dark-mode styles — D6)

# Frontend — PHP Manager
resources/js/Pages/PHP/Index.jsx                                        (modify: pass installedVersions to InstallPHPForm — D11)
resources/js/Pages/PHP/Partials/InstallPHPForm.jsx                      (modify: disable installed options — D11)

# Frontend — Accounts
resources/js/Pages/Accounts/Index.jsx                                   (modify: hide impersonate for own row — D13)

# Frontend — File Manager
resources/js/Pages/Filemanager/Filemanager.jsx                          (modify: hint banner — D10; breadcrumb — D14)
resources/js/Pages/Filemanager/Components/Breadcrumb.jsx                (new — D14)

# Tests — Pest
tests/Feature/Dashboard/DashboardStatsTest.php                          (new — D1, D3)
tests/Feature/PHP/PHPManagerInstallTest.php                             (new — D11)
tests/Feature/Accounts/ImpersonateSelfTest.php                          (new — D13)

# Tests — Vitest
resources/js/Pages/Dashboard/Admin/AdminDashboard.test.jsx              (new — D1)
resources/js/Pages/Dashboard/Admin/Components/TopProcesses.test.jsx     (new — D2)
resources/js/Pages/Dashboard/Admin/Components/DbEnginesLive.test.jsx    (new — D3)
resources/js/Layouts/Partials/SidebarNavi.test.jsx                      (new — D5, D7)
resources/js/Pages/Operations/Index.test.jsx                            (new — D6)
resources/js/Pages/PHP/Partials/InstallPHPForm.test.jsx                 (new — D11)
resources/js/Pages/Accounts/Index.test.jsx                              (new — D13)
resources/js/Pages/Filemanager/Filemanager.test.jsx                     (new — D10)
resources/js/Pages/Filemanager/Components/Breadcrumb.test.jsx           (new — D14)
```

---

## Open questions

1. **D3 — Key rename backward compatibility:** Renaming `getAllStats()` from `mysql` to `dbEngines` breaks any integration test or documentation that references `liveStats.mysql`. Are there any external consumers (e.g. a monitoring script, test that checks the broadcast payload shape) that need a migration period or aliased key?

2. **D2 — Chart metric toggle:** Should the donut chart switch metric (CPU vs Memory) in sync with the existing CPU/Memory sort toggle in `TopProcesses.jsx`, or should it have an independent toggle? The current proposal ties it to `sortBy` for simplicity.

3. **D5 — Collapse state scope:** `localStorage` means collapse is per-browser, not per-user (not stored on the server). If a user switches browsers or devices, they start expanded. Is server-side persistence (user `preferences` column on `users` table) worth the complexity for v1?

4. **D11 — Available versions list:** The static `availableVersions` array in `InstallPHPForm.jsx` (`['8.4', '8.3', '8.2', '8.1', '8.0', '7.4']`) is hardcoded. Should it be driven from a config or API endpoint so new PHP versions (8.5, etc.) can be added without a frontend deploy?

5. **D13 — Impersonate admin-to-admin:** The current code only guards self-impersonation. Should admin-impersonating-another-admin also be blocked? (`lab404` allows it by default.) Flag for a future security decision if not addressed now.

6. **D10 — Hint persistence scope:** The `localStorage` dismiss is per-browser. If a user logs in from a different browser the hint reappears. This is probably acceptable for a first-time hint; confirm no objection.

7. **D4 — Centering approach:** `max-w-screen-xl` on the `AuthenticatedLayout` children wrapper may clip some pages differently on very large displays. If a page intentionally uses full width (e.g., a future logs viewer), the layout-level cap should be removable per-page. Confirm whether a layout-level cap is preferred over per-page centering.
