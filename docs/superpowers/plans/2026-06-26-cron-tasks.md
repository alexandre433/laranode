# Cron Tasks — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each Laranode user a UI to manage scheduled cron jobs for their `{username}_ln` system account. The panel DB is the authoritative record; `laranode-cron.sh` syncs to the real crontab on every write. All mutations write an audit `Operation` row using the shipped foundation from `feature/platform-async-progress`.

**Architecture:** Controller (thin) → FormRequest (validation) → Service (sync, sub-second) → `laranode-cron.sh` via `Process::run` + `Operation` row created and lifecycle-driven inline (no queue needed — crontab writes are sub-second). Flash messages are sufficient feedback; no `OperationProgress` live UI.

**Tech Stack:** Laravel 12, Pest 3, Inertia + React (JSX), `Process` facade (with `Process::fake()` in tests), MySQL (prod) / SQLite `:memory:` (tests).

## Global Constraints

- **Operation types:** `cron.create` | `cron.delete` | `cron.toggle` — consistent everywhere (controller, tests, audit page).
- **`Operation` lifecycle is driven inline by the controller**, not via a queued job. Pattern: `Operation::create([...]) → $op->markRunning() → Service::handle() → $op->appendOutput() → $op->markFinished($exitCode)`. On service exception, the controller catches, calls `$op->markFinished(1)`, and flashes `flash.error`.
- **`scopeMine()` on `CronJob`** must mirror the pattern in `app/Models/Database.php:49` and `app/Models/Operation.php:33` exactly — admins see all rows, non-admins see only their own `user_id`.
- **`CronJobPolicy`** mirrors `WebsitePolicy`: `$user->isAdmin() || $user->id === $cronJob->user_id`. Checked via `Gate::authorize` in destroy and toggleActive.
- **`laranode-cron.sh` uses full rebuild on every write** — PHP passes all active jobs for the user via a temp file (not shell args), the script atomically replaces only the `# laranode-managed` block. Manually added crontab entries for `{username}_ln` are left untouched.
- **Sudoers drop-in** (`etc/sudoers.d/laranode-cron`) is a separate file, not appended to the monolithic installer line. The installer copies it.
- **`AllowedCronCommand` rule must reject** shell metacharacters (`;`, `&&`, `||`, `|`, `>`, `<`, `` $(...) ``), paths outside `{username}_ln` homedir, and only allowlist: `php /home/{username}_ln/...`, `artisan /home/{username}_ln/...`, `curl https?://...`, `wget https?://...`.
- **Tests run with `QUEUE_CONNECTION=sync`** (already in `phpunit.xml`). Use `Process::fake()` to assert script invocation without executing on the real system. System tests (real script, real crontab) are gated behind `LARANODE_SYSTEM_TESTS=1`.
- **Branch:** `feature/cron-tasks` (off `development`). Each task commits here.
- **Run the authoritative suite inside the container:** `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test'`. `make`/`docker compose` from PowerShell only; `docker exec …` from any shell.

---

> **Execution order:** Tasks 1–7 in order. Task 1 (migration + model) is depended on by all others. Task 2 (validation rules) is depended on by Task 3 (FormRequest). Task 4 (services + script) depends on Tasks 1 and 3. Task 5 (controller + routes) depends on Tasks 1–4. Task 6 (React UI) depends on Task 5. Task 7 (system test + final gate) depends on everything.

---

### Task 1: `cron_jobs` table + `CronJob` model

**TDD: yes — write the failing test before the migration and model.**

**Files:**
- Create: `database/migrations/XXXX_create_cron_jobs_table.php`
- Create: `app/Models/CronJob.php`
- Create: `tests/Feature/CronJobs/CronJobModelTest.php`

**Interfaces:**
- Produces: `App\Models\CronJob` with columns `id, user_id, schedule, command, label, active, timestamps`; `belongsTo(User)`; `$fillable`; `$casts = ['active' => 'boolean']`; `scopeMine(Builder): Builder`. Consumed by Tasks 3–7.

- [ ] **Step 1: Write the failing test**

```php
<?php // tests/Feature/CronJobs/CronJobModelTest.php

use App\Models\CronJob;
use App\Models\User;

test('a cron job belongs to its owner user', function () {
    $user = User::factory()->create();
    $job = CronJob::create([
        'user_id' => $user->id,
        'schedule' => '0 2 * * *',
        'command'  => 'php /home/testuser_ln/app/artisan schedule:run',
        'label'    => 'Daily artisan',
    ]);

    expect($job->user->is($user))->toBeTrue()
        ->and($job->active)->toBeTrue(); // default
});

test('scopeMine restricts non-admins to their own cron jobs', function () {
    $admin = User::factory()->isAdmin()->create();
    $user  = User::factory()->isNotAdmin()->create();
    $other = User::factory()->isNotAdmin()->create();

    CronJob::create(['user_id' => $user->id,  'schedule' => '* * * * *', 'command' => 'php /home/u_ln/a.php']);
    CronJob::create(['user_id' => $other->id, 'schedule' => '* * * * *', 'command' => 'php /home/o_ln/a.php']);

    $this->actingAs($user);
    expect(CronJob::mine()->count())->toBe(1);

    $this->actingAs($admin);
    expect(CronJob::mine()->count())->toBe(2);
});

test('cron job active field defaults to true and can be cast to bool', function () {
    $user = User::factory()->create();
    $job  = CronJob::create(['user_id' => $user->id, 'schedule' => '* * * * *', 'command' => 'curl https://example.com']);

    expect($job->active)->toBeTrue();
    $job->update(['active' => false]);
    expect($job->fresh()->active)->toBeFalse();
});
```

- [ ] **Step 2: Run it; verify it fails**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=CronJobModelTest'`
Expected: FAIL — `Class "App\Models\CronJob" not found`.

- [ ] **Step 3: Write the migration**

Filename: `database/migrations/XXXX_create_cron_jobs_table.php` (use `php artisan make:migration create_cron_jobs_table` inside the container to get the correct timestamp prefix, then replace the body):

```php
public function up(): void
{
    Schema::create('cron_jobs', function (Blueprint $table) {
        $table->id();
        $table->foreignId('user_id')->constrained()->onDelete('cascade');
        $table->string('schedule', 100);         // cron expression e.g. "0 2 * * *"
        $table->string('command', 500);          // shell command
        $table->string('label', 255)->nullable();// human description
        $table->boolean('active')->default(true);
        $table->timestamps();

        $table->index(['user_id', 'active']);
    });
}

public function down(): void
{
    Schema::dropIfExists('cron_jobs');
}
```

- [ ] **Step 4: Write the model**

```php
<?php // app/Models/CronJob.php

namespace App\Models;

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class CronJob extends Model
{
    protected $fillable = ['user_id', 'schedule', 'command', 'label', 'active'];

    protected $casts = ['active' => 'boolean'];

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function scopeMine(Builder $query): Builder
    {
        $user = auth()->user();
        return $query->when($user && ! $user->isAdmin(), fn ($q) => $q->where('user_id', $user->id));
    }
}
```

