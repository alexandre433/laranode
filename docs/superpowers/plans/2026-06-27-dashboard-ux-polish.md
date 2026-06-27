# dashboard-ux-polish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A targeted sweep of 10 UX/polish/bug-fix items across the admin dashboard, sidebar, file manager, PHP manager, accounts, databases, and operations pages. No new domain models or migrations. No new bash scripts or sudoers entries.

**Architecture:** No `OperationJob`, no new privileged scripts. Backend items are thin controller/service patches (D1, D3, D11, D13). Frontend items are pure React JSX + Tailwind changes. The one security-critical item (D13) requires a hard server-side abort guard before the frontend conditional.

**Key constraints:**
- `SystemStatsService::getAllStats()` is the single source of truth for live dashboard stats; the `mysql` key is replaced by `dbEngines` in this branch — all consumers (`AdminDashboard.jsx`, `dashboard_stats_last_known` cache) are updated atomically.
- `PHPManagerController::install()` uses `shell_exec("sudo bash {$scriptPath}")` pattern (existing); the new `isVersionInstalled()` guard must follow the same pattern (call `laranode-php-list.sh`), not inline a raw `dpkg` call.
- `AccountsController::impersonate()` currently has no self-impersonation guard; the hard `abort(403)` is added before any call to `impersonate()`.
- `SidebarNavi.jsx` currently uses `isSidebarOpen` state (mobile-only toggle) and `TbBrandMysql` for the Databases link.
- `AuthenticatedLayout.jsx` children wrapper is `<div className="ml-3 pr-3">` — D4 adds `mx-auto` (and optionally `max-w-screen-xl`) to this div only.
- `Filemanager.jsx` path block is the `{goBack && goBack != "" && ...}` section at lines 279–289; the `path` state is the backend-sandboxed string returned by `FilemanagerController`.
- Vitest + RTL for all frontend components; Pest 3 + RefreshDatabase for all backend changes; no new `LARANODE_SYSTEM_TESTS=1` tests required (D11 reuses the existing `laranode-php-list.sh` — no new shell script, only a new call site).

**Branch:** `feature/dashboard-ux-polish` (off `development`).
**Suite:** `./vendor/bin/pest` (backend) + `npm run test` (frontend Vitest).

---

> **Execution order:** Tasks 1–3 are independent and may run in parallel. Tasks 4–7 are independent and may run in parallel after their respective backend tasks are done. Task 8 is the final gate and depends on all prior tasks.

---

### Task 1 — D1: Dashboard stats blank-on-refresh (TDD)

**Items covered:** D1

**Files:**
- Modify: `app/Events/SystemStatsEvent.php`
- Modify: `app/Http/Controllers/DashboardController.php`
- Modify: `resources/js/Pages/Dashboard/Admin/AdminDashboard.jsx`
- Create: `tests/Feature/Dashboard/DashboardStatsTest.php`
- Create: `resources/js/Pages/Dashboard/Admin/AdminDashboard.test.jsx`

**Scope — backend:**

`app/Events/SystemStatsEvent.php` — in the constructor, after `$this->stats = (new SystemStatsService)->getAllStats();`, add:
```php
Cache::put('dashboard_stats_last_known', $this->stats, 90);
```
Import `Illuminate\Support\Facades\Cache`. No other changes to this file.

`app/Http/Controllers/DashboardController.php` — in `admin()`, before the `Inertia::render` call, read:
```php
$initialStats = Cache::get('dashboard_stats_last_known', []);
```
Pass it to the render call: `Inertia::render('Dashboard/Admin/AdminDashboard', compact('initialStats'))`.
The existing `use Illuminate\Support\Facades\Cache;` is already present in this file — verify before adding.

**Scope — frontend:**

`resources/js/Pages/Dashboard/Admin/AdminDashboard.jsx` — the `Dashboard` component currently accepts no props. Add `{ initialStats }` to the function signature. Change `useState([])` to `useState(initialStats ?? [])`. The `useEffect`/whisper/`setLiveStats` logic is unchanged — live updates continue to overwrite the seed value.

**Acceptance criteria:**
- Cache key `dashboard_stats_last_known` is set (TTL=90s) every time `SystemStatsEvent` is constructed.
- `GET /dashboard/admin` (as admin) Inertia response contains `initialStats` prop; when cache is cold (`[]`), the prop is an empty array.
- `AdminDashboard.jsx` rendered with a non-empty `initialStats` prop shows CPU stat text without a spinner on first render (before any Echo event fires).
- `AdminDashboard.jsx` rendered with `initialStats = []` shows the same empty/spinner state as before this change.

**Test layer — Pest (TDD):**
- `tests/Feature/Dashboard/DashboardStatsTest.php` (new)
  - Test: dispatching `new SystemStatsEvent()` (with `Process::fake()`) writes `dashboard_stats_last_known` to Cache.
  - Test: `GET /dashboard/admin` as admin returns Inertia component `Dashboard/Admin/AdminDashboard` with `initialStats` key in props (use `$response->assertInertia(fn($page) => $page->component('Dashboard/Admin/AdminDashboard')->has('initialStats'))`).
  - Write failing tests first, then implement.

**Test layer — Vitest (TDD):**
- `resources/js/Pages/Dashboard/Admin/AdminDashboard.test.jsx` (new)
  - Mock `window.Echo` (private channel that does nothing).
  - Render `<AdminDashboard initialStats={{ cpuStats: { usage: '42', ... }, ... }} />`.
  - Assert CPU usage text appears immediately without waiting for an event.
  - Render `<AdminDashboard initialStats={[]} />` — assert no crash.
  - Write failing tests first.

