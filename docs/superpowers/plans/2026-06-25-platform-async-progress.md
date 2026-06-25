# Platform Async + Live-Progress + Audit Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Laranode a reusable async primitive — run long operations on the queue, stream their live output to the triggering user over Reverb, record them in an `operations` audit table, and add the scheduler hook — proven by converting SSL generation to async.

**Architecture:** Controller creates an `operations` row and dispatches a queued `OperationJob` subclass. The job runs the work via an `$emit($line)` callback; each line is appended to the row and broadcast (`OperationUpdated`) on the user-scoped private channel `operations.{userId}`. React's `useOperation` hook subscribes via Echo and renders a live log. Reuses the already-running database queue worker + Reverb server.

**Tech Stack:** Laravel 12, Pest 3, Laravel Reverb (Echo/pusher-js), Inertia + React (JSX), `Process` facade with real-time output callback, MySQL (prod) / SQLite `:memory:` (tests).

## Global Constraints

- **Broadcast channel name is exactly `operations.{userId}`**; event `broadcastAs` name is exactly `OperationUpdated`; payload keys exactly `operationId`, `kind` (`status`|`line`), `status`, `line`, `exitCode`.
- **`operations.status` values are exactly:** `queued`, `running`, `succeeded`, `failed`.
- **Channel auth:** a user may listen to their own channel; admins may listen to any (`(int)$user->id === (int)$userId || $user->isAdmin()`).
- **Follow existing conventions:** `scopeMine()` (see `app/Models/Database.php:49`), `AdminMiddleware` gating, Inertia shared `auth.user` (see `HandleInertiaRequests`), private channels via `resources/js/echo.js` (`window.Echo`).
- **`GenerateWebsiteSslAction::execute` signature change must be backward compatible:** add `?callable $onOutput = null` as a 3rd param; default `null` preserves current behavior.
- **Tests run with `QUEUE_CONNECTION=sync`** (jobs run inline) — already the case in `phpunit.xml`. Use `Event::fake()` / `Process::fake()` to assert without real broadcast/exec.
- **Branch:** `feature/platform-async-progress` (off `development`). Each task commits here.
- **Run the suite in the `local-dev` container** for the authoritative result: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test'`. On Windows, `make`/`docker compose` run from PowerShell (Git Bash strips the env docker needs); plain `docker exec laranode-lab …` works from any shell.

---

> **Execution order:** run **Task A** then **Task B** (front-end test infrastructure, project-wide — there is no JS test harness today) BEFORE the numbered tasks. Then Tasks 1–7 in order. Task 7 (React) depends on Task A's Vitest harness.

### Task A: Front-end unit/component test harness (Vitest + RTL + jsdom)

**Files:**
- Create: `vitest.config.js`
- Create: `resources/js/tests/setup.js`
- Create: `resources/js/tests/sanity.test.jsx`
- Modify: `package.json` (add `test` + `test:watch` scripts; devDeps added by install)

**Interfaces:**
- Produces: a working `npm run test` (Vitest, jsdom, RTL, `@` → `resources/js` alias, jest-dom matchers). Consumed by Task 7's component tests.

- [ ] **Step 1: Install dev deps (in the container — node_modules is the container volume)**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && npm i -D vitest @testing-library/react @testing-library/jest-dom @testing-library/user-event jsdom'`
Expected: installs succeed; `package.json` devDependencies gains these.

- [ ] **Step 2: Create `vitest.config.js`** (separate from `vite.config.js` — must NOT load the laravel plugin, which needs a running Laravel server)

```js
import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
import path from 'node:path';

export default defineConfig({
    plugins: [react()],
    resolve: { alias: { '@': path.resolve(__dirname, 'resources/js') } },
    test: {
        environment: 'jsdom',
        globals: true,
        setupFiles: ['resources/js/tests/setup.js'],
        include: ['resources/js/**/*.{test,spec}.{js,jsx}'],
    },
});
```

- [ ] **Step 3: Create `resources/js/tests/setup.js`**

```js
import '@testing-library/jest-dom';
```

- [ ] **Step 4: Add scripts to `package.json`** (keep existing `build`/`dev`)

In the `"scripts"` block add:
```json
        "test": "vitest run",
        "test:watch": "vitest"
```

- [ ] **Step 5: Write a sanity test `resources/js/tests/sanity.test.jsx`**

```jsx
import { render, screen } from '@testing-library/react';
import { test, expect } from 'vitest';

test('vitest + React Testing Library render works', () => {
    render(<div>hello laranode</div>);
    expect(screen.getByText('hello laranode')).toBeInTheDocument();
});
```

- [ ] **Step 6: Run it; verify it passes**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && npm run test'`
Expected: 1 passing test.

- [ ] **Step 7: Commit**

```bash
git add vitest.config.js resources/js/tests/setup.js resources/js/tests/sanity.test.jsx package.json
git commit -m "test(frontend): add Vitest + React Testing Library harness"
```

---

### Task B: E2E test harness (Playwright smoke)

**Files:**
- Create: `playwright.config.js`
- Create: `tests/e2e/smoke.spec.js`
- Modify: `package.json` (add `test:e2e` script; dep added by install)

**Interfaces:**
- Produces: `npm run test:e2e` running headless chromium against the running container (`http://localhost`) with the seeded admin. Reusable by later sub-projects.