- [ ] **Step 5: Run the test; verify it passes**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=CronJobModelTest'`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add database/migrations/ app/Models/CronJob.php tests/Feature/CronJobs/CronJobModelTest.php
git commit -m "feat(cron): cron_jobs migration + CronJob model (scopeMine, active cast)"
```

---

### Task 2: Validation rules — `ValidCronExpression` + `AllowedCronCommand`

**TDD: yes — write the failing tests first.**

**Files:**
- Create: `app/Rules/ValidCronExpression.php`
- Create: `app/Rules/AllowedCronCommand.php`
- Create: `tests/Unit/ValidCronExpressionRuleTest.php`
- Create: `tests/Unit/AllowedCronCommandRuleTest.php`

**Interfaces:**
- Produces: two `Illuminate\Contracts\Validation\Rule` implementors. `ValidCronExpression` validates a 5-field cron expression. `AllowedCronCommand` enforces the command allowlist and metacharacter blocklist, receiving the authenticated user via its constructor. Consumed by `StoreCronJobRequest` (Task 3).

- [ ] **Step 1: Write the failing tests**

```php
<?php // tests/Unit/ValidCronExpressionRuleTest.php

use App\Rules\ValidCronExpression;
use Illuminate\Support\Facades\Validator;

dataset('valid_expressions', [
    '* * * * *',
    '0 2 * * *',
    '*/5 * * * *',
    '0 0 1 1 *',
    '30 6 * * 1-5',
]);

dataset('invalid_expressions', [
    '',
    'not a cron',
    '* * * *',         // only 4 fields
    '* * * * * *',     // 6 fields
    '60 * * * *',      // minute out of range
    '* 25 * * *',      // hour out of range
]);

test('valid cron expressions pass', function (string $expr) {
    $v = Validator::make(['s' => $expr], ['s' => [new ValidCronExpression]]);
    expect($v->passes())->toBeTrue();
})->with('valid_expressions');

test('invalid cron expressions fail', function (string $expr) {
    $v = Validator::make(['s' => $expr], ['s' => [new ValidCronExpression]]);
    expect($v->fails())->toBeTrue();
})->with('invalid_expressions');
```

```php
<?php // tests/Unit/AllowedCronCommandRuleTest.php

use App\Rules\AllowedCronCommand;
use App\Models\User;
use Illuminate\Support\Facades\Validator;

function makeUser(string $username = 'alice'): User
{
    return User::factory()->make(['username' => $username]);
}

dataset('allowed_commands', [
    'php /home/alice_ln/app/artisan schedule:run',
    'php /home/alice_ln/public_html/index.php',
    'curl https://example.com/webhook',
    'wget -q https://example.com/ping',
]);

dataset('blocked_commands', [
    'php /home/other_ln/app/artisan',       // outside own homedir
    'rm -rf /',                              // not an allowed prefix
    'php /home/alice_ln/a.php; rm -rf /',   // semicolon metachar
    'php /home/alice_ln/a.php && curl x',   // && metachar
    'php /home/alice_ln/a.php | bash',      // pipe metachar
    'php /home/alice_ln/$(id)/a.php',       // subshell
    'curl http://example.com',              // http not https
]);

test('allowed commands pass validation', function (string $cmd) {
    $user = makeUser('alice');
    $v = Validator::make(['c' => $cmd], ['c' => [new AllowedCronCommand($user)]]);
    expect($v->passes())->toBeTrue();
})->with('allowed_commands');

test('blocked commands fail validation', function (string $cmd) {
    $user = makeUser('alice');
    $v = Validator::make(['c' => $cmd], ['c' => [new AllowedCronCommand($user)]]);
    expect($v->fails())->toBeTrue();
})->with('blocked_commands');
```

- [ ] **Step 2: Run them; verify they fail**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter="ValidCronExpressionRuleTest|AllowedCronCommandRuleTest"'`
Expected: FAIL — `Class "App\Rules\ValidCronExpression" not found`.

- [ ] **Step 3: Write `ValidCronExpression`**

```php
<?php // app/Rules/ValidCronExpression.php

namespace App\Rules;

use Closure;
use Illuminate\Contracts\Validation\ValidationRule;

class ValidCronExpression implements ValidationRule
{
    public function validate(string $attribute, mixed $value, Closure $fail): void
    {
        $parts = preg_split('/\s+/', trim((string) $value));
        if (count($parts) !== 5) {
            $fail('The :attribute must be a valid 5-field cron expression (e.g. "0 2 * * *").');
            return;
        }

        [$minute, $hour, $dom, $month, $dow] = $parts;

        $ranges = [
            $minute => [0, 59],
            $hour   => [0, 23],
            $dom    => [1, 31],
            $month  => [1, 12],
            $dow    => [0, 7],
        ];

        foreach ($ranges as $field => [$min, $max]) {
            if (! $this->fieldValid($field, $min, $max)) {
                $fail('The :attribute contains an invalid cron field value.');
                return;
            }
        }
    }

    private function fieldValid(string $field, int $min, int $max): bool
    {
        // wildcards
        if ($field === '*') return true;

        // step expressions */n or range/n
        if (preg_match('/^(\*|\d+)-?(\d+)?\/(\d+)$/', $field)) return true;

        // range n-m
        if (preg_match('/^(\d+)-(\d+)$/', $field, $m)) {
            return (int)$m[1] >= $min && (int)$m[2] <= $max && (int)$m[1] <= (int)$m[2];
        }

        // comma-separated list
        if (str_contains($field, ',')) {
            foreach (explode(',', $field) as $v) {
                if (! is_numeric($v) || (int)$v < $min || (int)$v > $max) return false;
            }
            return true;
        }

        // single integer
        if (is_numeric($field)) return (int)$field >= $min && (int)$field <= $max;

        return false;
    }
}
```

- [ ] **Step 4: Write `AllowedCronCommand`**

```php
<?php // app/Rules/AllowedCronCommand.php

namespace App\Rules;

use App\Models\User;
use Closure;
use Illuminate\Contracts\Validation\ValidationRule;

class AllowedCronCommand implements ValidationRule
{
    public function __construct(private User $user) {}

    public function validate(string $attribute, mixed $value, Closure $fail): void
    {
        $cmd = (string) $value;

        // Block shell metacharacters
        if (preg_match('/[;&|><`]|\$\(/', $cmd)) {
            $fail('The :attribute contains disallowed shell characters.');
            return;
        }

        $homedir = '/home/' . $this->user->systemUsername;

        $allowed = [
            '/^php\s+' . preg_quote($homedir, '/') . '\//',
            '/^curl\s+https:\/\//',
            '/^wget\s+(-\S+\s+)*https:\/\//',
        ];

        foreach ($allowed as $pattern) {
            if (preg_match($pattern, $cmd)) return;
        }

        $fail('The :attribute must be a php, curl, or wget command scoped to your home directory.');
    }
}
```

- [ ] **Step 5: Run the tests; verify they pass**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter="ValidCronExpressionRuleTest|AllowedCronCommandRuleTest"'`
Expected: PASS (all dataset variants).

- [ ] **Step 6: Commit**

```bash
git add app/Rules/ValidCronExpression.php app/Rules/AllowedCronCommand.php tests/Unit/ValidCronExpressionRuleTest.php tests/Unit/AllowedCronCommandRuleTest.php
git commit -m "feat(cron): ValidCronExpression + AllowedCronCommand validation rules"
```

---

### Task 3: `StoreCronJobRequest` + `CronJobPolicy`

**TDD: yes — the policy and FormRequest are exercised via HTTP tests written before the controller exists.**

**Files:**
- Create: `app/Http/Requests/StoreCronJobRequest.php`
- Create: `app/Policies/CronJobPolicy.php`
- Create: `tests/Feature/CronJobs/CronJobPolicyTest.php`

