# Sub-project #1 — Async job + live-progress + audit foundation (`platform-async-progress`)

- **Date:** 2026-06-25
- **Status:** Approved design (ready for writing-plans)
- **Roadmap:** Phase 0, sub-project #1 of `docs/superpowers/specs/2026-06-25-laranode-feature-roadmap.md`
- **Branch:** `feature/platform-async-progress` (off `development`)

## Goal

Establish the reusable platform primitive every later feature needs: run a long operation on the **queue**, stream its **live output** to the triggering user over Reverb, record it in an **`operations` audit table**, and add the **scheduler hook**. Prove it by converting SSL generation to async with a live cert-issuance log.

**Why first:** every requested feature (git deploy, fail2ban scans, multi-engine installs, DB dumps) is long-running and will time out in a synchronous HTTP request. Queue worker + Reverb already run idle — this wires a convention, not new infra.

## Success criteria

- Triggering SSL generate returns immediately; the certbot run executes on the queue.
- The user sees streamed output lines live in the UI (no polling), ending in succeeded/failed; `ssl_status` is still updated correctly at the end.
- Every async operation creates an `operations` row capturing actor, type, target, status lifecycle, buffered output, exit code, timings.
- An admin page lists recent operations with expandable output.
- `bootstrap/app.php` has a `withSchedule` hook (previously absent) and old operations are pruned.
- Feature tests (queue `sync`, faked events/process) prove the lifecycle + the SSL path; run green in the `local-dev` container.

## Architecture

Pattern stays **Controller → (create Operation row) → dispatch queued Job → Job runs work via an `$emit` line callback → each line appended to the row + broadcast on the user's private channel**. Streaming uses Laravel's `Process::run($cmd, fn($type, $line) => …)` real-time output callback (not polling). Reuses the existing database queue worker + Reverb server.

### Components

**1. `operations` table + `Operation` model**
Migration `create_operations_table`:
- `id`, `user_id` (FK users, the actor), `type` (string, e.g. `ssl.generate`), `target` (string, nullable — human label, e.g. the domain), `status` (string: `queued|running|succeeded|failed`, default `queued`), `output` (longText, nullable), `exit_code` (integer, nullable), `started_at` (timestamp, nullable), `finished_at` (timestamp, nullable), `timestamps`.
`Operation` model:
- `$fillable` for the above; `belongsTo(User)`; `scopeMine()` (mirror Website/Database — non-admins see own); helper methods:
  - `markRunning(): void` — sets `status=running`, `started_at=now()`, saves, broadcasts a status event.
  - `appendOutput(string $line): void` — appends `$line."\n"` to `output`, saves, broadcasts a line event. (Saves per line; acceptable now — throttle only if proven chatty. YAGNI.)
  - `markFinished(int $exitCode): void` — sets `status` to `succeeded` (exit 0) or `failed`, `exit_code`, `finished_at=now()`, saves, broadcasts a status event.
  - `prunable()` — `where('created_at', '<', now()->subDays(30))` (Laravel `MassPrunable`).

**2. Broadcast event — `OperationUpdated implements ShouldBroadcast`**
Constructor `(public Operation $operation, public string $kind, public ?string $line = null)` where `kind ∈ {status, line}`.
- `broadcastOn(): PrivateChannel('operations.'.$this->operation->user_id)`
- `broadcastAs(): 'OperationUpdated'`
- `broadcastWith(): ['operationId' => id, 'kind' => kind, 'status' => operation.status, 'line' => line, 'exitCode' => operation.exit_code]`

**3. Channel auth — `routes/channels.php`**
```php
Broadcast::channel('operations.{userId}', function ($user, $userId) {
    return (int) $user->id === (int) $userId || $user->isAdmin();
});
```
(Admin may watch any user's ops — useful for the audit page live view; otherwise own only. Establishes the user-scoped pattern that today's admin-only stats channels lack.)

**4. Queued job convention — abstract `App\Jobs\OperationJob`**
```php
abstract class OperationJob implements ShouldQueue {
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;
    public function __construct(public Operation $operation) {}
    /** Do the work; call $emit($line) per output line; return the process exit code. */
    abstract protected function run(callable $emit): int;
    public function handle(): void {
        $this->operation->markRunning();
        try {
            $exit = $this->run(fn (string $line) => $this->operation->appendOutput($line));
            $this->operation->markFinished($exit);
        } catch (\Throwable $e) {
            $this->operation->appendOutput('ERROR: '.$e->getMessage());
            $this->operation->markFinished(1);
            throw $e; // let the failed_jobs table record it too
        }
    }
}
```
Each async feature subclasses this. `failed()` is naturally handled (markFinished already ran in catch before rethrow; the rethrow records to `failed_jobs`).