- [ ] Write failing Pest tests (`DashboardStatsTest.php`)
- [ ] Write failing Vitest tests (`AdminDashboard.test.jsx`)
- [ ] Implement `SystemStatsEvent.php` cache write
- [ ] Implement `DashboardController::admin()` `initialStats` prop
- [ ] Implement `AdminDashboard.jsx` prop seeding
- [ ] Verify Pest tests pass
- [ ] Verify Vitest tests pass
- [ ] Run Pint on new PHP files
- [ ] Commit: `feat(dashboard): seed liveStats from server-side initialStats prop (D1)`

---

### Task 2 — D2: Top-processes doughnut chart (TDD)

**Items covered:** D2

**Files:**
- Modify: `resources/js/Pages/Dashboard/Admin/Components/TopProcesses.jsx`
- Create (optional, preferred for testability): `resources/js/Pages/Dashboard/Admin/Components/TopProcessesChart.jsx`
- Create: `resources/js/Pages/Dashboard/Admin/Components/TopProcesses.test.jsx`

**Scope:**

Extract `TopProcessesChart` to `TopProcessesChart.jsx` (new file) for testability. It accepts `topStats` (array) and `sortBy` (`'cpu'|'memory'`) props.

Chart logic:
- Import `Doughnut` from `react-chartjs-2` and required Chart.js registrations.
- Aggregate `parseFloat(item.cpu)` (or `parseFloat(item.mem)`) by `item.mainCmd`. Items under 1% each are merged into a single "Other" slice.
- Tooltip: `process.mainCmd — X% CPU / Y% MEM`.
- Render nothing (return null) when `topStats.length === 0`.
- `sortBy` prop switches which metric is visualised — when `sortBy === 'memory'`, aggregate `mem`; otherwise aggregate `cpu`.

In `TopProcesses.jsx`, import `TopProcessesChart` and render `<TopProcessesChart topStats={topStats} sortBy={sortBy} />` above the existing `<div className="relative overflow-x-auto ...">` table wrapper. The existing `topStats` state and `sortBy` state are passed as props — no duplication.

No backend change. No migration.

**Acceptance criteria:**
- Chart canvas element renders when `topStats` has entries.
- "Other" slice is present when the input contains more than ~10 distinct commands each under 1%.
- No canvas element renders when `topStats` is empty.
- Switching `sortBy` from `cpu` to `memory` changes which metric drives the chart data.

**Test layer — Vitest (TDD):**
- `resources/js/Pages/Dashboard/Admin/Components/TopProcesses.test.jsx` (new)
  - Import and render `TopProcessesChart` directly.
  - Render with sample `topStats` (10+ entries with mixed small %CPU) and `sortBy="cpu"`; assert `<canvas>` element is in the DOM.
  - Render with `topStats` containing many small processes; assert "Other" appears in the chart data (inspect the chart instance or spy on chart data construction).
  - Render with `topStats=[]`; assert no `<canvas>` element.
  - Write failing tests first.

- [ ] Write failing Vitest tests (`TopProcesses.test.jsx`)
- [ ] Create `TopProcessesChart.jsx`
- [ ] Integrate into `TopProcesses.jsx`
- [ ] Verify Vitest tests pass
- [ ] Commit: `feat(dashboard): top-processes doughnut chart above table (D2)`

---

### Task 3 — D3: Surface all DB engines in dashboard widget (TDD)

**Items covered:** D3

**Files:**
- Modify: `app/Services/Dashboard/SystemStatsService.php`
- Create: `resources/js/Pages/Dashboard/Admin/Components/DbEnginesLive.jsx`
- Modify: `resources/js/Pages/Dashboard/Admin/AdminDashboard.jsx`
- Delete/replace: `resources/js/Pages/Dashboard/Admin/Components/MySQLLive.jsx` (replaced by `DbEnginesLive.jsx`)
- Create: `tests/Feature/Dashboard/DbEnginesStatusTest.php`
- Create: `resources/js/Pages/Dashboard/Admin/Components/DbEnginesLive.test.jsx`

**Scope — backend:**

`app/Services/Dashboard/SystemStatsService.php`:
1. Extract a private `getServiceStatus(string $service): array` method that contains the existing `getMysqlStatus()` pipe+parse logic (the `systemctl status` → awk → explode pattern). The method takes a service name and returns `['pid', 'memory', 'cpuTime', 'uptime']` array.
2. Add `getDbEnginesStatus(): array`. This method calls `(new \App\Databases\EngineManager)->available()` to get `$activeEngines` (a map of `engineKey => serviceName`). For each entry it calls `$this->getServiceStatus($serviceName)` and builds the result: `['mysql' => [...], 'postgres' => [...]]` etc. Returns an empty array when no engines are active.
3. In `getAllStats()`: replace `'mysql' => $this->getMysqlStatus()` with `'dbEngines' => $this->getDbEnginesStatus()`.
4. `getMysqlStatus()` can remain as a private method (or be removed if `getServiceStatus()` covers it fully) — prefer removal to avoid dead code.

No change to `SystemStatsEvent.php` (it already calls `getAllStats()`).

**Scope — frontend:**

`resources/js/Pages/Dashboard/Admin/Components/DbEnginesLive.jsx` (new):
- Accepts `dbEngines` prop — a map of `{ engineKey: { pid, memory, cpuTime, uptime } }`.
- Renders one card per engine key.
- Icon logic: `engineKey === 'mysql' || engineKey === 'mariadb'` → `TbBrandMysql`; `engineKey === 'postgres'` → `BiLogoPostgresql` (from `react-icons/bi`) or `TbDatabase` as fallback; unknown keys → `TbDatabase` (from `react-icons/tb`, already used in `Databases/Index.jsx`).
- Label: capitalise the engine key (`MySQL`, `MariaDB`, `Postgres`).
- Returns null when `dbEngines` is falsy or empty.

`resources/js/Pages/Dashboard/Admin/AdminDashboard.jsx`:
- Replace `import MySQLLive from './Components/MySQLLive'` with `import DbEnginesLive from './Components/DbEnginesLive'`.
- Replace `<MySQLLive mysqlStats={liveStats.mysql} />` with `<DbEnginesLive dbEngines={liveStats.dbEngines} />`.