**Interfaces:**
- `StoreCronJobRequest` — `authorize()` returns `true` (all auth'd users may create), `rules()` validates `schedule` (ValidCronExpression), `command` (AllowedCronCommand), `label` (nullable string max 255). `CronJobPolicy` — `delete(User, CronJob): Response`, `update(User, CronJob): Response` — mirrors `WebsitePolicy`. Consumed by Task 5 controller.

- [ ] **Step 1: Write the failing policy test**

```php
<?php // tests/Feature/CronJobs/CronJobPolicyTest.php

use App\Models\CronJob;
use App\Models\User;

test('an admin can delete any cron job', function () {
    $admin = User::factory()->isAdmin()->create();
    $other = User::factory()->isNotAdmin()->create();
    $job   = CronJob::create(['user_id' => $other->id, 'schedule' => '* * * * *', 'command' => 'curl https://x.test']);

    $this->actingAs($admin);
    expect($this->actingAs($admin)->can('delete', $job))->toBeTrue();
});

test('a user can only delete their own cron job', function () {
    $user  = User::factory()->isNotAdmin()->create();
    $other = User::factory()->isNotAdmin()->create();

    $own   = CronJob::create(['user_id' => $user->id,  'schedule' => '* * * * *', 'command' => 'curl https://x.test']);
    $theirs= CronJob::create(['user_id' => $other->id, 'schedule' => '* * * * *', 'command' => 'curl https://x.test']);

    $this->actingAs($user);
    expect($this->actingAs($user)->can('delete', $own))->toBeTrue();
    expect($this->actingAs($user)->can('delete', $theirs))->toBeFalse();
});
```

- [ ] **Step 2: Run it; verify it fails**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=CronJobPolicyTest'`
Expected: FAIL — no policy registered.

- [ ] **Step 3: Write `CronJobPolicy`**

```php
<?php // app/Policies/CronJobPolicy.php

namespace App\Policies;

use App\Models\CronJob;
use App\Models\User;
use Illuminate\Auth\Access\Response;

class CronJobPolicy
{
    public function delete(User $user, CronJob $cronJob): Response
    {
        return ($user->isAdmin() || $user->id === $cronJob->user_id)
            ? Response::allow()
            : Response::deny('You are not authorized to delete this cron job.');
    }

    public function update(User $user, CronJob $cronJob): Response
    {
        return ($user->isAdmin() || $user->id === $cronJob->user_id)
            ? Response::allow()
            : Response::deny('You are not authorized to update this cron job.');
    }
}
```

Register it in `app/Providers/AuthServiceProvider.php` (or the `$policies` array if the project uses explicit registration):

```php
protected $policies = [
    // ... existing ...
    \App\Models\CronJob::class => \App\Policies\CronJobPolicy::class,
];
```

If the project relies on automatic policy discovery (no explicit `$policies` array), no registration step is needed — confirm by checking `AuthServiceProvider` before adding.

- [ ] **Step 4: Write `StoreCronJobRequest`**

```php
<?php // app/Http/Requests/StoreCronJobRequest.php

namespace App\Http\Requests;

use App\Rules\AllowedCronCommand;
use App\Rules\ValidCronExpression;
use Illuminate\Foundation\Http\FormRequest;

class StoreCronJobRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true; // any authenticated user may create their own cron jobs
    }

    public function rules(): array
    {
        return [
            'schedule' => ['required', 'string', 'max:100', new ValidCronExpression],
            'command'  => ['required', 'string', 'max:500', new AllowedCronCommand($this->user())],
            'label'    => ['nullable', 'string', 'max:255'],
        ];
    }
}
```

- [ ] **Step 5: Run the policy test; verify it passes**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=CronJobPolicyTest'`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add app/Http/Requests/StoreCronJobRequest.php app/Policies/CronJobPolicy.php app/Providers/AuthServiceProvider.php tests/Feature/CronJobs/CronJobPolicyTest.php
git commit -m "feat(cron): StoreCronJobRequest + CronJobPolicy (mirrors WebsitePolicy)"
```

---

### Task 4: `laranode-cron.sh` + sudoers drop-in + Services

**This task has two sub-parts: (A) the bash script + sudoers file, then (B) the PHP services. Write the PHP service tests before writing the service classes.**

**TDD: yes for PHP services (write tests first). The bash script is tested implicitly via `Process::fake()` in PHP tests and explicitly via system test in Task 7.**

**Files:**
- Create: `laranode-scripts/bin/laranode-cron.sh`
- Create: `etc/sudoers.d/laranode-cron`
- Create: `app/Services/CronJobs/CreateCronJobService.php` (includes `CreateCronJobException`)
- Create: `app/Services/CronJobs/DeleteCronJobService.php` (includes `DeleteCronJobException`)
- Create: `tests/Feature/CronJobs/StoreCronJobTest.php` (services tested via HTTP through the controller — but we write the test here, before the controller, to validate the service interface via direct instantiation)

**Interfaces:**
- `CreateCronJobService(__construct(CronJob $cronJob, User $user))::handle(): void` — passes all active jobs for `$user` to `laranode-cron.sh set`; throws `CreateCronJobException` on non-zero exit.
- `DeleteCronJobService(__construct(CronJob $cronJob, User $user))::handle(): void` — deletes the DB row first, then re-syncs remaining active jobs via `laranode-cron.sh set`; throws `DeleteCronJobException` on non-zero exit.
- Script interface: `laranode-cron.sh set <system_user> <tmp_file_path>` — reads newline-separated `schedule|command` pairs from the tmp file, rebuilds the managed block in the crontab.

- [ ] **Step 1: Write `laranode-cron.sh`**

```bash
#!/usr/bin/env bash
# laranode-cron.sh — manage the laranode-managed block in a user's crontab
# Usage:
#   set    <system_user> <tmp_file>   — rebuild managed block from newline-delimited "schedule TAB command" file
#   remove <system_user>              — remove all managed lines for the user (equivalent to set with empty file)
#   list   <system_user>              — print current crontab (for diagnostics)
set -euo pipefail

ACTION="${1:-}"
SYSTEM_USER="${2:-}"
TMP_FILE="${3:-}"

MARKER="# laranode-managed"

if [[ -z "$ACTION" || -z "$SYSTEM_USER" ]]; then
    echo "Usage: $0 {set|remove|list} <system_user> [<tmp_file>]" >&2
    exit 1
fi

case "$ACTION" in
    list)
        crontab -l -u "$SYSTEM_USER" 2>/dev/null || true
        ;;

    set)
        if [[ -z "$TMP_FILE" || ! -f "$TMP_FILE" ]]; then
            echo "ERROR: tmp_file required and must exist for 'set'" >&2
            exit 1
        fi

        # Read existing crontab, strip any previously managed lines
        EXISTING=$(crontab -l -u "$SYSTEM_USER" 2>/dev/null || true)
        MANUAL_LINES=$(printf '%s\n' "$EXISTING" | grep -v "$MARKER" || true)

        # Build new managed block from tmp file
        MANAGED_BLOCK=""
        while IFS= read -r LINE || [[ -n "$LINE" ]]; do
            [[ -z "$LINE" ]] && continue
            MANAGED_BLOCK+="${LINE} ${MARKER}"$'\n'
        done < "$TMP_FILE"

        # Write back: managed block first, then manual lines
        {
            printf '%s\n' "$MANAGED_BLOCK"
            printf '%s\n' "$MANUAL_LINES"
        } | crontab -u "$SYSTEM_USER" -
        ;;

    remove)
        EXISTING=$(crontab -l -u "$SYSTEM_USER" 2>/dev/null || true)
        printf '%s\n' "$EXISTING" | grep -v "$MARKER" | crontab -u "$SYSTEM_USER" -
        ;;

    *)
        echo "Unknown action: $ACTION" >&2
        exit 1
        ;;