**5. SSL conversion (the proof) — `App\Jobs\GenerateSslOperationJob extends OperationJob`**
- Constructed with `(Operation $operation, Website $website, string $email)`.
- `run($emit)`: calls `(new GenerateWebsiteSslAction())->execute($website, $email, $emit)` and returns 0 on success (the action throws on failure → caught by base → failed). 
- **`GenerateWebsiteSslAction::execute(Website $website, string $email, ?callable $onOutput = null)`** — add the optional `$onOutput` param (backward compatible). Pass it to the certbot `Process::run([...], $onOutput ? fn ($type, $line) => $onOutput(rtrim($line, "\n")) : null)`. The existing status-update logic (pending → active/inactive, `ssl_expires_at`) is unchanged and runs at the end.
- **`WebsiteController@toggleSsl`** — for the `enabled` (generate) path: create `$operation = Operation::create(['user_id'=>$request->user()->id,'type'=>'ssl.generate','target'=>$website->url,'status'=>'queued'])`, then `GenerateSslOperationJob::dispatch($operation, $website, $request->user()->email)`, and return JSON `{ operation_id: $operation->id }` (matches the existing JSON style of `checkSslStatus`). The `disable`/remove path stays synchronous (it's fast) and returns its existing redirect/flash. (Note: the React SSL toggle must call this via axios and read `operation_id`; the spec includes that UI change.)

**6. React — reusable progress + the SSL wiring**
- `resources/js/hooks/useOperation.js` — `useOperation(operationId)`: subscribes to `Echo.private('operations.'+authUserId)` (auth user id from Inertia shared props), filters events by `operationId`, accumulates `lines`, tracks `status`; returns `{ status, lines, exitCode }`; unsubscribes on unmount/`operationId` change.
- `resources/js/Components/OperationProgress.jsx` — given `operationId`, renders a scrolling log (the accumulated lines) + a status badge (queued/running/succeeded/failed). Reusable by every future feature.
- Websites SSL toggle UI: on enabling SSL, POST via axios, take `operation_id`, render `<OperationProgress>` in a modal/inline; on `succeeded`, refresh the row's SSL status (reuse `checkSslStatus`).

**7. Admin audit page — `/admin/operations`**
- Route (auth + `AdminMiddleware`): `OperationsController@index` → `Inertia::render('Operations/Index', ['operations' => Operation::with('user')->latest()->paginate(30)])`.
- React `Pages/Operations/Index.jsx`: table (time, actor, type, target, status badge) with an expandable row showing buffered `output`. Read-only.

**8. Scheduler hook — `bootstrap/app.php`**
- Add `->withSchedule(function (\Illuminate\Console\Scheduling\Schedule $schedule) { $schedule->command('model:prune', ['--model' => [\App\Models\Operation::class]])->daily(); })`. Establishes the (currently absent) scheduler entrypoint that backups/renewals will extend. (Running the scheduler in prod = a `schedule:run` cron / systemd timer — note for the installer, but adding the cron entry is out of this sub-project's scope; the hook + prune definition are in scope.)

## Error handling

- Job failure: base `OperationJob` marks the row `failed` + appends the error line + rethrows so `failed_jobs` also records it. The user sees `failed` + the error line live.
- Certbot/script nonzero exit: `GenerateWebsiteSslAction` already throws on `$result->failed()`; that path now also reverts `ssl_enabled/ssl_status` (existing behavior) and surfaces as a failed operation.
- Channel auth denies other users' channels (own + admin only).
- If the queue worker is down (shouldn't be — systemd), operations sit `queued`; the UI shows `queued` until processed (honest, not a hang).

## Testing (Pest, in `local-dev` container; `QUEUE_CONNECTION=sync` so jobs run inline)

- `Operation` lifecycle: a dummy `OperationJob` subclass whose `run` emits two lines + returns 0 → row goes queued→running→succeeded, `output` has both lines, `started_at`/`finished_at` set, `exit_code=0`.
- Failure path: subclass whose `run` throws → row `failed`, error line in output, exit 1.
- Broadcast: `Event::fake()` → assert `OperationUpdated` dispatched for running + each line + finished, on `operations.{userId}`.
- Channel auth: user can authorize own channel, not another user's; admin can authorize any.
- SSL conversion: `Process::fake()` (success + failure), hit `toggleSsl` enabled → asserts an `operations` row (`type=ssl.generate`) created + `GenerateSslOperationJob` dispatched (`Queue::fake` or sync) + JSON `operation_id` returned; running it (sync) updates `ssl_status` as before. Disable path unchanged.
- Admin page: admin sees `/admin/operations`; non-admin forbidden.

## File inventory

```
database/migrations/XXXX_create_operations_table.php   (new)
app/Models/Operation.php                                (new)
app/Jobs/OperationJob.php                               (new, abstract base)
app/Jobs/GenerateSslOperationJob.php                    (new)
app/Events/OperationUpdated.php                         (new)
app/Http/Controllers/OperationsController.php           (new, admin audit page)
routes/channels.php                                     (modify: operations.{userId})
routes/web.php                                          (modify: /admin/operations route)
bootstrap/app.php                                       (modify: withSchedule + prune)
app/Actions/SSL/GenerateWebsiteSslAction.php            (modify: optional $onOutput callback)
app/Http/Controllers/WebsiteController.php              (modify: toggleSsl generate → async)
resources/js/hooks/useOperation.js                      (new)
resources/js/Components/OperationProgress.jsx           (new)
resources/js/Pages/Operations/Index.jsx                 (new, admin audit page)
resources/js/Pages/Websites/Index.jsx                   (modify: SSL toggle → progress UI)
tests/Feature/Operations/*                              (new)
```

## Out of scope (later sub-projects / deferred)

- Converting other ops (website create, etc.) to async — only SSL generate here; the convention makes them easy later.
- Per-operation cancellation / retry-from-UI.
- Throttling/batching of line broadcasts (add only if a chatty feature needs it).
- Installer cron entry for `schedule:run` (note it; wire in a later infra pass).
- Output truncation/streaming for huge logs (buffered longText is fine for cert/short ops; revisit for deploy).

## Notes for implementation

- Follow existing conventions: Service/Action layering, `scopeMine()`, `AdminMiddleware`, Inertia shared `auth.user`, Echo private channels (`resources/js/echo.js`).
- The `Process::run` output callback signature is `fn (string $type, string $buffer)`; `$buffer` may contain multiple lines — split on newlines before emitting, or emit the buffer and let the UI render it (spec: emit per line, splitting the buffer).
- `OperationJob` must `SerializesModels` so the `Operation`/`Website` survive queue serialization.