`resources/js/Pages/Dashboard/Admin/Components/MySQLLive.jsx`:
- Delete (or leave as a dead file with a redirect comment — deletion preferred). If deleted, verify no other file imports it before removing.

**Acceptance criteria:**
- `SystemStatsService::getDbEnginesStatus()` returns `{ mysql: { memory, cpuTime, uptime, pid } }` when only MySQL is active.
- `getDbEnginesStatus()` returns both `mysql` and `postgres` keys when both engines are active.
- `getAllStats()` no longer has a `mysql` key; it has a `dbEngines` key.
- `DbEnginesLive` renders a "MySQL" labelled card when `dbEngines = { mysql: { memory: '64M', ... } }`.
- `DbEnginesLive` renders a "Postgres" labelled card when `dbEngines = { postgres: { ... } }`.
- `DbEnginesLive` renders nothing when `dbEngines` is `undefined` or `{}`.

**Test layer — Pest (TDD):**
- `tests/Feature/Dashboard/DbEnginesStatusTest.php` (new)
  - Use `Process::fake()` to stub `systemctl is-active mysql` → `active`, others → `inactive`.
  - Assert `(new SystemStatsService)->getDbEnginesStatus()` returns array with `mysql` key and expected shape keys (`pid`, `memory`, `cpuTime`, `uptime`).
  - Use `Process::fake()` with both `mysql` and `postgresql` active.
  - Assert both `mysql` and `postgres` keys present.
  - Assert `getAllStats()` has `dbEngines` key and no `mysql` key at the top level.
  - Write failing tests first.

**Test layer — Vitest (TDD):**
- `resources/js/Pages/Dashboard/Admin/Components/DbEnginesLive.test.jsx` (new)
  - Render with `dbEngines = { mysql: { memory: '64M', cpuTime: '0h1m', uptime: '2 days', pid: '123' } }`.
  - Assert "MySQL" text appears; memory value appears.
  - Render with `dbEngines = { postgres: { memory: '128M', cpuTime: '0h2m', uptime: '1 day', pid: '456' } }`.
  - Assert "Postgres" text appears.
  - Render with `dbEngines = {}` — assert nothing rendered (component returns null).
  - Write failing tests first.

- [ ] Write failing Pest tests (`DbEnginesStatusTest.php`)
- [ ] Write failing Vitest tests (`DbEnginesLive.test.jsx`)
- [ ] Implement `getServiceStatus()` + `getDbEnginesStatus()` in `SystemStatsService.php`
- [ ] Update `getAllStats()` — swap `mysql` for `dbEngines`
- [ ] Create `DbEnginesLive.jsx`
- [ ] Update `AdminDashboard.jsx` (swap import + usage)
- [ ] Delete `MySQLLive.jsx` (verify no other importers first)
- [ ] Verify Pest tests pass
- [ ] Verify Vitest tests pass
- [ ] Run Pint on PHP files
- [ ] Commit: `feat(dashboard): multi-engine DB widget (DbEnginesLive), replace MySQLLive (D3)`

---

### Task 4 — D4: Center main panel content

**Items covered:** D4

**Files:**
- Modify: `resources/js/Layouts/AuthenticatedLayout.jsx`

**Scope:**

`resources/js/Layouts/AuthenticatedLayout.jsx` — line 37, the children wrapper:
```jsx
// before:
<div className="ml-3 pr-3">
// after:
<div className="ml-3 pr-3 mx-auto max-w-screen-xl">
```

This single class addition is the entire change. Pages that already have `max-w-7xl` on their own inner wrapper (e.g. `AdminDashboard.jsx`, `Filemanager.jsx`, `Accounts/Index.jsx`) will have a consistent outer cap. `max-w-screen-xl` (1280px) is wider than `max-w-7xl` (1280px = same) — effectively a no-op constraint for most pages, but ensures consistent centering via `mx-auto` on wide viewports.

No backend change. No test required (pure CSS layout — visual regression is the verification).

**Acceptance criteria:**
- The children wrapper div in `AuthenticatedLayout.jsx` has class `mx-auto` (and `max-w-screen-xl`) added to it.
- `npm run build` succeeds with no errors.
- Visual check: on a wide viewport the main content is horizontally centred relative to the visible area to the right of the sidebar.

- [ ] Modify `AuthenticatedLayout.jsx` (add `mx-auto max-w-screen-xl`)
- [ ] Verify `npm run build` passes
- [ ] Commit: `feat(layout): center main content with mx-auto (D4)`

---

### Task 5 — D5 + D7: Collapsible sidebar with persisted state + engine-agnostic DB icon (TDD)

**Items covered:** D5, D7

**Files:**
- Modify: `resources/js/Layouts/AuthenticatedLayout.jsx`
- Modify: `resources/js/Layouts/Partials/SidebarNavi.jsx`
- Create: `resources/js/Layouts/Partials/SidebarNavi.test.jsx`

**Scope — D7 (simpler, do first):**

`resources/js/Layouts/Partials/SidebarNavi.jsx`:
- Line 7: `import { TbBrandMysql } from "react-icons/tb"` — add `TbDatabase` to this import: `import { TbBrandMysql, TbDatabase } from "react-icons/tb"`.
- Databases `<li>` (lines 113–123): replace `<TbBrandMysql className="ml-3 w-5 h-5" />` with `<TbDatabase className="ml-3 w-5 h-5" />`.
- Remove `TbBrandMysql` import entirely if it is no longer used in this file after D7 (it is only used for the Databases link — confirm by search before removing).

**Scope — D5:**