esac
```

Make it executable: `chmod +x laranode-scripts/bin/laranode-cron.sh`

- [ ] **Step 2: Write the sudoers drop-in `etc/sudoers.d/laranode-cron`**

```
www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-cron.sh
```

Note: the path must match `config('laranode.laranode_bin_path')`. The installer copies this file to `/etc/sudoers.d/laranode-cron` with mode `0440`. Add the copy step to `laranode-scripts/bin/laranode-installer.sh` (see Step 7 below).

- [ ] **Step 3: Write service tests (these will be used in Step 5 after the services exist)**

```php
<?php // tests/Feature/CronJobs/StoreCronJobTest.php

use App\Models\CronJob;
use App\Models\User;
use App\Services\CronJobs\CreateCronJobService;
use App\Services\CronJobs\CreateCronJobException;
use App\Services\CronJobs\DeleteCronJobService;
use Illuminate\Support\Facades\Process;

test('CreateCronJobService calls laranode-cron.sh set with all active jobs', function () {
    Process::fake(['*laranode-cron.sh*' => Process::result(exitCode: 0)]);

    $user = User::factory()->create(['username' => 'alice']);
    $job  = CronJob::create([
        'user_id'  => $user->id,
        'schedule' => '0 2 * * *',
        'command'  => 'php /home/alice_ln/app/artisan schedule:run',
    ]);

    (new CreateCronJobService($job, $user))->handle();

    Process::assertRan(fn ($p) => str_contains(implode(' ', $p->command()), 'laranode-cron.sh')
        && in_array('set', $p->command())
        && in_array('alice_ln', $p->command())
    );
});

test('CreateCronJobService throws CreateCronJobException on non-zero exit', function () {
    Process::fake(['*laranode-cron.sh*' => Process::result(exitCode: 1, errorOutput: 'crontab: permission denied')]);

    $user = User::factory()->create(['username' => 'bob']);
    $job  = CronJob::create([
        'user_id'  => $user->id,
        'schedule' => '* * * * *',
        'command'  => 'curl https://example.com',
    ]);

    expect(fn () => (new CreateCronJobService($job, $user))->handle())
        ->toThrow(CreateCronJobException::class);
});

test('DeleteCronJobService deletes the DB row then re-syncs remaining jobs', function () {
    Process::fake(['*laranode-cron.sh*' => Process::result(exitCode: 0)]);

    $user = User::factory()->create(['username' => 'carol']);
    $jobA = CronJob::create(['user_id' => $user->id, 'schedule' => '* * * * *', 'command' => 'curl https://a.test']);
    $jobB = CronJob::create(['user_id' => $user->id, 'schedule' => '0 3 * * *', 'command' => 'curl https://b.test']);

    (new DeleteCronJobService($jobA, $user))->handle();

    expect(CronJob::where('id', $jobA->id)->exists())->toBeFalse()
        ->and(CronJob::where('id', $jobB->id)->exists())->toBeTrue();

    Process::assertRan(fn ($p) => str_contains(implode(' ', $p->command()), 'laranode-cron.sh'));
});
```

- [ ] **Step 4: Run the service tests; verify they fail**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=StoreCronJobTest'`
Expected: FAIL — `Class "App\Services\CronJobs\CreateCronJobService" not found`.

- [ ] **Step 5: Write `CreateCronJobService`**

```php
<?php // app/Services/CronJobs/CreateCronJobService.php

namespace App\Services\CronJobs;

use App\Models\CronJob;
use App\Models\User;
use Exception;
use Illuminate\Support\Facades\Process;

class CreateCronJobException extends Exception {}

class CreateCronJobService
{
    public function __construct(private CronJob $cronJob, private User $user) {}

    public function handle(): void
    {
        $tmpFile = $this->writeTmpFile();

        try {
            $result = Process::run([
                'sudo',
                config('laranode.laranode_bin_path') . '/laranode-cron.sh',
                'set',
                $this->user->systemUsername,
                $tmpFile,
            ]);

            if ($result->failed()) {
                throw new CreateCronJobException(
                    'laranode-cron.sh set failed: ' . $result->errorOutput()
                );
            }
        } finally {
            @unlink($tmpFile);
        }
    }

    private function writeTmpFile(): string
    {
        $activeJobs = CronJob::where('user_id', $this->user->id)
            ->where('active', true)
            ->get();

        $lines = $activeJobs->map(fn ($j) => $j->schedule . "\t" . $j->command)->implode("\n");
        $path  = sys_get_temp_dir() . '/laranode-cron-' . $this->user->systemUsername . '-' . uniqid() . '.txt';
        file_put_contents($path, $lines);
        chmod($path, 0600);

        return $path;
    }
}
```

- [ ] **Step 6: Write `DeleteCronJobService`**

```php
<?php // app/Services/CronJobs/DeleteCronJobService.php

namespace App\Services\CronJobs;

use App\Models\CronJob;
use App\Models\User;
use Exception;
use Illuminate\Support\Facades\Process;

class DeleteCronJobException extends Exception {}

class DeleteCronJobService
{
    public function __construct(private CronJob $cronJob, private User $user) {}

    public function handle(): void
    {
        // Delete DB row first; the rebuild will exclude it.
        $this->cronJob->delete();

        $tmpFile = $this->writeTmpFile();

        try {
            $result = Process::run([
                'sudo',
                config('laranode.laranode_bin_path') . '/laranode-cron.sh',
                'set',
                $this->user->systemUsername,
                $tmpFile,
            ]);

            if ($result->failed()) {
                throw new DeleteCronJobException(
                    'laranode-cron.sh set failed after delete: ' . $result->errorOutput()
                );
            }
        } finally {
            @unlink($tmpFile);
        }
    }

    private function writeTmpFile(): string
    {
        $activeJobs = CronJob::where('user_id', $this->user->id)
            ->where('active', true)
            ->get();

        $lines = $activeJobs->map(fn ($j) => $j->schedule . "\t" . $j->command)->implode("\n");
        $path  = sys_get_temp_dir() . '/laranode-cron-' . $this->user->systemUsername . '-' . uniqid() . '.txt';
        file_put_contents($path, $lines);
        chmod($path, 0600);

        return $path;
    }
}
```

- [ ] **Step 7: Add the sudoers copy step to `laranode-installer.sh`**

Locate the section in `laranode-scripts/bin/laranode-installer.sh` that copies sudoers drop-ins (search for `/etc/sudoers.d/`). After the last such line, add:

```bash
cp "${SCRIPT_DIR}/../etc/sudoers.d/laranode-cron" /etc/sudoers.d/laranode-cron
chmod 0440 /etc/sudoers.d/laranode-cron
```

- [ ] **Step 8: Run the service tests; verify they pass**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=StoreCronJobTest'`
Expected: PASS (3 tests).

- [ ] **Step 9: Commit**

```bash
git add laranode-scripts/bin/laranode-cron.sh etc/sudoers.d/laranode-cron app/Services/CronJobs/CreateCronJobService.php app/Services/CronJobs/DeleteCronJobService.php laranode-scripts/bin/laranode-installer.sh tests/Feature/CronJobs/StoreCronJobTest.php
git commit -m "feat(cron): laranode-cron.sh + sudoers drop-in + Create/DeleteCronJobService"
```

---

### Task 5: `CronJobsController` + routes + HTTP feature tests