> Heavier layer: runs the browser **inside the container** (so it hits the container's own Apache on :80; node_modules is the container volume). A one-time browser+deps install is required. Keep specs to robust smokes — do NOT E2E the live SSL-streaming flow (needs queue+Reverb+Pebble; flaky).

- [ ] **Step 1: Install Playwright + chromium (in the container, as root)**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && npm i -D @playwright/test && apt-get update -qq && npx playwright install --with-deps chromium'`
Expected: package installed; chromium + its apt libs installed (one-time, ~150MB). If `apt-get` is slow/large, that's expected.

- [ ] **Step 2: Create `playwright.config.js`**

```js
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
    testDir: './tests/e2e',
    timeout: 30000,
    use: { baseURL: process.env.APP_URL || 'http://localhost', headless: true },
    projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
```

- [ ] **Step 3: Add the script to `package.json`**

In `"scripts"` add:
```json
        "test:e2e": "playwright test"
```

- [ ] **Step 4: Write the smoke spec `tests/e2e/smoke.spec.js`**

```js
import { test, expect } from '@playwright/test';

test('admin can log in and reach the dashboard', async ({ page }) => {
    await page.goto('/login');
    await page.fill('input#email', 'admin@laranode.test');
    await page.fill('input#password', 'password');
    await page.click('button[type="submit"]');
    await expect(page).toHaveURL(/dashboard/);
});

test('the websites page renders for an authenticated admin', async ({ page }) => {
    await page.goto('/login');
    await page.fill('input#email', 'admin@laranode.test');
    await page.fill('input#password', 'password');
    await page.click('button[type="submit"]');
    await page.waitForURL(/dashboard/);
    await page.goto('/websites');
    await expect(page.locator('body')).toContainText(/website/i);
});
```
(Match the real input selectors in `resources/js/Pages/Auth/Login.jsx` — Breeze uses `id="email"` / `id="password"`. If they differ, adjust the selectors.)

- [ ] **Step 5: Run it against the running container; verify**

First confirm the app is up + assets built + admin seeded: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && systemctl is-active apache2 && curl -s -o /dev/null -w "%{http_code}\n" http://localhost/login'` → apache `active`, login `200`.
Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && npm run test:e2e'`
Expected: 2 passing E2E tests. If a selector mismatches, fix per the real Login page and re-run.

- [ ] **Step 6: Commit**

```bash
git add playwright.config.js tests/e2e/smoke.spec.js package.json
git commit -m "test(e2e): add Playwright harness + login/dashboard/websites smokes"
```

---

### Task 1: `operations` table + `Operation` model

**Files:**
- Create: `database/migrations/2026_06_25_000001_create_operations_table.php`
- Create: `app/Models/Operation.php`
- Test: `tests/Feature/Operations/OperationModelTest.php`

**Interfaces:**
- Produces: `App\Models\Operation` with columns `id, user_id, type, target, status, output, exit_code, started_at, finished_at, timestamps`; `belongsTo(User)`; `scopeMine(Builder): Builder`; `MassPrunable` via `prunable()`. Consumed by every later task.

- [ ] **Step 1: Write the failing test**

```php
<?php // tests/Feature/Operations/OperationModelTest.php

use App\Models\Operation;
use App\Models\User;

test('an operation belongs to a user and defaults to queued', function () {
    $user = User::factory()->create();
    $op = Operation::create([
        'user_id' => $user->id,
        'type' => 'demo.run',
        'target' => 'example.test',
    ]);

    expect($op->status)->toBe('queued')
        ->and($op->user->is($user))->toBeTrue();
});

test('scopeMine restricts non-admins to their own operations', function () {
    $admin = User::factory()->isAdmin()->create();
    $user = User::factory()->isNotAdmin()->create();
    $other = User::factory()->isNotAdmin()->create();

    Operation::create(['user_id' => $user->id, 'type' => 't']);
    Operation::create(['user_id' => $other->id, 'type' => 't']);

    $this->actingAs($user);
    expect(Operation::mine()->count())->toBe(1);

    $this->actingAs($admin);
    expect(Operation::mine()->count())->toBe(2);
});

test('prunable targets operations older than 30 days', function () {
    $old = Operation::create(['user_id' => User::factory()->create()->id, 'type' => 't']);
    $old->forceFill(['created_at' => now()->subDays(31)])->save();
    Operation::create(['user_id' => User::factory()->create()->id, 'type' => 't']);

    expect((new Operation)->prunable()->count())->toBe(1);
});
```

- [ ] **Step 2: Run it; verify it fails**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=OperationModelTest'`
Expected: FAIL — `Class "App\Models\Operation" not found`.

- [ ] **Step 3: Write the migration**

```php
<?php // database/migrations/2026_06_25_000001_create_operations_table.php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::create('operations', function (Blueprint $table) {
            $table->id();
            $table->foreignId('user_id')->constrained()->onDelete('cascade');
            $table->string('type');                 // e.g. ssl.generate
            $table->string('target')->nullable();   // human label, e.g. the domain
            $table->string('status')->default('queued'); // queued|running|succeeded|failed
            $table->longText('output')->nullable();
            $table->integer('exit_code')->nullable();
            $table->timestamp('started_at')->nullable();
            $table->timestamp('finished_at')->nullable();
            $table->timestamps();

            $table->index(['user_id', 'status']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('operations');
    }
};
```

- [ ] **Step 4: Write the model**

```php
<?php // app/Models/Operation.php

namespace App\Models;

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\MassPrunable;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class Operation extends Model
{
    use MassPrunable;

    protected $fillable = [
        'user_id', 'type', 'target', 'status', 'output', 'exit_code', 'started_at', 'finished_at',
    ];

    protected $casts = [
        'started_at' => 'datetime',
        'finished_at' => 'datetime',
        'exit_code' => 'integer',
    ];

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function scopeMine(Builder $query): Builder
    {
        $user = auth()->user();
        return $query->when($user && ! $user->isAdmin(), fn ($q) => $q->where('user_id', $user->id));
    }

    public function prunable(): Builder
    {
        return static::where('created_at', '<', now()->subDays(30));
    }
}
```

- [ ] **Step 5: Run the test; verify it passes**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=OperationModelTest'`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add database/migrations/2026_06_25_000001_create_operations_table.php app/Models/Operation.php tests/Feature/Operations/OperationModelTest.php
git commit -m "feat(operations): operations table + model (scopeMine, prunable)"
```

---

### Task 2: `OperationUpdated` event + channel auth + lifecycle methods

**Files:**
- Create: `app/Events/OperationUpdated.php`
- Modify: `routes/channels.php` (append the `operations.{userId}` channel)
- Modify: `app/Models/Operation.php` (add `markRunning`/`appendOutput`/`markFinished`)
- Test: `tests/Feature/Operations/OperationLifecycleTest.php`

**Interfaces:**
- Consumes: `App\Models\Operation` (Task 1).
- Produces: `App\Events\OperationUpdated(Operation $operation, string $kind, ?string $line = null)` (ShouldBroadcast, `broadcastAs()='OperationUpdated'`, channel `operations.{user_id}`). `Operation::markRunning(): void`, `Operation::appendOutput(string $line): void`, `Operation::markFinished(int $exitCode): void` — each persists and dispatches `OperationUpdated`.

- [ ] **Step 1: Write the failing test**

```php
<?php // tests/Feature/Operations/OperationLifecycleTest.php

use App\Events\OperationUpdated;
use App\Models\Operation;
use App\Models\User;
use Illuminate\Support\Facades\Event;

test('markRunning sets running + broadcasts a status event', function () {
    Event::fake([OperationUpdated::class]);
    $op = Operation::create(['user_id' => User::factory()->create()->id, 'type' => 't']);

    $op->markRunning();

    expect($op->fresh()->status)->toBe('running')
        ->and($op->fresh()->started_at)->not->toBeNull();
    Event::assertDispatched(OperationUpdated::class, fn ($e) =>
        $e->operation->is($op) && $e->kind === 'status');
});

test('appendOutput accumulates lines + broadcasts each line', function () {
    Event::fake([OperationUpdated::class]);
    $op = Operation::create(['user_id' => User::factory()->create()->id, 'type' => 't']);

    $op->appendOutput('line one');
    $op->appendOutput('line two');

    expect($op->fresh()->output)->toBe("line one\nline two\n");
    Event::assertDispatchedTimes(OperationUpdated::class, 2);
});

test('markFinished maps exit code to status + broadcasts', function () {
    Event::fake([OperationUpdated::class]);
    $ok = Operation::create(['user_id' => User::factory()->create()->id, 'type' => 't']);
    $bad = Operation::create(['user_id' => User::factory()->create()->id, 'type' => 't']);

    $ok->markFinished(0);
    $bad->markFinished(1);

    expect($ok->fresh()->status)->toBe('succeeded')
        ->and($ok->fresh()->exit_code)->toBe(0)
        ->and($ok->fresh()->finished_at)->not->toBeNull()
        ->and($bad->fresh()->status)->toBe('failed');
});

test('the event carries the agreed payload + channel', function () {
    $op = Operation::create(['user_id' => 7, 'type' => 't']);
    $event = new OperationUpdated($op, 'line', 'hello');

    expect($event->broadcastAs())->toBe('OperationUpdated')
        ->and($event->broadcastWith())->toMatchArray([
            'operationId' => $op->id, 'kind' => 'line', 'status' => 'queued', 'line' => 'hello',
        ])
        ->and($event->broadcastOn()->name)->toBe('private-operations.7');
});
```

- [ ] **Step 2: Run it; verify it fails**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=OperationLifecycleTest'`
Expected: FAIL — `Class "App\Events\OperationUpdated" not found`.

- [ ] **Step 3: Write the event**

```php
<?php // app/Events/OperationUpdated.php

namespace App\Events;

use App\Models\Operation;
use Illuminate\Broadcasting\InteractsWithSockets;
use Illuminate\Broadcasting\PrivateChannel;
use Illuminate\Contracts\Broadcasting\ShouldBroadcast;
use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

class OperationUpdated implements ShouldBroadcast
{
    use Dispatchable, InteractsWithSockets, SerializesModels;

    public function __construct(
        public Operation $operation,
        public string $kind,          // 'status' | 'line'
        public ?string $line = null,
    ) {}

    public function broadcastOn(): PrivateChannel
    {
        return new PrivateChannel('operations.' . $this->operation->user_id);
    }

    public function broadcastAs(): string
    {
        return 'OperationUpdated';
    }

    public function broadcastWith(): array
    {
        return [
            'operationId' => $this->operation->id,
            'kind' => $this->kind,
            'status' => $this->operation->status,
            'line' => $this->line,
            'exitCode' => $this->operation->exit_code,
        ];
    }
}
```

- [ ] **Step 4: Add the channel authorization**

Append to `routes/channels.php`:
```php
Broadcast::channel('operations.{userId}', function ($user, $userId) {
    return (int) $user->id === (int) $userId || $user->isAdmin();
});
```

- [ ] **Step 5: Add the lifecycle methods to `Operation`**

Add these methods to `app/Models/Operation.php` (after `prunable()`):
```php
    public function markRunning(): void
    {
        $this->update(['status' => 'running', 'started_at' => now()]);
        \App\Events\OperationUpdated::dispatch($this, 'status');
    }

    public function appendOutput(string $line): void
    {
        $this->update(['output' => ($this->output ?? '') . $line . "\n"]);
        \App\Events\OperationUpdated::dispatch($this, 'line', $line);
    }

    public function markFinished(int $exitCode): void
    {
        $this->update([
            'status' => $exitCode === 0 ? 'succeeded' : 'failed',
            'exit_code' => $exitCode,
            'finished_at' => now(),
        ]);
        \App\Events\OperationUpdated::dispatch($this, 'status');
    }
```

- [ ] **Step 6: Run the test; verify it passes**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=OperationLifecycleTest'`
Expected: PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
git add app/Events/OperationUpdated.php routes/channels.php app/Models/Operation.php tests/Feature/Operations/OperationLifecycleTest.php
git commit -m "feat(operations): OperationUpdated event + channel auth + lifecycle methods"
```

---

### Task 3: Abstract `OperationJob` base

**Files:**
- Create: `app/Jobs/OperationJob.php`
- Test: `tests/Feature/Operations/OperationJobTest.php` (includes an inline test-double subclass)

**Interfaces:**
- Consumes: `Operation` lifecycle methods (Task 2).
- Produces: abstract `App\Jobs\OperationJob` (`ShouldQueue`), constructed `(Operation $operation)`, with abstract `protected function run(callable $emit): int` and a concrete `handle()` that drives running → emit-per-line → finished, marking `failed` + rethrowing on exception.

- [ ] **Step 1: Write the failing test**

```php
<?php // tests/Feature/Operations/OperationJobTest.php

use App\Jobs\OperationJob;
use App\Models\Operation;
use App\Models\User;

// inline test-double subclasses
class SucceedingOperationJob extends OperationJob {
    protected function run(callable $emit): int {
        $emit('doing work'); $emit('more work');
        return 0;
    }
}
class ThrowingOperationJob extends OperationJob {
    protected function run(callable $emit): int {
        $emit('starting');
        throw new \RuntimeException('boom');
    }
}

test('a succeeding job drives the operation to succeeded with captured output', function () {
    $op = Operation::create(['user_id' => User::factory()->create()->id, 'type' => 'demo']);

    (new SucceedingOperationJob($op))->handle();

    $op->refresh();
    expect($op->status)->toBe('succeeded')
        ->and($op->exit_code)->toBe(0)
        ->and($op->output)->toBe("doing work\nmore work\n")
        ->and($op->started_at)->not->toBeNull()
        ->and($op->finished_at)->not->toBeNull();
});

test('a throwing job marks the operation failed, records the error, and rethrows', function () {
    $op = Operation::create(['user_id' => User::factory()->create()->id, 'type' => 'demo']);

    expect(fn () => (new ThrowingOperationJob($op))->handle())
        ->toThrow(\RuntimeException::class);

    $op->refresh();
    expect($op->status)->toBe('failed')
        ->and($op->exit_code)->toBe(1)
        ->and($op->output)->toContain('starting')
        ->and($op->output)->toContain('ERROR: boom');
});
```

- [ ] **Step 2: Run it; verify it fails**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=OperationJobTest'`
Expected: FAIL — `Class "App\Jobs\OperationJob" not found`.

- [ ] **Step 3: Write the abstract job**

```php
<?php // app/Jobs/OperationJob.php

namespace App\Jobs;

use App\Models\Operation;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;

abstract class OperationJob implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public function __construct(public Operation $operation) {}

    /** Do the work; call $emit($line) per output line; return the exit code. */
    abstract protected function run(callable $emit): int;

    public function handle(): void
    {
        $this->operation->markRunning();

        try {
            $exit = $this->run(fn (string $line) => $this->operation->appendOutput($line));
            $this->operation->markFinished($exit);
        } catch (\Throwable $e) {
            $this->operation->appendOutput('ERROR: ' . $e->getMessage());
            $this->operation->markFinished(1);
            throw $e; // also record in failed_jobs
        }
    }
}
```

- [ ] **Step 4: Run the test; verify it passes**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=OperationJobTest'`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add app/Jobs/OperationJob.php tests/Feature/Operations/OperationJobTest.php
git commit -m "feat(operations): abstract OperationJob base (run/emit + lifecycle + failure)"
```

---

### Task 4: Convert SSL generate to async (the proof)

**Files:**
- Modify: `app/Actions/SSL/GenerateWebsiteSslAction.php` (add `?callable $onOutput = null`)
- Create: `app/Jobs/GenerateSslOperationJob.php`
- Modify: `app/Http/Controllers/WebsiteController.php:90-114` (`toggleSsl` enable path → async + JSON)
- Test: `tests/Feature/Operations/GenerateSslOperationTest.php`

**Interfaces:**
- Consumes: `OperationJob` (Task 3), `Operation` (Task 1).
- Produces: `App\Jobs\GenerateSslOperationJob(Operation $operation, Website $website, string $email)`; `GenerateWebsiteSslAction::execute(Website, string $email, ?callable $onOutput = null)`; `toggleSsl` returns JSON `{ operation_id }` for the enable path.

- [ ] **Step 1: Write the failing test**

```php
<?php // tests/Feature/Operations/GenerateSslOperationTest.php

use App\Models\Operation;
use App\Models\PhpVersion;
use App\Models\User;
use App\Models\Website;
use Illuminate\Support\Facades\Process;

function makeSiteFor(User $user): Website {
    $php = PhpVersion::firstOrCreate(['version' => '8.4'], ['active' => true, 'is_default' => true]);
    return $user->websites()->create([
        'url' => 'demo.test', 'document_root' => '/public_html', 'php_version_id' => $php->id,
    ]);
}

test('enabling SSL creates an operation and returns its id (queue sync runs it)', function () {
    Process::fake(['*' => Process::result(output: "active\n", exitCode: 0)]);
    $user = User::factory()->create();
    $site = makeSiteFor($user);

    $response = $this->actingAs($user)
        ->postJson(route('websites.ssl.toggle', $site), ['enabled' => true]);

    $response->assertOk()->assertJsonStructure(['operation_id']);

    $op = Operation::findOrFail($response->json('operation_id'));
    expect($op->type)->toBe('ssl.generate')
        ->and($op->user_id)->toBe($user->id)
        ->and($op->status)->toBe('succeeded'); // ran inline under QUEUE_CONNECTION=sync
    expect($site->fresh()->ssl_status)->toBe('active');
});

test('a failing certbot run marks the operation failed and reverts ssl flags', function () {
    Process::fake(['*' => Process::result(output: '', errorOutput: 'certbot boom', exitCode: 1)]);
    $user = User::factory()->create();
    $site = makeSiteFor($user);

    $response = $this->actingAs($user)
        ->postJson(route('websites.ssl.toggle', $site), ['enabled' => true]);

    $op = Operation::findOrFail($response->json('operation_id'));
    expect($op->status)->toBe('failed');
    expect($site->fresh()->ssl_enabled)->toBeFalse();
});
```

- [ ] **Step 2: Run it; verify it fails**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=GenerateSslOperationTest'`
Expected: FAIL — route returns a redirect (not JSON) / `GenerateSslOperationJob` not found.

- [ ] **Step 3: Add the output callback to `GenerateWebsiteSslAction`**

In `app/Actions/SSL/GenerateWebsiteSslAction.php`, change the signature and the first `Process::run` (the certbot `generate` call) to stream output. Replace:
```php
    public function execute(Website $website, string $email): void
    {
```
with:
```php
    public function execute(Website $website, string $email, ?callable $onOutput = null): void
    {
```
and change the generate `Process::run([...])` call to pass the callback:
```php
        $result = Process::run([
            'sudo',
            config('laranode.laranode_bin_path') . '/laranode-ssl-manager.sh',
            'generate',
            $website->url,
            $email,
            $website->fullDocumentRoot,
        ], $onOutput ? function (string $type, string $buffer) use ($onOutput) {
            foreach (preg_split('/\r?\n/', rtrim($buffer, "\r\n")) as $line) {
                if ($line !== '') {
                    $onOutput($line);
                }
            }
        } : null);
```
(Leave the rest — the `status` check and `$website->update([...])` logic — unchanged.)

- [ ] **Step 4: Write the SSL operation job**

```php
<?php // app/Jobs/GenerateSslOperationJob.php

namespace App\Jobs;

use App\Actions\SSL\GenerateWebsiteSslAction;
use App\Models\Operation;
use App\Models\Website;

class GenerateSslOperationJob extends OperationJob
{
    public function __construct(Operation $operation, public Website $website, public string $email)
    {
        parent::__construct($operation);
    }

    protected function run(callable $emit): int
    {
        $emit("Generating SSL certificate for {$this->website->url}...");
        (new GenerateWebsiteSslAction())->execute($this->website, $this->email, $emit);
        $emit('SSL certificate issued.');
        return 0; // GenerateWebsiteSslAction throws on failure -> base marks failed
    }
}
```

- [ ] **Step 5: Convert `toggleSsl` (enable path) to async + JSON**

In `app/Http/Controllers/WebsiteController.php`, replace the body of `toggleSsl` (lines 90-114) with:
```php
    public function toggleSsl(Request $request, Website $website)
    {
        Gate::authorize('update', $website);

        $request->validate(['enabled' => 'required|boolean']);

        if ($request->enabled) {
            $operation = \App\Models\Operation::create([
                'user_id' => $request->user()->id,
                'type' => 'ssl.generate',
                'target' => $website->url,
                'status' => 'queued',
            ]);

            \App\Jobs\GenerateSslOperationJob::dispatch($operation, $website, $request->user()->email);

            return response()->json(['operation_id' => $operation->id]);
        }

        // Disable path stays synchronous (fast).
        try {
            (new RemoveWebsiteSslAction())->execute($website);
            session()->flash('success', 'SSL certificate removed successfully');
            return redirect()->route('websites.index');
        } catch (\Exception $e) {
            session()->flash('error', 'Failed to remove SSL certificate: ' . $e->getMessage());
            return redirect()->back();
        }
    }
```

- [ ] **Step 6: Run the test; verify it passes**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=GenerateSslOperationTest'`
Expected: PASS (2 tests). If the failure test errors because `RemoveWebsiteSslAction` import is missing, confirm the existing `use App\Actions\SSL\RemoveWebsiteSslAction;` (already present at line 13) is intact.

- [ ] **Step 7: Commit**

```bash
git add app/Actions/SSL/GenerateWebsiteSslAction.php app/Jobs/GenerateSslOperationJob.php app/Http/Controllers/WebsiteController.php tests/Feature/Operations/GenerateSslOperationTest.php
git commit -m "feat(ssl): run SSL generate as an async operation with live output"
```

---

### Task 5: Admin operations audit page

**Files:**
- Create: `app/Http/Controllers/OperationsController.php`
- Modify: `routes/web.php` (add the admin route near the Stats History route, ~line 76)
- Create: `resources/js/Pages/Operations/Index.jsx`
- Test: `tests/Feature/Operations/OperationsPageTest.php`

**Interfaces:**
- Consumes: `Operation` (Task 1).
- Produces: route name `operations.index` at `GET /admin/operations` (auth + admin); Inertia page `Operations/Index` with paginated `operations` (eager-loaded `user`).

- [ ] **Step 1: Write the failing test**

```php
<?php // tests/Feature/Operations/OperationsPageTest.php

use App\Models\Operation;
use App\Models\User;

test('an admin can view the operations audit page', function () {
    $admin = User::factory()->isAdmin()->create();
    Operation::create(['user_id' => $admin->id, 'type' => 'ssl.generate', 'target' => 'demo.test']);

    $this->actingAs($admin)
        ->get(route('operations.index'))
        ->assertOk();
});

test('a non-admin cannot view the operations audit page', function () {
    $user = User::factory()->isNotAdmin()->create();

    $this->actingAs($user)
        ->get(route('operations.index'))
        ->assertForbidden();
});
```

- [ ] **Step 2: Run it; verify it fails**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=OperationsPageTest'`
Expected: FAIL — route `operations.index` not defined.

- [ ] **Step 3: Write the controller**

```php
<?php // app/Http/Controllers/OperationsController.php

namespace App\Http\Controllers;

use App\Models\Operation;
use Inertia\Inertia;

class OperationsController extends Controller
{
    public function index(): \Inertia\Response
    {
        return Inertia::render('Operations/Index', [
            'operations' => Operation::with('user:id,username')->latest()->paginate(30),
        ]);
    }
}
```

- [ ] **Step 4: Add the route**

In `routes/web.php`, after the Stats History route (~line 76), add:
```php
// Operations audit log [Admin]
Route::get('/admin/operations', [\App\Http\Controllers\OperationsController::class, 'index'])
    ->middleware(['auth', AdminMiddleware::class])->name('operations.index');
```

- [ ] **Step 5: Write the Inertia page**

```jsx
// resources/js/Pages/Operations/Index.jsx
import AuthenticatedLayout from '@/Layouts/AuthenticatedLayout';
import { Head } from '@inertiajs/react';
import { useState } from 'react';

const badge = { queued: 'bg-gray-200 text-gray-800', running: 'bg-blue-200 text-blue-800', succeeded: 'bg-green-200 text-green-800', failed: 'bg-red-200 text-red-800' };

export default function Index({ operations }) {
    const [open, setOpen] = useState(null);
    return (
        <AuthenticatedLayout>
            <Head title="Operations" />
            <div className="p-6">
                <h1 className="text-xl font-semibold mb-4">Operations</h1>
                <table className="w-full text-sm">
                    <thead>
                        <tr className="text-left border-b">
                            <th className="py-2">When</th><th>Actor</th><th>Type</th><th>Target</th><th>Status</th>
                        </tr>
                    </thead>
                    <tbody>
                        {operations.data.map((op) => (
                            <tr key={op.id} className="border-b align-top cursor-pointer" onClick={() => setOpen(open === op.id ? null : op.id)}>
                                <td className="py-2">{op.created_at}</td>
                                <td>{op.user?.username ?? '—'}</td>
                                <td>{op.type}</td>
                                <td>{op.target ?? '—'}</td>
                                <td><span className={`px-2 py-1 rounded text-xs ${badge[op.status] ?? ''}`}>{op.status}</span>
                                    {open === op.id && (
                                        <pre className="mt-2 whitespace-pre-wrap bg-black text-green-300 p-2 rounded max-h-64 overflow-auto">{op.output ?? '(no output)'}</pre>
                                    )}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>
        </AuthenticatedLayout>
    );
}
```
(If the layout import alias differs, match the existing pages under `resources/js/Pages/` — they import `AuthenticatedLayout` from `@/Layouts/AuthenticatedLayout`.)

- [ ] **Step 6: Run the test + build assets; verify**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=OperationsPageTest && npm run build'`
Expected: tests PASS (2); build succeeds.

- [ ] **Step 7: Commit**

```bash
git add app/Http/Controllers/OperationsController.php routes/web.php resources/js/Pages/Operations/Index.jsx tests/Feature/Operations/OperationsPageTest.php
git commit -m "feat(operations): admin operations audit page"
```

---

### Task 6: Scheduler hook + operation pruning

**Files:**
- Modify: `bootstrap/app.php` (add `->withSchedule(...)`)
- Test: `tests/Feature/Operations/SchedulerTest.php`

**Interfaces:**
- Consumes: `Operation` `MassPrunable` (Task 1).
- Produces: a registered daily `model:prune` schedule for `Operation`; establishes the `withSchedule` entrypoint for later features.

- [ ] **Step 1: Write the failing test**

```php
<?php // tests/Feature/Operations/SchedulerTest.php

use Illuminate\Console\Scheduling\Schedule;

test('the operation prune command is scheduled', function () {
    $events = app(Schedule::class)->events();
    $commands = collect($events)->map(fn ($e) => $e->command ?? '')->implode(' | ');

    expect($commands)->toContain('model:prune')
        ->and($commands)->toContain('Operation');
});
```

- [ ] **Step 2: Run it; verify it fails**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=SchedulerTest'`
Expected: FAIL — no scheduled `model:prune` (no `withSchedule` configured).

- [ ] **Step 3: Add the scheduler hook**

In `bootstrap/app.php`, add a `use` for the schedule and the `withSchedule` call. The file currently ends with `->withExceptions(...)->create();`. Insert `->withSchedule(...)` before `->create()`:
```php
    ->withSchedule(function (\Illuminate\Console\Scheduling\Schedule $schedule) {
        $schedule->command('model:prune', ['--model' => [\App\Models\Operation::class]])->daily();
    })
    ->create();
```

- [ ] **Step 4: Run the test; verify it passes**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=SchedulerTest'`
Expected: PASS (1). Also confirm `php artisan schedule:list` shows the prune entry.

- [ ] **Step 5: Commit**

```bash
git add bootstrap/app.php tests/Feature/Operations/SchedulerTest.php
git commit -m "feat(platform): scheduler hook + daily operations prune"
```

---

### Task 7: React live-progress (hook + component) + SSL toggle wiring

**Files:**
- Create: `resources/js/hooks/useOperation.js`
- Create: `resources/js/Components/OperationProgress.jsx`
- Modify: `resources/js/Pages/Websites/Index.jsx` (SSL toggle → axios + live progress; the current `toggleSsl` is at ~line 42 using `router.post`)
- Test (Vitest, from Task A): `resources/js/hooks/useOperation.test.jsx`, `resources/js/Components/OperationProgress.test.jsx`
- Verification: automated Vitest component/hook tests (below) + a manual in-container check of the real live-streaming SSL flow (which needs queue+Reverb+Pebble and is deliberately not E2E'd).

**Interfaces:**
- Consumes: the `operations.{userId}` channel + `OperationUpdated` event (Task 2), the `toggleSsl` JSON `{operation_id}` (Task 4), Inertia shared `auth.user.id`, `window.Echo` (`resources/js/echo.js`), `window.axios` (`resources/js/bootstrap.js`).
- Produces: `useOperation(operationId)` → `{ status, lines, exitCode }`; `<OperationProgress operationId=… />`.

- [ ] **Step 1: Write the `useOperation` hook**

```js
// resources/js/hooks/useOperation.js
import { useEffect, useState } from 'react';
import { usePage } from '@inertiajs/react';

export default function useOperation(operationId) {
    const userId = usePage().props.auth.user.id;
    const [status, setStatus] = useState('queued');
    const [lines, setLines] = useState([]);
    const [exitCode, setExitCode] = useState(null);

    useEffect(() => {
        if (!operationId) return;
        setStatus('queued'); setLines([]); setExitCode(null);

        const channel = window.Echo.private(`operations.${userId}`);
        channel.listen('.OperationUpdated', (e) => {
            if (e.operationId !== operationId) return;
            if (e.kind === 'line' && e.line) setLines((prev) => [...prev, e.line]);
            if (e.kind === 'status') { setStatus(e.status); setExitCode(e.exitCode); }
        });

        return () => window.Echo.leave(`operations.${userId}`);
    }, [operationId, userId]);

    return { status, lines, exitCode };
}
```
(Note the leading dot in `.OperationUpdated` — Echo uses it for custom `broadcastAs` names.)

- [ ] **Step 2: Write the `OperationProgress` component**

```jsx
// resources/js/Components/OperationProgress.jsx
import useOperation from '@/hooks/useOperation';

const badge = { queued: 'text-gray-500', running: 'text-blue-600', succeeded: 'text-green-600', failed: 'text-red-600' };

export default function OperationProgress({ operationId, onDone }) {
    const { status, lines, exitCode } = useOperation(operationId);

    if ((status === 'succeeded' || status === 'failed') && onDone) {
        // fire once when terminal
        setTimeout(() => onDone(status), 0);
    }

    return (
        <div className="mt-2">
            <div className={`text-sm font-medium ${badge[status] ?? ''}`}>Status: {status}{exitCode !== null ? ` (exit ${exitCode})` : ''}</div>
            <pre className="mt-1 whitespace-pre-wrap bg-black text-green-300 p-2 rounded max-h-64 overflow-auto text-xs">{lines.join('\n') || '…'}</pre>
        </div>
    );
}
```

- [ ] **Step 3: Write the Vitest test for `useOperation`**

```jsx
// resources/js/hooks/useOperation.test.jsx
import { renderHook, act } from '@testing-library/react';
import { test, expect, vi, beforeEach } from 'vitest';
import useOperation from '@/hooks/useOperation';

let captured; // the .listen() callback the hook registers
vi.mock('@inertiajs/react', () => ({
    usePage: () => ({ props: { auth: { user: { id: 7 } } } }),
}));

beforeEach(() => {
    captured = null;
    window.Echo = {
        private: () => ({ listen: (_name, cb) => { captured = cb; } }),
        leave: vi.fn(),
    };
});

test('accumulates lines and tracks status for the matching operation', () => {
    const { result } = renderHook(() => useOperation(42));
    act(() => captured({ operationId: 42, kind: 'line', line: 'hello' }));
    act(() => captured({ operationId: 42, kind: 'status', status: 'running', exitCode: null }));
    expect(result.current.lines).toEqual(['hello']);
    expect(result.current.status).toBe('running');
});

test('ignores events for a different operation id', () => {
    const { result } = renderHook(() => useOperation(42));
    act(() => captured({ operationId: 99, kind: 'line', line: 'nope' }));
    expect(result.current.lines).toEqual([]);
});
```

- [ ] **Step 4: Write the Vitest test for `OperationProgress`**

```jsx
// resources/js/Components/OperationProgress.test.jsx
import { render, screen, act } from '@testing-library/react';
import { test, expect, vi, beforeEach } from 'vitest';
import OperationProgress from '@/Components/OperationProgress';

let captured;
vi.mock('@inertiajs/react', () => ({
    usePage: () => ({ props: { auth: { user: { id: 1 } } } }),
}));

beforeEach(() => {
    captured = null;
    window.Echo = {
        private: () => ({ listen: (_name, cb) => { captured = cb; } }),
        leave: vi.fn(),
    };
});

test('renders streamed lines and the terminal status', () => {
    render(<OperationProgress operationId={5} onDone={vi.fn()} />);
    act(() => captured({ operationId: 5, kind: 'line', line: 'building...' }));
    act(() => captured({ operationId: 5, kind: 'status', status: 'succeeded', exitCode: 0 }));
    expect(screen.getByText(/building\.\.\./)).toBeInTheDocument();
    expect(screen.getByText(/Status: succeeded/)).toBeInTheDocument();
});
```

- [ ] **Step 5: Run the Vitest tests; verify they pass**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && npm run test'`
Expected: all Vitest tests pass (sanity + the 2 hook tests + the component test). If `usePage` mocking errors, confirm `@inertiajs/react` is the import path used by the hook/component.

- [ ] **Step 6: Wire the SSL toggle in `Websites/Index.jsx`**

Replace the `toggleSsl` handler (current, ~line 42, which does `router.post(...)`). New behavior: enabling SSL calls the endpoint via axios, stores the returned `operation_id` in state, and renders `<OperationProgress>`; on terminal status, `router.reload()`. Disabling keeps the existing `router.post` redirect. Add at the top: `import { useState } from 'react'; import axios from 'axios'; import OperationProgress from '@/Components/OperationProgress';` and a state `const [sslOp, setSslOp] = useState(null);`. Handler:
```jsx
    const toggleSsl = (website) => {
        const enabling = !website.ssl_enabled;
        if (enabling) {
            axios.post(route('websites.ssl.toggle', { website: website.id }), { enabled: true })
                .then((res) => setSslOp({ id: res.data.operation_id, url: website.url }));
        } else {
            router.post(route('websites.ssl.toggle', { website: website.id }), { enabled: false }, {
                preserveScroll: true, onSuccess: () => router.reload(),
            });
        }
    };
```
And render, near the table (e.g. above it), the live panel when an op is active:
```jsx
    {sslOp && (
        <div className="mb-4 p-3 border rounded">
            <div className="text-sm">Issuing SSL for {sslOp.url}</div>
            <OperationProgress operationId={sslOp.id} onDone={() => { setSslOp(null); router.reload(); }} />
        </div>
    )}
```

- [ ] **Step 7: Build assets**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && npm run build'`
Expected: build succeeds (no import errors).

- [ ] **Step 8: Manual verification of the live-streaming flow (the one path not E2E'd)**

The component/hook logic is now covered by Vitest (Steps 3–5); the operation lifecycle by Pest (Task 4). What remains is the real end-to-end live stream, which needs queue+Reverb+Pebble and is deliberately not automated. Verify it once manually:
Ensure the queue worker + Reverb are running: `docker exec laranode-lab bash -lc 'systemctl is-active laranode-queue-worker laranode-reverb'` → both `active`.
Then in the browser (`http://localhost`, logged in as admin), with the `ssl` profile up (`make ssl-test` from PowerShell so Pebble is reachable): create a website, click Enable SSL, confirm the live log streams certbot output and ends `succeeded`, the row shows SSL active, and `/admin/operations` lists the run with its output. Report the outcome (this is the one manual gate; everything else is automated).

- [ ] **Step 9: Commit**

```bash
git add resources/js/hooks/useOperation.js resources/js/Components/OperationProgress.jsx resources/js/Pages/Websites/Index.jsx resources/js/hooks/useOperation.test.jsx resources/js/Components/OperationProgress.test.jsx
git commit -m "feat(ui): live operation progress (hook + component) + SSL toggle streaming + Vitest tests"
```

---

## Self-Review

**1. Spec coverage:**
- front-end unit/component test harness (Vitest+RTL+jsdom) → Task A ✓
- front-end E2E harness (Playwright smoke) → Task B ✓
- operations table + model → Task 1 ✓
- OperationUpdated event + user-scoped channel auth → Task 2 ✓
- lifecycle (markRunning/appendOutput/markFinished, broadcast) → Task 2 ✓
- abstract OperationJob convention → Task 3 ✓
- SSL conversion (action `$onOutput`, job, controller JSON) → Task 4 ✓
- streamed output lines (Process callback splitting buffer) → Task 4 Step 3 ✓
- React hook + OperationProgress + SSL UI → Task 7 ✓ (now with Vitest component/hook tests, Steps 3–5)
- admin audit page → Task 5 ✓
- scheduler hook + prune → Task 6 ✓
- tests (lifecycle, failure, broadcast, channel auth, SSL, admin page) → Tasks 1–6 ✓ (channel-auth assertion lives in Task 2 Step 1's payload/channel test + the `routes/channels.php` closure; a dedicated auth-callback test is optional — the closure is trivial and exercised via the broadcasting auth route in manual verification).
- front-end testing (component/hook + E2E) → Task A (Vitest) + Task B (Playwright) + Task 7's Vitest tests ✓

**2. Placeholder scan:** No TBD/TODO; every code step has complete code; commands have expected output.

**3. Type/contract consistency:** `Operation` fields + methods (`markRunning`/`appendOutput`/`markFinished`) consistent across Tasks 1–4. `OperationUpdated(operation, kind, line)` + payload keys (`operationId`/`kind`/`status`/`line`/`exitCode`) consistent between Task 2 (event), Task 7 (hook + its Vitest test read them), and the Global Constraints. Channel `operations.{userId}` consistent (Task 2 auth, Task 7 subscribe). `GenerateSslOperationJob(operation, website, email)` matches Task 4 dispatch. `toggleSsl` JSON `{operation_id}` consistent between Task 4 (returns) and Task 7 (reads `res.data.operation_id`). Route name `operations.index` consistent (Task 5).

**Front-end testing coverage (was the prior gap, now closed):** Task A adds Vitest+RTL+jsdom (project had no JS harness); Task 7 adds deterministic component/hook tests for `useOperation` + `OperationProgress`; Task B adds Playwright E2E smokes. The only remaining **manual** gate is the real live-streaming SSL flow (queue+Reverb+Pebble), deliberately not E2E'd to avoid flakiness — and even that is component-tested (UI logic) + Pest-tested (backend lifecycle). Surfaced honestly, not implied as fully E2E'd.