Lift collapse state into `AuthenticatedLayout.jsx`:
- Add state: `const [isCollapsed, setIsCollapsed] = useState(() => localStorage.getItem('laranode_sidebar_collapsed') === 'true')`.
- Pass as props to `SidebarNavi`: `<SidebarNavi isCollapsed={isCollapsed} setIsCollapsed={setIsCollapsed} />`.
- Switch the content area margin: change `<div className="h-full ml-14 mt-14 mb-10 md:ml-64">` to `<div className={`h-full ${isCollapsed ? 'ml-14' : 'ml-64'} mt-14 mb-10`}>` (removes the responsive `md:ml-64` pair; a single dynamic value replaces it).

`resources/js/Layouts/Partials/SidebarNavi.jsx`:
- Accept `{ isCollapsed, setIsCollapsed }` props (destructured from props, not from a hook).
- Remove the existing `const [isSidebarOpen, setIsSidebarOpen] = useState(false)` internal state.
- Sidebar width class: replace `${isSidebarOpen ? 'w-64' : 'w-14'} md:w-64` with `${isCollapsed ? 'w-14' : 'w-64'}`.
- Toggle button: the existing mobile-only `<button onClick={() => setIsSidebarOpen(!isSidebarOpen)} className="... block md:hidden">` becomes an all-breakpoints toggle. Update `onClick` to:
  ```jsx
  () => {
      const next = !isCollapsed;
      setIsCollapsed(next);
      localStorage.setItem('laranode_sidebar_collapsed', String(next));
  }
  ```
  Remove the `md:hidden` class so it shows on all breakpoints.
- When `isCollapsed` is true, item label `<span>` elements should be hidden. The existing `truncate` approach on `<span className="ml-2 text-sm tracking-wide truncate">` does not hide on collapse — add a conditional class: `${isCollapsed ? 'hidden' : ''}` or simply `hidden md:block`-style based on `isCollapsed`. Prefer the conditional: `className={`ml-2 text-sm tracking-wide truncate ${isCollapsed ? 'hidden' : ''}`}`. Apply to all nav `<span>` labels.

**Acceptance criteria:**
- On mount with `localStorage` empty, sidebar starts expanded (`w-64`).
- Clicking the toggle button collapses sidebar to `w-14` and calls `localStorage.setItem('laranode_sidebar_collapsed', 'true')`.
- Clicking again expands and sets `'false'`.
- On mount with `localStorage.getItem('laranode_sidebar_collapsed') === 'true'`, sidebar starts collapsed.
- Databases nav link renders `TbDatabase` icon, not `TbBrandMysql`.
- When collapsed, nav label `<span>` elements are not visible.