**TDD: yes — write HTTP tests before the controller body.**

**Files:**
- Create: `app/Http/Controllers/CronJobsController.php`
- Modify: `routes/web.php` (add cron-jobs resource + toggle route)
- Create: `tests/Feature/CronJobs/CronJobControllerTest.php`

**Interfaces:**
- `index` → Inertia `CronJobs/Index` with `cronJobs` prop (paginated or collection).
- `store` → creates `CronJob` row + `Operation` row (type `cron.create`) + calls `CreateCronJobService` + flash success/error + redirect.
- `destroy` → `Gate::authorize('delete', $cronJob)` + calls `DeleteCronJobService` + `Operation` row (type `cron.delete`) + flash + redirect.
- `toggleActive` → `Gate::authorize('update', $cronJob)` + flips `active` + re-syncs via `CreateCronJobService` (passing the toggled job's user) + `Operation` row (type `cron.toggle`) + flash + redirect.
- Routes: `Route::resource('/cron-jobs', CronJobsController::class)->except(['create','edit','show'])` + `Route::post('/cron-jobs/{cronJob}/toggle', [..., 'toggleActive'])->name('cron-jobs.toggle')`.

- [ ] **Step 1: Write the failing HTTP tests**

```php
<?php // tests/Feature/CronJobs/CronJobControllerTest.php

use App\Models\CronJob;
use App\Models\Operation;
use App\Models\User;
use Illuminate\Support\Facades\Process;

test('index renders the CronJobs/Index Inertia page', function () {
    $user = User::factory()->isNotAdmin()->create();
    CronJob::create(['user_id' => $user->id, 'schedule' => '* * * * *', 'command' => 'curl https://example.com']);

    $this->actingAs($user)
        ->get(route('cron-jobs.index'))
        ->assertOk()
        ->assertInertia(fn ($page) => $page->component('CronJobs/Index')->has('cronJobs'));
});

test('store creates a cron job row and an Operation row with type cron.create', function () {
    Process::fake(['*laranode-cron.sh*' => Process::result(exitCode: 0)]);
    $user = User::factory()->create(['username' => 'dave']);

    $this->actingAs($user)
        ->post(route('cron-jobs.store'), [
            'schedule' => '0 4 * * *',
            'command'  => 'php /home/dave_ln/app/artisan queue:work --stop-when-empty',
            'label'    => 'Queue flush',
        ])
        ->assertRedirect(route('cron-jobs.index'));

    expect(CronJob::where('user_id', $user->id)->count())->toBe(1);
    expect(Operation::where('user_id', $user->id)->where('type', 'cron.create')->count())->toBe(1);
    $op = Operation::where('user_id', $user->id)->where('type', 'cron.create')->first();
    expect($op->status)->toBe('succeeded');
});

test('store returns 422 for an invalid cron expression', function () {
    $user = User::factory()->create(['username' => 'eve']);

    $this->actingAs($user)
        ->post(route('cron-jobs.store'), [
            'schedule' => 'not a cron',
            'command'  => 'curl https://example.com',
        ])
        ->assertSessionHasErrors('schedule');
});

test('store returns 422 for a disallowed command', function () {
    $user = User::factory()->create(['username' => 'frank']);

    $this->actingAs($user)
        ->post(route('cron-jobs.store'), [
            'schedule' => '* * * * *',
            'command'  => 'rm -rf /',
        ])
        ->assertSessionHasErrors('command');
});

test('store creates a failed Operation row when the script exits non-zero', function () {
    Process::fake(['*laranode-cron.sh*' => Process::result(exitCode: 1, errorOutput: 'permission denied')]);
    $user = User::factory()->create(['username' => 'grace']);

    $this->actingAs($user)
        ->post(route('cron-jobs.store'), [
            'schedule' => '* * * * *',
            'command'  => 'curl https://example.com',
        ])
        ->assertRedirect();

    $op = Operation::where('user_id', $user->id)->where('type', 'cron.create')->first();
    expect($op->status)->toBe('failed');
});

test('destroy deletes the cron job and creates an Operation row with type cron.delete', function () {
    Process::fake(['*laranode-cron.sh*' => Process::result(exitCode: 0)]);
    $user = User::factory()->create(['username' => 'hana']);
    $job  = CronJob::create(['user_id' => $user->id, 'schedule' => '* * * * *', 'command' => 'curl https://h.test']);

    $this->actingAs($user)
        ->delete(route('cron-jobs.destroy', $job))
        ->assertRedirect(route('cron-jobs.index'));

    expect(CronJob::find($job->id))->toBeNull();
    $op = Operation::where('user_id', $user->id)->where('type', 'cron.delete')->first();
    expect($op->status)->toBe('succeeded');
});

test('destroy returns 403 when a non-owner tries to delete another users job', function () {
    $owner = User::factory()->isNotAdmin()->create();
    $other = User::factory()->isNotAdmin()->create();
    $job   = CronJob::create(['user_id' => $owner->id, 'schedule' => '* * * * *', 'command' => 'curl https://o.test']);

    $this->actingAs($other)
        ->delete(route('cron-jobs.destroy', $job))
        ->assertForbidden();
});

test('toggleActive flips active flag and creates an Operation row with type cron.toggle', function () {
    Process::fake(['*laranode-cron.sh*' => Process::result(exitCode: 0)]);
    $user = User::factory()->create(['username' => 'ivan']);
    $job  = CronJob::create(['user_id' => $user->id, 'schedule' => '* * * * *', 'command' => 'curl https://i.test', 'active' => true]);

    $this->actingAs($user)
        ->post(route('cron-jobs.toggle', $job))
        ->assertRedirect(route('cron-jobs.index'));

    expect($job->fresh()->active)->toBeFalse();
    $op = Operation::where('user_id', $user->id)->where('type', 'cron.toggle')->first();
    expect($op->status)->toBe('succeeded');
});
```

- [ ] **Step 2: Run them; verify they fail**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=CronJobControllerTest'`
Expected: FAIL — route `cron-jobs.index` not defined.

- [ ] **Step 3: Add the routes to `routes/web.php`**

After the Operations audit route (line ~81 in current `routes/web.php`), add:

```php
// Cron Jobs [Admin | User]
Route::resource('/cron-jobs', \App\Http\Controllers\CronJobsController::class)
    ->middleware(['auth'])
    ->except(['create', 'edit', 'show']);
Route::post('/cron-jobs/{cronJob}/toggle', [\App\Http\Controllers\CronJobsController::class, 'toggleActive'])
    ->middleware(['auth'])
    ->name('cron-jobs.toggle');
```

- [ ] **Step 4: Write `CronJobsController`**

```php
<?php // app/Http/Controllers/CronJobsController.php

namespace App\Http\Controllers;

use App\Http\Requests\StoreCronJobRequest;
use App\Models\CronJob;
use App\Models\Operation;
use App\Services\CronJobs\CreateCronJobException;
use App\Services\CronJobs\CreateCronJobService;
use App\Services\CronJobs\DeleteCronJobException;
use App\Services\CronJobs\DeleteCronJobService;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Gate;
use Inertia\Inertia;
use Inertia\Response;

class CronJobsController extends Controller
{
    public function index(Request $request): Response
    {
        $cronJobs = CronJob::mine()
            ->where('user_id', $request->user()->id)
            ->orderBy('id')
            ->get();

        return Inertia::render('CronJobs/Index', ['cronJobs' => $cronJobs]);
    }

    public function store(StoreCronJobRequest $request): RedirectResponse
    {
        $user   = $request->user();
        $cronJob = CronJob::create([
            'user_id'  => $user->id,
            'schedule' => $request->validated('schedule'),
            'command'  => $request->validated('command'),
            'label'    => $request->validated('label'),
            'active'   => true,
        ]);

        $op = Operation::create([
            'user_id' => $user->id,
            'type'    => 'cron.create',
            'target'  => $user->systemUsername,
            'status'  => 'queued',
        ]);
        $op->markRunning();

        try {
            (new CreateCronJobService($cronJob, $user))->handle();
            $op->appendOutput("Cron job created: {$cronJob->schedule} {$cronJob->command}");
            $op->markFinished(0);
            session()->flash('success', 'Cron job created successfully.');
        } catch (CreateCronJobException $e) {
            $cronJob->delete();
            $op->appendOutput('ERROR: ' . $e->getMessage());
            $op->markFinished(1);
            session()->flash('error', 'Failed to create cron job: ' . $e->getMessage());
        }

        return redirect()->route('cron-jobs.index');
    }

    public function destroy(Request $request, CronJob $cronJob): RedirectResponse
    {
        Gate::authorize('delete', $cronJob);
        $user = $request->user();

        $op = Operation::create([
            'user_id' => $user->id,
            'type'    => 'cron.delete',
            'target'  => $user->systemUsername,
            'status'  => 'queued',
        ]);
        $op->markRunning();

        try {
            (new DeleteCronJobService($cronJob, $user))->handle();
            $op->appendOutput("Cron job deleted: {$cronJob->schedule} {$cronJob->command}");
            $op->markFinished(0);
            session()->flash('success', 'Cron job deleted successfully.');
        } catch (DeleteCronJobException $e) {
            $op->appendOutput('ERROR: ' . $e->getMessage());
            $op->markFinished(1);
            session()->flash('error', 'Failed to delete cron job: ' . $e->getMessage());
        }

        return redirect()->route('cron-jobs.index');
    }

    public function toggleActive(Request $request, CronJob $cronJob): RedirectResponse
    {
        Gate::authorize('update', $cronJob);
        $user = $request->user();

        $cronJob->update(['active' => ! $cronJob->active]);

        $op = Operation::create([
            'user_id' => $user->id,
            'type'    => 'cron.toggle',
            'target'  => $user->systemUsername,
            'status'  => 'queued',
        ]);
        $op->markRunning();

        try {
            // Re-sync the full crontab with the updated active state
            (new CreateCronJobService($cronJob, $user))->handle();
            $op->appendOutput("Cron job toggled active={$cronJob->active}: {$cronJob->command}");
            $op->markFinished(0);
            session()->flash('success', 'Cron job updated successfully.');
        } catch (CreateCronJobException $e) {
            // Revert the toggle in DB if sync fails
            $cronJob->update(['active' => ! $cronJob->active]);
            $op->appendOutput('ERROR: ' . $e->getMessage());
            $op->markFinished(1);
            session()->flash('error', 'Failed to toggle cron job: ' . $e->getMessage());
        }

        return redirect()->route('cron-jobs.index');
    }
}
```

Note: the `index` action uses `scopeMine()` which already scopes to `user_id` for non-admins, but also adds an explicit `where('user_id', ...)` so admins viewing via impersonation see only the impersonated user's jobs in the UI (the audit page `/admin/operations` is where admins see all).

- [ ] **Step 5: Run the HTTP tests; verify they pass**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test --filter=CronJobControllerTest'`
Expected: PASS (8 tests).

- [ ] **Step 6: Run Pint; fix any style issues**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && ./vendor/bin/pint app/Http/Controllers/CronJobsController.php app/Services/CronJobs/'`
Expected: no changes, or auto-fixed (re-run to confirm clean).

- [ ] **Step 7: Commit**

```bash
git add app/Http/Controllers/CronJobsController.php routes/web.php tests/Feature/CronJobs/CronJobControllerTest.php
git commit -m "feat(cron): CronJobsController (index/store/destroy/toggleActive) + routes"
```

---

### Task 6: React UI — `CronJobs/Index.jsx` + `CreateCronJobForm.jsx` + nav link + Vitest

**Files:**
- Create: `resources/js/Pages/CronJobs/Index.jsx`
- Create: `resources/js/Pages/CronJobs/Partials/CreateCronJobForm.jsx`
- Modify: `resources/js/Layouts/Partials/SidebarNavi.jsx` (add Cron Jobs nav link)
- Create: `resources/js/Pages/CronJobs/CronJobs.test.jsx` (Vitest)

**Interfaces:**
- `Index.jsx` receives `cronJobs` prop (array from Inertia). Renders a table with columns: schedule, command, label, active toggle, delete. Inline form at top (or below table) for adding new job — delegates to `CreateCronJobForm`.
- `CreateCronJobForm.jsx` — preset `<select>` for common schedules (`@hourly`, `@daily`, `@weekly`, `@monthly`, custom), a text input for custom expression when "custom" selected, a text input for command, a text input for label. Submits via `router.post(route('cron-jobs.store'), {...})`.
- Nav link in `SidebarNavi.jsx` — visible to all authenticated users (not admin-only). Place it between MySQL DBs and File Manager, or after MySQL DBs.

- [ ] **Step 1: Write the Vitest test first (failing)**

```jsx
// resources/js/Pages/CronJobs/CronJobs.test.jsx
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { test, expect, vi, beforeEach } from 'vitest';

vi.mock('@inertiajs/react', () => ({
    usePage: () => ({ props: { auth: { user: { id: 1 } } } }),
    router: { post: vi.fn() },
    Link: ({ href, children }) => <a href={href}>{children}</a>,
    Head: ({ title }) => <title>{title}</title>,
}));

vi.mock('@/Layouts/AuthenticatedLayout', () => ({
    default: ({ children }) => <div>{children}</div>,
}));

// route() helper used in JSX
global.route = vi.fn((name) => `/${name}`);

import Index from '@/Pages/CronJobs/Index';
import { router } from '@inertiajs/react';

const fakeCronJobs = [
    { id: 1, schedule: '0 2 * * *', command: 'curl https://example.com', label: 'Nightly ping', active: true },
];

test('renders cron job rows and the add form', () => {
    render(<Index cronJobs={fakeCronJobs} />);
    expect(screen.getByText('0 2 * * *')).toBeInTheDocument();
    expect(screen.getByText('Nightly ping')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /add cron job/i })).toBeInTheDocument();
});

test('submitting the form calls router.post with the correct data', async () => {
    const user = userEvent.setup();
    render(<Index cronJobs={[]} />);

    // Fill in the form fields
    const commandInput = screen.getByPlaceholderText(/command/i);
    await user.type(commandInput, 'curl https://test.test');

    const submitBtn = screen.getByRole('button', { name: /add cron job/i });
    await user.click(submitBtn);

    expect(router.post).toHaveBeenCalledWith(
        expect.stringContaining('cron-jobs.store'),
        expect.objectContaining({ command: 'curl https://test.test' }),
    );
});
```

- [ ] **Step 2: Run the test; verify it fails**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && npm run test -- --reporter=verbose'`
Expected: FAIL — `Cannot find module '@/Pages/CronJobs/Index'`.

- [ ] **Step 3: Write `CreateCronJobForm.jsx`**

```jsx
// resources/js/Pages/CronJobs/Partials/CreateCronJobForm.jsx
import { useState } from 'react';
import { router } from '@inertiajs/react';

const PRESETS = [
    { label: 'Every minute',  value: '* * * * *' },
    { label: 'Hourly',        value: '0 * * * *' },
    { label: 'Daily (2am)',   value: '0 2 * * *' },
    { label: 'Weekly (Mon)',  value: '0 0 * * 1' },
    { label: 'Monthly (1st)',  value: '0 0 1 * *' },
    { label: 'Custom…',       value: '__custom__' },
];

export default function CreateCronJobForm() {
    const [preset, setPreset]   = useState(PRESETS[2].value);
    const [custom, setCustom]   = useState('');
    const [command, setCommand] = useState('');
    const [label, setLabel]     = useState('');

    const schedule = preset === '__custom__' ? custom : preset;

    const submit = (e) => {
        e.preventDefault();
        router.post(route('cron-jobs.store'), { schedule, command, label });
    };

    return (
        <form onSubmit={submit} className="flex flex-col gap-3 p-4 border rounded bg-white dark:bg-gray-800 mb-4">
            <h2 className="text-sm font-semibold">Add Cron Job</h2>
            <div className="flex gap-2 flex-wrap">
                <select
                    value={preset}
                    onChange={(e) => setPreset(e.target.value)}
                    className="border rounded px-2 py-1 text-sm dark:bg-gray-700"
                >
                    {PRESETS.map((p) => (
                        <option key={p.value} value={p.value}>{p.label}</option>
                    ))}
                </select>
                {preset === '__custom__' && (
                    <input
                        type="text"
                        value={custom}
                        onChange={(e) => setCustom(e.target.value)}
                        placeholder="* * * * *"
                        className="border rounded px-2 py-1 text-sm font-mono dark:bg-gray-700"
                    />
                )}
                <input
                    type="text"
                    value={command}
                    onChange={(e) => setCommand(e.target.value)}
                    placeholder="Command (php /home/…/artisan …)"
                    className="border rounded px-2 py-1 text-sm flex-1 min-w-48 dark:bg-gray-700"
                />
                <input
                    type="text"
                    value={label}
                    onChange={(e) => setLabel(e.target.value)}
                    placeholder="Label (optional)"
                    className="border rounded px-2 py-1 text-sm dark:bg-gray-700"
                />
                <button type="submit" className="bg-indigo-600 text-white px-3 py-1 rounded text-sm hover:bg-indigo-700">
                    Add Cron Job
                </button>
            </div>
        </form>
    );
}
```

- [ ] **Step 4: Write `CronJobs/Index.jsx`**

```jsx
// resources/js/Pages/CronJobs/Index.jsx
import AuthenticatedLayout from '@/Layouts/AuthenticatedLayout';
import { Head, router } from '@inertiajs/react';
import CreateCronJobForm from './Partials/CreateCronJobForm';

export default function Index({ cronJobs }) {
    const handleToggle = (job) => {
        router.post(route('cron-jobs.toggle', { cronJob: job.id }), {}, { preserveScroll: true });
    };

    const handleDelete = (job) => {
        if (! confirm(`Delete cron job: ${job.command}?`)) return;
        router.delete(route('cron-jobs.destroy', { cronJob: job.id }), { preserveScroll: true });
    };

    return (
        <AuthenticatedLayout>
            <Head title="Cron Jobs" />
            <div className="p-6">
                <h1 className="text-xl font-semibold mb-4">Cron Jobs</h1>
                <CreateCronJobForm />
                <table className="w-full text-sm border-collapse">
                    <thead>
                        <tr className="text-left border-b dark:border-gray-700">
                            <th className="py-2 pr-4">Schedule</th>
                            <th className="py-2 pr-4">Command</th>
                            <th className="py-2 pr-4">Label</th>
                            <th className="py-2 pr-4">Active</th>
                            <th className="py-2"></th>
                        </tr>
                    </thead>
                    <tbody>
                        {cronJobs.map((job) => (
                            <tr key={job.id} className="border-b dark:border-gray-700 align-middle">
                                <td className="py-2 pr-4 font-mono text-xs">{job.schedule}</td>
                                <td className="py-2 pr-4 font-mono text-xs break-all">{job.command}</td>
                                <td className="py-2 pr-4 text-gray-500 dark:text-gray-400">{job.label ?? '—'}</td>
                                <td className="py-2 pr-4">
                                    <button
                                        onClick={() => handleToggle(job)}
                                        className={`text-xs px-2 py-1 rounded ${job.active ? 'bg-green-200 text-green-800' : 'bg-gray-200 text-gray-600'}`}
                                    >
                                        {job.active ? 'Active' : 'Paused'}
                                    </button>
                                </td>
                                <td className="py-2">
                                    <button
                                        onClick={() => handleDelete(job)}
                                        className="text-xs px-2 py-1 rounded bg-red-100 text-red-700 hover:bg-red-200"
                                    >
                                        Delete
                                    </button>
                                </td>
                            </tr>
                        ))}
                        {cronJobs.length === 0 && (
                            <tr>
                                <td colSpan={5} className="py-4 text-center text-gray-400">No cron jobs yet.</td>
                            </tr>
                        )}
                    </tbody>
                </table>
            </div>
        </AuthenticatedLayout>
    );
}
```

- [ ] **Step 5: Add the nav link to `SidebarNavi.jsx`**

In `resources/js/Layouts/Partials/SidebarNavi.jsx`, add the import at the top (already has react-icons imports — add `MdSchedule` or `MdOutlineSchedule` from `react-icons/md` which is already imported in the file, or reuse a suitable icon). Add the nav `<li>` after the MySQL DBs entry (around line 121 in the current file):

```jsx
import { MdSchedule } from 'react-icons/md'; // add to existing md import line

// Inside the <ul>, after the MySQL DBs <li>:
<li>
    <Link
        href={route('cron-jobs.index')}
        className="relative flex flex-row items-center h-11 focus:outline-none hover:bg-gray-900 text-gray-300 border-l-4 border-transparent hover:border-indigo-900 pr-6"
    >
        <div>
            <MdSchedule className="ml-3 w-5 h-5" />
        </div>
        <span className="ml-2 text-sm tracking-wide truncate">Cron Jobs</span>
    </Link>
</li>
```

Since `react-icons/md` is already imported, extend the existing import: `import { MdSecurity, MdOutlineListAlt, MdSchedule } from "react-icons/md";`

- [ ] **Step 6: Run the Vitest tests; verify they pass**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && npm run test'`
Expected: all Vitest tests pass including the 2 new `CronJobs.test.jsx` tests.

- [ ] **Step 7: Build assets; verify no import errors**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && npm run build'`
Expected: build succeeds, no errors.

- [ ] **Step 8: Commit**

```bash
git add resources/js/Pages/CronJobs/ resources/js/Layouts/Partials/SidebarNavi.jsx resources/js/Pages/CronJobs/CronJobs.test.jsx
git commit -m "feat(cron): CronJobs UI (Index + CreateCronJobForm) + nav link + Vitest tests"
```

---

### Task 7: System test (LARANODE_SYSTEM_TESTS=1) + final verification gate

**This task is non-TDD; it runs the real `laranode-cron.sh` inside the container.**

**Files:**
- Create: `tests/Feature/CronJobs/CronJobSystemTest.php`

**Interfaces:**
- Exercises the real `laranode-cron.sh` against the container's crontab. Gated behind `LARANODE_SYSTEM_TESTS=1`. Not run in the standard CI suite.

- [ ] **Step 1: Write the system test**

```php
<?php // tests/Feature/CronJobs/CronJobSystemTest.php

use App\Models\CronJob;
use App\Models\User;
use App\Services\CronJobs\CreateCronJobService;
use App\Services\CronJobs\DeleteCronJobService;

// Only run on a real Linux host with the laranode-cron.sh installed and sudoers configured.
test('creates a cron entry in the real crontab', function () {
    if (! env('LARANODE_SYSTEM_TESTS')) {
        $this->markTestSkipped('LARANODE_SYSTEM_TESTS not set.');
    }

    // This test requires a real {username}_ln Linux account in the container.
    // The local-dev container creates testuser_ln via the provisioning entrypoint.
    $user = User::factory()->create(['username' => 'testuser']);
    $job  = CronJob::create([
        'user_id'  => $user->id,
        'schedule' => '0 3 * * *',
        'command'  => 'curl https://example.com/cron-test',
    ]);

    (new CreateCronJobService($job, $user))->handle();

    $crontab = shell_exec("crontab -l -u testuser_ln 2>/dev/null");
    expect($crontab)->toContain('curl https://example.com/cron-test')
        ->and($crontab)->toContain('# laranode-managed');
});

test('removes the cron entry from the real crontab on delete', function () {
    if (! env('LARANODE_SYSTEM_TESTS')) {
        $this->markTestSkipped('LARANODE_SYSTEM_TESTS not set.');
    }

    $user = User::factory()->create(['username' => 'testuser2']);
    $job  = CronJob::create([
        'user_id'  => $user->id,
        'schedule' => '*/5 * * * *',
        'command'  => 'curl https://example.com/cron-delete-test',
    ]);

    (new CreateCronJobService($job, $user))->handle();

    // Verify added
    $before = shell_exec("crontab -l -u testuser2_ln 2>/dev/null");
    expect($before)->toContain('cron-delete-test');

    (new DeleteCronJobService($job, $user))->handle();

    $after = shell_exec("crontab -l -u testuser2_ln 2>/dev/null");
    expect($after ?? '')->not->toContain('cron-delete-test');
});
```

- [ ] **Step 2: Run the standard suite (without system tests) — must be fully green**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test'`
Expected: ALL tests pass. Zero failures. Zero skipped (other than the system tests, which are `markTestSkipped` by default).

- [ ] **Step 3: Run the system suite (with LARANODE_SYSTEM_TESTS=1) inside the container**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && LARANODE_SYSTEM_TESTS=1 php artisan test --filter=CronJobSystemTest'`
Expected: PASS (2 tests). If `testuser_ln` accounts don't exist in the container, the provisioning `entrypoint.sh` must create them first — or adjust the system test to use the existing `alice_ln` / admin account that the container seeds.
Also verify via direct shell: `docker exec laranode-lab bash -lc 'crontab -l -u testuser_ln'` shows the managed entry after the create test ran.

- [ ] **Step 4: Run Pint on all new PHP files**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && ./vendor/bin/pint app/Models/CronJob.php app/Services/CronJobs/ app/Rules/ app/Http/Controllers/CronJobsController.php app/Http/Requests/StoreCronJobRequest.php app/Policies/CronJobPolicy.php tests/Feature/CronJobs/ tests/Unit/'`
Expected: no changes required (clean). If any are auto-fixed, stage and commit them.

- [ ] **Step 5: Run Vitest once more for final confirmation**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && npm run test'`
Expected: all Vitest tests pass.

- [ ] **Step 6: `schedule:list` check — confirm no regression to the existing prune schedule**

Run: `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan schedule:list'`
Expected: the `model:prune --model=App\Models\Operation` daily entry is still listed (from `bootstrap/app.php`). No new schedule entries needed for cron-tasks.

- [ ] **Step 7: Manual browser check (optional but recommended)**

In the running container's panel (`http://localhost` with admin or a regular user):
1. Navigate to "Cron Jobs" in the sidebar — page renders with empty table.
2. Add a cron job using the preset dropdown (e.g., Daily) + a valid command — flash success appears.
3. Check `/admin/operations` — the `cron.create` row appears with status `succeeded`.
4. Toggle the job to Paused — status column shows Paused, `cron.toggle` Operation created.
5. Delete the job — row gone, `cron.delete` Operation visible in `/admin/operations`.
6. Attempt to add a job with an invalid command (`rm -rf /`) — inline validation error shown, no DB row created.

- [ ] **Step 8: Commit**

```bash
git add tests/Feature/CronJobs/CronJobSystemTest.php
git commit -m "test(cron): system test for real crontab create/delete (LARANODE_SYSTEM_TESTS=1)"
```

---

## Back-compat / Migration Notes

- **`back-compat` flag:** No existing models (`User`, `Website`, `Database`, `Operation`) are changed. The new `cron_jobs` table is additive only.
- **`Operation` rows with `type=cron.*`** are new and render automatically in the existing `/admin/operations` page via the generic table — no code change needed there.
- **`bootstrap/app.php` scheduler hook** is already in place from `feature/platform-async-progress` — no change needed.
- **Existing crontabs** for `{username}_ln` that were set manually before this feature are preserved: `laranode-cron.sh` only touches lines tagged `# laranode-managed`.
- **Migration is additive** — the new `create_cron_jobs_table` migration poses no back-compat risk to existing tables.

---

## Self-Review

**Spec coverage:**
- `cron_jobs` table + `CronJob` model (scopeMine, active cast, belongsTo) → Task 1 ✓
- `ValidCronExpression` rule (5 fields, range checks) → Task 2 ✓
- `AllowedCronCommand` rule (metachar blocklist, homedir path confinement, prefix allowlist) → Task 2 ✓
- `StoreCronJobRequest` (schedule, command, label) → Task 3 ✓
- `CronJobPolicy` (mirrors WebsitePolicy, admin passes all) → Task 3 ✓
- `laranode-cron.sh` (set/remove/list, `# laranode-managed` marker, full rebuild, temp file) → Task 4 ✓
- `etc/sudoers.d/laranode-cron` drop-in + installer copy step → Task 4 ✓
- `CreateCronJobService` (Process::run + temp file + CreateCronJobException) → Task 4 ✓
- `DeleteCronJobService` (delete row first then rebuild + DeleteCronJobException) → Task 4 ✓
- `CronJobsController` (index/store/destroy/toggleActive + inline Operation lifecycle) → Task 5 ✓
- Routes (`cron-jobs.*` resource + toggle) → Task 5 ✓
- React `CronJobs/Index.jsx` + `CreateCronJobForm.jsx` → Task 6 ✓
- Nav link in `SidebarNavi.jsx` (visible to all auth'd users) → Task 6 ✓
- Vitest component tests for Index + form → Task 6 ✓
- System test (real crontab, `LARANODE_SYSTEM_TESTS=1`) → Task 7 ✓
- `Operation` rows for all mutations (type `cron.create|cron.delete|cron.toggle`, status `succeeded|failed`) → Task 5 (controller drives lifecycle inline) ✓
- Error handling: script failure → `failed` Operation + flash.error + DB rollback → Task 5 ✓
- Pint clean + Vitest green + Pest green as final gate → Task 7 ✓

**Placeholder scan:** No TBD or TODO. Every step has a concrete command with expected output.

**Type/contract consistency:** `CronJob.$fillable` consistent between migration (Task 1) and service queries (Task 4). `Operation` type literals `cron.create|cron.delete|cron.toggle` consistent between controller (Task 5) and tests (Task 5). `AllowedCronCommand($user)` receives a `User` model with `systemUsername` accessor — the accessor pattern is established in the codebase and is not a new dependency.