**Test layer — Vitest (TDD):**
- `resources/js/Layouts/Partials/SidebarNavi.test.jsx` (new)
  - Mock `window.localStorage` (or use `vitest`'s `jsdom` localStorage).
  - Mock `window.route` (Ziggy helper) to return `'/'` for any route call.
  - Render `<SidebarNavi isCollapsed={false} setIsCollapsed={mockFn} />`.
  - Assert "Databases" link renders with an element that has the `TbDatabase` aria/role (or assert by test ID if added, or simply assert `TbBrandMysql` is absent and `TbDatabase` present).
  - Render `<SidebarNavi isCollapsed={true} setIsCollapsed={mockFn} />`.
  - Assert nav label spans are not visible (hidden class present or `getByText('Websites')` not in document).
  - Click the toggle button.
  - Assert `setIsCollapsed` mock was called with `true`.
  - Assert `localStorage.setItem` was called with `'laranode_sidebar_collapsed'` and `'true'`.
  - Write failing tests first.

- [ ] Write failing Vitest tests (`SidebarNavi.test.jsx`)
- [ ] Implement D7 icon swap in `SidebarNavi.jsx` (TbDatabase)
- [ ] Implement D5 collapse state in `AuthenticatedLayout.jsx`
- [ ] Implement D5 collapse props + toggle + localStorage in `SidebarNavi.jsx`
- [ ] Verify Vitest tests pass
- [ ] Commit: `feat(sidebar): collapsible with localStorage persist + engine-agnostic DB icon (D5, D7)`

---

### Task 6 — D6: Operations page dark-mode styles (TDD)

**Items covered:** D6

**Files:**
- Modify: `resources/js/Pages/Operations/Index.jsx`
- Create: `resources/js/Pages/Operations/Index.test.jsx`

**Scope:**

`resources/js/Pages/Operations/Index.jsx` — the current file has `<div className="p-6">` as the page container and no `dark:` variants. Apply the following changes:

1. Page container: change `<div className="p-6">` to `<div className="max-w-7xl px-4 my-8 dark:text-gray-100">`.
2. Page title `<h1>`: add `dark:text-gray-100` (merge with existing `text-xl font-semibold mb-4`).
3. Table header row `<tr className="text-left border-b">`: add `dark:text-gray-300 dark:border-gray-700`.
4. Table body rows `<tr ... className="border-b align-top cursor-pointer">`: add `dark:border-gray-700 dark:text-gray-200`.
5. Pagination `<Link>` and `<span>` elements with `className="px-3 py-1 border rounded"`: add `dark:border-gray-600 dark:text-gray-300` on links, and `dark:border-gray-700 dark:text-gray-500` on disabled spans.
6. The `<pre>` block (`bg-black text-green-300`) is intentionally terminal-themed and left unchanged.
7. The `badge` map colour utilities are Tailwind colour classes — they render correctly in both modes without `dark:` overrides.

No backend change. No migration.

**Acceptance criteria:**
- Operations page container is wrapped in `max-w-7xl px-4 my-8` (matches pattern in other pages like `Accounts/Index.jsx`).
- Table header and rows have `dark:` variants for text and border colours.
- Pagination links have `dark:` border and text variants.
- `npm run build` succeeds.

**Test layer — Vitest (TDD):**
- `resources/js/Pages/Operations/Index.test.jsx` (new)
  - Render with sample `operations` prop: `{ data: [{ id:1, created_at:'...', user:{username:'admin'}, type:'ssl.enable', target:'example.com', status:'succeeded', output:'ok' }], prev_page_url: null, next_page_url: '/operations?page=2', current_page: 1, last_page: 2 }`.
  - Assert table headers render ("When", "Actor", "Type", "Target", "Status").
  - Assert the operation row renders with the `succeeded` badge.
  - Assert "Previous" pagination is a `<span>` with `opacity-50` class (disabled).
  - Assert "Next" pagination is a `<Link>` (renders as `<a>`) with `href` present.
  - Write failing tests first.

- [ ] Write failing Vitest tests (`Operations/Index.test.jsx`)
- [ ] Implement dark-mode classes in `Operations/Index.jsx`
- [ ] Implement container restructure (`max-w-7xl px-4 my-8`)
- [ ] Verify Vitest tests pass
- [ ] Commit: `feat(operations): dark-mode styles + max-w-7xl container (D6)`

---

### Task 7 — D10 + D14: File manager hint banner + breadcrumb navigation (TDD)

**Items covered:** D10, D14

**Files:**
- Modify: `resources/js/Pages/Filemanager/Filemanager.jsx`
- Create: `resources/js/Pages/Filemanager/Components/Breadcrumb.jsx`
- Create: `resources/js/Pages/Filemanager/Filemanager.test.jsx`
- Create: `resources/js/Pages/Filemanager/Components/Breadcrumb.test.jsx`

**Scope — D14 (breadcrumb — do first, it replaces the path text block):**

Create `resources/js/Pages/Filemanager/Components/Breadcrumb.jsx`:
- Props: `path` (string) and `onNavigate` (function).
- Logic: split `path` on `/`, filter empty segments, build `[{ label: '/', fullPath: '/' }, { label: 'home', fullPath: '/home' }, ...]` array.
- Render segments separated by `/` text dividers.
- Each segment except the last is a `<button>` that calls `onNavigate(segment.fullPath)` on click.
- Last segment is rendered as `<span>` (non-clickable, styled as active/current).
- Root segment label is `/`.

`resources/js/Pages/Filemanager/Filemanager.jsx`:
- Import `Breadcrumb` from `./Components/Breadcrumb`.
- Replace the existing path display block (lines 279–289, the `{goBack && goBack != "" && ...}` section):
  - Keep the "Back" button `<div>` (double-click `cdIntoPath(goBack)`) — this is a separate element.
  - Replace the `<div className="bg-white dark:bg-gray-850 py-3 px-6 dark:text-gray-300 text-gray-900 flex items-center space-x-2">Path: {path}</div>` with `<Breadcrumb path={path} onNavigate={cdIntoPath} />`.
- The `{goBack && ...}` condition wrapping remains — breadcrumb only shows when `goBack` is set (i.e. not at root).

**Scope — D10 (hint banner):**

`resources/js/Pages/Filemanager/Filemanager.jsx`:
- Add state: `const [hintDismissed, setHintDismissed] = useState(() => localStorage.getItem('laranode_fm_hint_dismissed') === 'true')`.
- Below the toolbar `<div className="mb-5 flex items-center space-x-2 ...">` (the action buttons row, lines 197–277), add the hint banner conditionally:
  ```jsx
  {!hintDismissed && (
      <div className="mb-3 flex items-center justify-between bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded px-4 py-2 text-sm text-blue-700 dark:text-blue-300">
          <span>Double-click a folder to enter it, or a file to edit it.</span>
          <button
              onClick={() => { setHintDismissed(true); localStorage.setItem('laranode_fm_hint_dismissed', 'true'); }}
              className="ml-4 text-blue-500 hover:text-blue-700 font-bold"
              aria-label="Dismiss hint"
          >
              &times;
          </button>
      </div>
  )}
  ```

**Acceptance criteria — D10:**
- Hint banner text "Double-click a folder to enter it, or a file to edit it." is present on first render.
- Clicking the dismiss button removes the hint from the DOM.
- After dismissal, `localStorage.setItem` is called with key `laranode_fm_hint_dismissed` and value `'true'`.
- Re-rendering with `localStorage` pre-set to `'true'` does not show the hint.

**Acceptance criteria — D14:**
- `Breadcrumb` rendered with `path="/home/alice_ln/domains"` renders 4 clickable/labelled segments: `/`, `home`, `alice_ln`, `domains`.
- Clicking the `home` segment calls `onNavigate('/home')`.
- Clicking the root `/` segment calls `onNavigate('/')`.
- The last segment (`domains`) is not a button (it is the active segment).
- In `Filemanager.jsx`, the static "Path: {path}" text is gone; `<Breadcrumb path={path} onNavigate={cdIntoPath} />` is present in the `{goBack && ...}` block.

**Test layer — Vitest (TDD):**
- `resources/js/Pages/Filemanager/Components/Breadcrumb.test.jsx` (new)
  - Render `<Breadcrumb path="/home/alice_ln/domains" onNavigate={mockFn} />`.
  - Assert 3 clickable buttons (root `/`, `home`, `alice_ln`) and 1 non-button span (`domains`).
  - Click the `home` button; assert `mockFn` called with `'/home'`.
  - Click the root button; assert `mockFn` called with `'/'`.
  - Write failing tests first.
- `resources/js/Pages/Filemanager/Filemanager.test.jsx` (new)
  - Mock `fetch` to return `{ files: [], goBack: false }` (at root, no breadcrumb).
  - Render `<Filemanager />` (needs to mock window.Echo is not needed since Filemanager does not use Echo).
  - Assert hint text "Double-click a folder to enter it" is present.
  - Click the dismiss button (`aria-label="Dismiss hint"`).
  - Assert hint no longer in DOM.
  - Assert `localStorage.setItem` called with `'laranode_fm_hint_dismissed'`, `'true'`.
  - Write failing tests first.

- [ ] Write failing Vitest tests (`Breadcrumb.test.jsx` and `Filemanager.test.jsx`)
- [ ] Create `Breadcrumb.jsx`
- [ ] Implement breadcrumb integration in `Filemanager.jsx` (replace path text block)
- [ ] Implement hint banner state + UI in `Filemanager.jsx`
- [ ] Verify Vitest tests pass
- [ ] Commit: `feat(filemanager): double-click hint banner (D10) + breadcrumb navigation (D14)`

---

### Task 8 — D11: PHP manager — block reinstall with server-side guard (TDD)

**Items covered:** D11

**Files:**
- Modify: `app/Http/Controllers/PHPManagerController.php`
- Modify: `resources/js/Pages/PHP/Partials/InstallPHPForm.jsx`
- Modify: `resources/js/Pages/PHP/Index.jsx`
- Create: `tests/Feature/PHP/PHPManagerInstallTest.php`
- Create: `resources/js/Pages/PHP/Partials/InstallPHPForm.test.jsx`

**Scope — backend:**

`app/Http/Controllers/PHPManagerController.php`:
- Add a private method `isVersionInstalled(string $version): bool`:
  ```php
  private function isVersionInstalled(string $version): bool
  {
      $scriptPath = base_path('laranode-scripts/bin/laranode-php-list.sh');
      $output = shell_exec("sudo bash {$scriptPath}");
      $installed = json_decode($output, true) ?? [];
      return collect($installed)->contains('version', $version);
  }
  ```
  This reuses the identical `shell_exec` pattern already in `list()`.
- In `install()`, after `$version = $request->input('version');` and before calling the install script, add:
  ```php
  if ($this->isVersionInstalled($version)) {
      return response()->json([
          'success' => false,
          'message' => "PHP {$version} is already installed",
      ], 409);
  }
  ```

**Scope — frontend:**

`resources/js/Pages/PHP/Index.jsx`:
- `<InstallPHPForm />` on line 110 becomes `<InstallPHPForm installedVersions={phpVersions} />`.
- No other change to this file.

`resources/js/Pages/PHP/Partials/InstallPHPForm.jsx`:
- Change signature from `export default function InstallPHPForm()` to `export default function InstallPHPForm({ installedVersions = [] })`.
- In the `availableVersions.map()` render:
  ```jsx
  {availableVersions.map((v) => {
      const isInstalled = installedVersions.some((p) => p.version === v);
      return (
          <option key={v} value={v} disabled={isInstalled}>
              PHP {v}{isInstalled ? ' (installed)' : ''}
          </option>
      );
  })}
  ```
- The `handleInstall` guard `if (!version)` is unchanged. No other logic changes.

**Acceptance criteria:**
- `POST /php/install` with a version present in the mocked `laranode-php-list.sh` output → 409 JSON `{ success: false, message: "PHP 8.4 is already installed" }`.
- `POST /php/install` with a version not in the installed list → proceeds to script call (200 on success).
- `POST /php/install` with invalid `version` format → 422 (existing validation still fires first).
- `InstallPHPForm` with `installedVersions=[{ version: '8.4', ... }]` renders the `8.4` option with `disabled` attribute and label "PHP 8.4 (installed)".
- `InstallPHPForm` with `installedVersions=[]` (default) renders all options enabled.

**Test layer — Pest (TDD):**
- `tests/Feature/PHP/PHPManagerInstallTest.php` (new)
  - Authenticate as admin.
  - `Process::fake()` is not directly applicable here since `PHPManagerController::install()` uses `shell_exec` — use `Mockery` or `PHPUnit` mocking to stub `shell_exec`, or use `Process::fake()` for the install script call but note `shell_exec` is separate.
  - Alternative approach: extract `isVersionInstalled()` to be overridable in tests. Use partial mocking of `PHPManagerController` via `$this->instance(PHPManagerController::class, ...)` in Pest, or spy the private method if possible.
  - Simpler: test the controller directly by passing a mock response from `laranode-php-list.sh`. Since `shell_exec` is a global function and hard to mock, test via the route with `Process::fake()` for the list call if refactored to `Process::run()`, OR use a test-only approach where `isVersionInstalled()` is extracted to a mockable service.
  - **Recommended:** refactor `isVersionInstalled()` to use `Process::run(['sudo', 'bash', $scriptPath])` instead of `shell_exec` (consistent with the project's `Process` facade pattern used elsewhere). Then `Process::fake()` works cleanly.
  - Tests: `POST /php/install` with mocked list showing `8.4` installed → assert 409; `POST /php/install` with mocked list showing `8.4` not installed → assert Process was called for the install script (200).
  - Write failing tests first.

**Test layer — Vitest (TDD):**
- `resources/js/Pages/PHP/Partials/InstallPHPForm.test.jsx` (new)
  - Render `<InstallPHPForm installedVersions={[{ version: '8.4', status: 'active', enabled: true }]} />` (opens modal first or renders select directly).
  - Assert the option element for value `8.4` has `disabled` attribute.
  - Assert the option text includes `(installed)`.
  - Assert options for `8.3`, `8.2` etc. do not have `disabled`.
  - Render with `installedVersions=[]`; assert all options are enabled.
  - Write failing tests first.

**Note on `Process` facade refactor:** `isVersionInstalled()` should call `Process::run(['sudo', 'bash', $scriptPath])` (not `shell_exec`) so it is testable with `Process::fake()`. This also applies the project convention (see `CreateCronJobService`, `SystemStatsService`, all service classes use `Process::run`). The `list()` method's existing `shell_exec` is a pre-existing inconsistency — do not fix it as part of this task (surgical change only).

- [ ] Write failing Pest tests (`PHPManagerInstallTest.php`)
- [ ] Write failing Vitest tests (`InstallPHPForm.test.jsx`)
- [ ] Add `isVersionInstalled(string $version): bool` to `PHPManagerController` (use `Process::run` not `shell_exec`)
- [ ] Add `isVersionInstalled` guard to `install()` method (409 response)
- [ ] Update `InstallPHPForm.jsx` to accept `installedVersions` prop + disable installed options
- [ ] Update `PHP/Index.jsx` to pass `installedVersions={phpVersions}` to `<InstallPHPForm>`
- [ ] Verify Pest tests pass
- [ ] Verify Vitest tests pass
- [ ] Run Pint on PHP files
- [ ] Commit: `feat(php): block reinstall via 409 guard + disable installed options in form (D11)`

---

### Task 9 — D13: Block self-impersonation (TDD, security)

**Items covered:** D13

**Files:**
- Modify: `app/Http/Controllers/AccountsController.php`
- Modify: `resources/js/Pages/Accounts/Index.jsx`
- Create: `tests/Feature/Accounts/ImpersonateSelfTest.php`
- Create (or extend): `resources/js/Pages/Accounts/Index.test.jsx`

**Scope — backend (hard block, mandatory):**

`app/Http/Controllers/AccountsController.php` — in `impersonate(User $user)`, add as the very first statement (before calling `impersonate()`):
```php
if ($user->id === auth()->id()) {
    abort(403, 'Cannot impersonate yourself.');
}
```
No other changes to this method. The `leaveImpersonation()` method is unchanged.

**Scope — frontend (UX-only, not a security control):**

`resources/js/Pages/Accounts/Index.jsx`:
- The component already receives `accounts` prop but does not currently receive `auth`. Read auth from `usePage().props`:
  - Add `import { usePage } from '@inertiajs/react'` if not already present (check: currently only `Link` and `Head` are imported from `@inertiajs/react`, and `router` is imported separately — `usePage` is not imported).
  - Add `const { auth } = usePage().props;` inside the `Accounts` component body.
- Wrap the impersonate link (lines 101–109) in a conditional:
  ```jsx
  {account.id !== auth.user.id && (
      <Link href={route('accounts.impersonate', { user: account.id })}
          data-tooltip-id={`tooltip-impersonate-${account.id}`}
          data-tooltip-content="Impersonate User"
          data-tooltip-place="top"
      >
          <RiLoginCircleLine className='w-4 h-4' />
      </Link>
  )}
  ```
  The `<Tooltip>` element remains outside the conditional.

**Acceptance criteria (security):**
- `GET /accounts/impersonate/{own_id}` (admin impersonating themselves) → 403.
- `GET /accounts/impersonate/{other_user_id}` (admin impersonating another user) → redirect (succeeds).
- Non-admin attempting impersonation → 403 (existing `AdminMiddleware` already blocks this; assert it still holds).
- **The frontend conditional is UX-only. The 403 test is the authoritative security assertion.**

**Test layer — Pest (TDD, security test):**
- `tests/Feature/Accounts/ImpersonateSelfTest.php` (new)
  - Test: admin `actingAs($admin)` → `get(route('accounts.impersonate', $admin))` → assert 403.
  - Test: admin `actingAs($admin)` → `get(route('accounts.impersonate', $otherUser))` → assert redirect (status 302, not 403).
  - Test: non-admin `actingAs($user)` → `get(route('accounts.impersonate', $admin))` → assert 403 (middleware guard, already covered conceptually but assert explicitly).
  - All three tests must pass before implementation is considered done.
  - Write failing tests first (the self-impersonate test must fail without the guard).

**Test layer — Vitest (TDD):**
- `resources/js/Pages/Accounts/Index.test.jsx` (new)
  - Mock `usePage` to return `{ props: { auth: { user: { id: 1 } }, flash: {} } }`.
  - Render `<Accounts accounts={[{ id: 1, name: 'Admin', username: 'admin', email: 'a@b.com', role: 'admin', ssh_access: false, domain_limit: null, database_limit: null }, { id: 2, name: 'User', username: 'user2', email: 'u@b.com', role: 'user', ssh_access: false, domain_limit: null, database_limit: null }]} />`.
  - Assert the impersonate link for `account.id === 2` (other user) is present.
  - Assert the impersonate link for `account.id === 1` (own row, auth.user.id === 1) is NOT present.
  - Write failing tests first.

- [ ] Write failing Pest tests (`ImpersonateSelfTest.php`)
- [ ] Write failing Vitest tests (`Accounts/Index.test.jsx`)
- [ ] Add `abort(403)` guard to `AccountsController::impersonate()`
- [ ] Add `usePage` import + `auth` destructure to `Accounts/Index.jsx`
- [ ] Wrap impersonate link in `account.id !== auth.user.id` conditional
- [ ] Verify Pest tests pass (403 on self, 302 on other)
- [ ] Verify Vitest tests pass
- [ ] Run Pint on PHP files
- [ ] Commit: `fix(accounts): block self-impersonation with 403 guard + hide link for own row (D13)`

---

### Task 10 — Final verification gate

**Depends on:** All tasks 1–9.

**Steps:**
- [ ] Run full Pest suite: `./vendor/bin/pest` — zero failures.
- [ ] Run full Vitest suite: `npm run test` — zero failures.
- [ ] Run Pint on all modified PHP files: `./vendor/bin/pint` — zero formatting issues.
- [ ] Run production asset build: `npm run build` — exits 0, no import errors.
- [ ] Manual visual check (local-dev container or browser): admin dashboard shows stats on hard refresh (D1); top-processes chart visible with real data (D2); DB engine widget shows correct engine name (D3); content is centred on wide viewport (D4); sidebar collapses and label text hides, persists across reload (D5); Databases link shows cylinder icon not MySQL brand icon (D7); Operations page is readable in dark mode (D6); File manager hint banner appears and dismisses (D10); breadcrumb segments are clickable (D14); PHP install modal shows installed versions as disabled (D11); impersonate link absent on own row (D13).
- [ ] Assert no regression: `GET /admin/operations` → 200; `GET /php` → 200; `GET /accounts` → 200; `GET /filemanager` → 200; `GET /dashboard` → 200 (admin); `GET /dashboard` → 200 (user).

---

## Back-compat notes

| Change | Risk | Mitigation |
|--------|------|------------|
| D3: `mysql` key removed from `getAllStats()`, replaced by `dbEngines` | Cache key `dashboard_stats_last_known` may hold stale shape after deploy | TTL is 90s; stale shape resolves itself within 90 seconds. `DbEnginesLive` renders nothing if `dbEngines` is undefined — no crash. |
| D1: new `initialStats` Inertia prop | If cache cold, prop is `[]` — identical to prior behaviour | None needed. |
| D5: `SidebarNavi` now requires `isCollapsed`/`setIsCollapsed` props | These are internal layout props; no external callers pass them | Props have no default, so TypeErrors possible if `SidebarNavi` is rendered without `AuthenticatedLayout`. Assert no standalone `SidebarNavi` usage in other layout files. |
| D11: `isVersionInstalled` uses `Process::run` (not `shell_exec`) | New call to `laranode-php-list.sh` on every install attempt | Script is fast (dpkg query); acceptable overhead. |
| D13: `abort(403)` is first check in `impersonate()` | Admin who accidentally clicks own row now gets a 403 page | Frontend conditional hides the link — 403 should only fire if bypassed. |

---

## File inventory

```
# Backend
app/Events/SystemStatsEvent.php                                        (modify: Cache::put on dispatch — D1)
app/Http/Controllers/DashboardController.php                           (modify: pass initialStats prop — D1)
app/Services/Dashboard/SystemStatsService.php                          (modify: getServiceStatus + getDbEnginesStatus, replace mysql key — D3)
app/Http/Controllers/PHPManagerController.php                          (modify: isVersionInstalled guard via Process::run — D11)
app/Http/Controllers/AccountsController.php                            (modify: abort(403) self-impersonate guard — D13)

# Frontend — Dashboard
resources/js/Pages/Dashboard/Admin/AdminDashboard.jsx                  (modify: initialStats prop seed — D1; swap DbEnginesLive — D3)
resources/js/Pages/Dashboard/Admin/Components/TopProcesses.jsx         (modify: add TopProcessesChart above table — D2)
resources/js/Pages/Dashboard/Admin/Components/TopProcessesChart.jsx    (new — D2)
resources/js/Pages/Dashboard/Admin/Components/MySQLLive.jsx            (delete — replaced by DbEnginesLive — D3)
resources/js/Pages/Dashboard/Admin/Components/DbEnginesLive.jsx        (new — D3)

# Frontend — Layout & Sidebar
resources/js/Layouts/AuthenticatedLayout.jsx                           (modify: mx-auto max-w-screen-xl on children wrapper — D4; isCollapsed state + prop to SidebarNavi — D5)
resources/js/Layouts/Partials/SidebarNavi.jsx                          (modify: accept isCollapsed props, localStorage toggle — D5; TbDatabase for Databases link — D7)

# Frontend — Operations
resources/js/Pages/Operations/Index.jsx                                (modify: dark: variants, max-w-7xl container — D6)

# Frontend — PHP Manager
resources/js/Pages/PHP/Index.jsx                                       (modify: pass installedVersions={phpVersions} to InstallPHPForm — D11)
resources/js/Pages/PHP/Partials/InstallPHPForm.jsx                     (modify: accept installedVersions prop, disable installed options — D11)

# Frontend — Accounts
resources/js/Pages/Accounts/Index.jsx                                  (modify: usePage auth import, conditional impersonate link — D13)

# Frontend — File Manager
resources/js/Pages/Filemanager/Filemanager.jsx                         (modify: hint banner — D10; breadcrumb integration — D14)
resources/js/Pages/Filemanager/Components/Breadcrumb.jsx               (new — D14)

# Tests — Pest
tests/Feature/Dashboard/DashboardStatsTest.php                         (new — D1)
tests/Feature/Dashboard/DbEnginesStatusTest.php                        (new — D3)
tests/Feature/PHP/PHPManagerInstallTest.php                            (new — D11)
tests/Feature/Accounts/ImpersonateSelfTest.php                         (new — D13, security)

# Tests — Vitest
resources/js/Pages/Dashboard/Admin/AdminDashboard.test.jsx             (new — D1)
resources/js/Pages/Dashboard/Admin/Components/TopProcesses.test.jsx    (new — D2)
resources/js/Pages/Dashboard/Admin/Components/DbEnginesLive.test.jsx   (new — D3)
resources/js/Layouts/Partials/SidebarNavi.test.jsx                     (new — D5, D7)
resources/js/Pages/Operations/Index.test.jsx                           (new — D6)
resources/js/Pages/PHP/Partials/InstallPHPForm.test.jsx                (new — D11)
resources/js/Pages/Accounts/Index.test.jsx                             (new — D13)
resources/js/Pages/Filemanager/Filemanager.test.jsx                    (new — D10)
resources/js/Pages/Filemanager/Components/Breadcrumb.test.jsx          (new — D14)
```

---

## Security checklist

| Item | Server-side guard | Frontend guard | Test |
|------|-------------------|----------------|------|
| D13 self-impersonate | `abort(403)` in `AccountsController::impersonate()` (hard block) | Conditional render (UX only) | `ImpersonateSelfTest.php` asserts 403 |
| D11 reinstall | 409 JSON response before script call | `disabled` option (UX only) | `PHPManagerInstallTest.php` asserts 409 |
| D3 engine detection | Config-driven `EngineManager::available()`; no user input | N/A | `DbEnginesStatusTest.php` |
| D5 sidebar state | `localStorage` client-side only; no auth data stored | N/A | Vitest localStorage assertion |
| D10/D14 file manager | Flysystem sandbox unchanged; `cdIntoPath` is same as manual nav | N/A | Existing backend sandboxing |
