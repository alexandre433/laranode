# Sub-project #12 — Notifications (in-app center + email/webhook channels)

- **Date:** 2026-06-26
- **Status:** Approved design (ready for writing-plans)
- **Roadmap:** Phase 4, sub-project #12 of `docs/superpowers/specs/2026-06-25-laranode-feature-roadmap.md`
- **Branch:** `feature/notifications` (off `main`)

## Goal

Deliver a persistent, per-user notification center: a bell icon with unread count in the layout, a page listing recent notifications, and opt-in delivery to email and/or a webhook/Slack URL. Notifications are fed by event sources that already exist or ship in later sub-projects. This sub-project owns **delivery** and the in-app center; alert-trigger logic (thresholds, monitoring decisions) belongs to `monitoring-alerts` (#11).

**Why here in the sequence:** the `platform-async-progress` foundation (#1) ships the `operations` table, `OperationUpdated` broadcast, and Reverb/queue infrastructure that this feature builds on. The dispatch seam is designed now so wiring a new event source later is a one-line addition.

## Architecture

A thin pipeline: **event source fires a Laravel `Notification` → `NotificationService` applies per-user preference filtering → `User::notify()` dispatches to the resolved channels (database, mail, webhook) → in-app center reads from the `notifications` table → Reverb pushes a live unread-count bump to the open session.**

```
Event Source
  └─> NotificationService::dispatch(User $user, Notification $notification)
        └─> preference filter (NotificationPreference rows for $user x $type x $channel)
              └─> $user->notify($notification)   // resolves enabled channels
                    ├─> DatabaseChannel  → notifications table
                    │     └─> NotificationsObserver::created() → NotificationCreated broadcast → bell bump
                    ├─> MailChannel      → queued Mailable (Laravel mail)
                    └─> WebhookChannel   → HTTP POST to stored encrypted URL (custom driver)
```

No polling. The bell count updates live via Reverb the same way `OperationProgress` receives job output.

## Components

### 1. `notifications` table (Laravel default schema)

Laravel's `php artisan notifications:table` migration creates `notifications` (`id` UUIDv4, `type`, `notifiable_type`, `notifiable_id`, `data` JSON, `read_at` nullable, `created_at`, `updated_at`). Use this unchanged; no custom columns needed. The `type` column stores the FQCN of the notification class (e.g. `App\Notifications\OperationFinishedNotification`).

Add a composite index `(notifiable_type, notifiable_id, read_at)` to the migration — the shared-prop unread count and `markAllRead` both query on all three columns.

`User` already uses the `Notifiable` trait (confirmed in `app/Models/User.php` line 17). No model change needed.

### 2. `notification_preferences` table + model

New migration `create_notification_preferences_table`:
- `id`, `user_id` (FK users, cascade), `event_type` (string — enum-like key, e.g. `operation.finished`, `ssl.issued`, `ssl.expiring`, `fail2ban.ban`, `resource.threshold`, `backup.result`, `deploy.success`, `deploy.failed`), `channel` (string: `database` | `mail` | `webhook`), `enabled` (boolean default true), `timestamps`.
- Unique index on `(user_id, event_type, channel)`.

**Channel values stored in this table use short aliases: `database`, `mail`, `webhook` — NOT the `WebhookChannel` FQCN.** `NotificationService::resolveChannels()` maps `webhook` → `WebhookChannel::class` when building the `via()` array.

`App\Models\NotificationPreference`:
- `$fillable`: `user_id`, `event_type`, `channel`, `enabled`.
- `$casts`: `enabled => 'boolean'`.
- `belongsTo(User)`.
- Static helper `App\Models\NotificationPreference::isEnabled(int $userId, string $eventType, string $channel): bool` — `$channel` here is the short alias; single query; returns `true` when no row exists (opt-out model: everything on by default, user turns things off).

Default: all channels enabled for all event types. A missing row means "enabled" so new event types light up automatically for existing users.

### 3. Notification classes

`app/Notifications/` — one class per event type. Each extends `Illuminate\Notifications\Notification` and implements `via(object $notifiable): array` using the preference model:

```php
// app/Notifications/OperationFinishedNotification.php
class OperationFinishedNotification extends Notification implements ShouldQueue
{
    public function __construct(public Operation $operation) {}

    public function via(object $notifiable): array
    {
        $eventType = $this->operation->status === 'failed' ? 'operation.failed' : 'operation.finished';
        return NotificationService::resolveChannels($notifiable, $eventType);
    }

    public function toDatabase(object $notifiable): array { ... }
    public function toMail(object $notifiable): MailMessage { ... }
    public function toWebhook(object $notifiable): array { ... }
}
```

Initial notification classes (wire up as their source features ship):
- `OperationFinishedNotification` (`operation.finished` | `operation.failed`) — dispatched from `OperationJob::handle()` when `$notifyUser` is set
- `SslIssuedNotification` (`ssl.issued`) — stub class; dispatch seam NOT yet wired (see §8 below)
- `SslExpiringNotification` (`ssl.expiring`) — dispatched from the scheduler (see §Scheduler Extension)
- `Fail2banBanNotification` (`fail2ban.ban`) — from `security-fail2ban` (#6) — stub
- `ResourceThresholdNotification` (`resource.threshold`) — from `monitoring-alerts` (#11) — stub
- `BackupResultNotification` (`backup.result`) — from `backups` (#9) — stub
- `DeployResultNotification` (`deploy.success` | `deploy.failed`) — from `deploy-git-push` (#7) — stub

For this sub-project, only `OperationFinishedNotification` and `SslExpiringNotification` have live dispatch seams. `SslIssuedNotification` is created as a stub (correct interface, no caller yet). The remaining classes are stubs so the channel + preference infrastructure is exercised end-to-end.

### 4. `NotificationService`

`app/Services/Notifications/NotificationService.php` — orchestrates dispatch; no sudo scripts needed.

```php
class NotificationService
{
    private const CHANNEL_MAP = [
        'database' => 'database',
        'mail'     => 'mail',
        'webhook'  => \App\Notifications\Channels\WebhookChannel::class,
    ];

    /**
     * Resolve which channels are enabled for a given user + event type.
     * $channel preferences use short aliases (database / mail / webhook).
     * Returns channel driver names / class names that Laravel's Notification system understands.
     */
    public static function resolveChannels(object $notifiable, string $eventType): array
    {
        return array_values(array_filter(
            array_values(self::CHANNEL_MAP),
            function ($driver) use ($notifiable, $eventType) {
                $alias = array_search($driver, self::CHANNEL_MAP);
                return NotificationPreference::isEnabled($notifiable->id, $eventType, $alias);
            }
        ));
    }

    /**
     * Dispatch a notification with preference filtering applied.
     * Call this from every event source instead of $user->notify() directly.
     */
    public static function dispatch(User $user, Notification $notification): void
    {
        $user->notify($notification); // via() applies the filter internally
    }
}
```

Callers: `NotificationService::dispatch($user, new OperationFinishedNotification($operation))`.

### 5. Custom `WebhookChannel`

`app/Notifications/Channels/WebhookChannel.php` — implements `send(object $notifiable, Notification $notification): void`.

Security requirements applied in `send()`:
1. Return early if `$notifiable->webhook_url` is null/empty.
2. Validate scheme is `http` or `https` only — reject any other scheme.
3. Reject RFC-1918 / loopback destinations (SSRF prevention): resolve the host and reject if the IP falls in `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, or `127.0.0.0/8`. Use `filter_var` with `FILTER_VALIDATE_IP` + `FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE` on the resolved IP.
4. POST `$notification->toWebhook($notifiable)` as JSON using Laravel's `Http` facade with a 10-second timeout.
5. Catch all `\Throwable`, log with `Log::warning(...)`, do not rethrow. Non-critical delivery path.

```php
public function send(object $notifiable, Notification $notification): void
{
    $url = $notifiable->webhook_url;
    if (empty($url)) return;

    $parsed = parse_url($url);
    if (!in_array($parsed['scheme'] ?? '', ['http', 'https'], true)) return;

    $host = $parsed['host'] ?? '';
    $ip = gethostbyname($host);
    if (!filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE)) {
        Log::warning('WebhookChannel blocked SSRF attempt', ['url' => $url]);
        return;
    }

    try {
        Http::timeout(10)->post($url, $notification->toWebhook($notifiable));
    } catch (\Throwable $e) {
        Log::warning('WebhookChannel delivery failed', ['url' => $url, 'error' => $e->getMessage()]);
    }
}
```

### 6. `webhook_url` stored on `User` — encrypted

Add `webhook_url` (nullable string) to `users` via a new migration. `User` model:
- `$fillable` gains `webhook_url`.
- `$hidden` gains `webhook_url` — prevents it from leaking in the shared `auth.user` Inertia prop (Slack incoming-webhook tokens are secrets).
- `casts()` returns `'webhook_url' => 'encrypted'` — encrypted at rest in the DB; decrypted transparently on read.

The Profile preferences page reads `webhook_url` via a dedicated prop (not via `auth.user`), so it remains accessible to the UI despite `$hidden`. The `NotificationPreferencesController::index()` adds `'webhookUrl' => $request->user()->webhook_url` to the Inertia props.

`ProfileUpdateRequest` does NOT handle `webhook_url` (it only handles name/email). Webhook URL is saved via `PATCH /profile/notifications` handled by `NotificationPreferencesController::updateWebhook()` — a dedicated endpoint that validates `webhook_url` as `nullable|url|max:2048` and saves it.

### 7. `NotificationPreferencesController`

`app/Http/Controllers/NotificationPreferencesController.php` (thin):
- `index()` — returns the current user's preference matrix as Inertia props, plus `webhookUrl` (decrypted). Returns `eventTypes`, `channels` (short aliases), `preferences` (full matrix), `webhookUrl`.
- `update(Request $request)` — validates `event_type` (in-list) + `channel` in `['database','mail','webhook']` + `enabled` (boolean); upserts a `NotificationPreference` row using short alias; returns JSON.
- `updateWebhook(Request $request)` — validates `webhook_url` as `nullable|url|max:2048`; saves to `$request->user()->webhook_url`; returns JSON.

Route: `GET /profile/notifications`, `PATCH /profile/notifications`, `PATCH /profile/notifications/webhook`.

### 8. `NotificationsController`

`app/Http/Controllers/NotificationsController.php`:
- `index()` — `Inertia::render('Notifications/Index', ['notifications' => auth()->user()->notifications()->latest()->paginate(30)])`.
- `markRead(string $id)` — marks a single notification read; returns JSON.
- `markAllRead()` — `$user->unreadNotifications->markAsRead()`; returns JSON.

Routes registered in this order (literal segment before parameter to avoid `read-all` being consumed as `{id}`):
```php
Route::patch('/notifications/read-all', [..., 'markAllRead'])->name('notifications.readAll');
Route::patch('/notifications/{id}/read', [..., 'markRead'])->name('notifications.read');
```

### 9. Live unread-count via Reverb

When a `database` channel notification is written, dispatch broadcast event `NotificationCreated implements ShouldBroadcastNow` on `private-notifications.{userId}`. Payload carries `{ unread_count: int }` only.

`App\Events\NotificationCreated` is fired from `NotificationsObserver` (Eloquent Observer on `Illuminate\Notifications\DatabaseNotification`) on `created`. The observer counts `$model->notifiable->unreadNotifications()->count()` and dispatches.

**Broadcast resilience:** `NotificationCreated::dispatch()` is wrapped in a `try/catch(\Throwable)` inside the observer. `ShouldBroadcastNow` broadcasts synchronously; if Reverb is down it throws. The in-app notification row is already written before the observer fires — catching the broadcast error keeps the row safe. The bell count will be stale until next page load (Inertia refreshes the shared prop). Log the error with `Log::warning`.

```php
public function created(DatabaseNotification $notification): void
{
    $notifiable = $notification->notifiable;
    if ($notifiable === null) return;
    $unreadCount = $notifiable->unreadNotifications()->count();
    try {
        NotificationCreated::dispatch($notifiable->id, $unreadCount);
    } catch (\Throwable $e) {
        Log::warning('NotificationCreated broadcast failed', ['error' => $e->getMessage()]);
    }
}
```

`routes/channels.php` gains:
```php
Broadcast::channel('notifications.{userId}', function ($user, $userId) {
    return (int) $user->id === (int) $userId; // personal only — no admin cross-view
});
```

### 10. `OperationJob` notification hook

Add `public ?User $notifyUser = null` to `OperationJob`. When set, `handle()` calls `NotificationService::dispatch($this->notifyUser, new OperationFinishedNotification($this->operation))` after `markFinished`, on both success and failure paths, via a private `maybeNotify()` method. This is opt-in: existing subclasses with no `notifyUser` set are unaffected.

`GenerateSslOperationJob` sets `$this->notifyUser = $website->user` in its constructor. Note: `Website::user()` currently selects only `['id', 'username', 'role']` — **the `email` column must be added to that select** so the mail channel has a valid recipient address. Fix: `$this->belongsTo(User::class)->select(['id', 'username', 'role', 'email'])`.

`SslIssuedNotification` is NOT dispatched from `GenerateSslOperationJob` in this sub-project. The class is created as a correctly-interfaced stub. The dispatch seam (calling `NotificationService::dispatch($user, new SslIssuedNotification($website))` from the job's `run()`) is left for a follow-up task or the `ssl` sub-project, to avoid wiring two notification types from one job and complicating the `notifyUser` opt-in semantics. The spec previously said it was wired — that was incorrect.

### 11. React — bell + unread count + notification center

**`useNotifications()`** (`resources/js/hooks/useNotifications.js`) — subscribes to `Echo.private('notifications.'+userId)`, listens for `.NotificationCreated`, sets `unreadCount` to `e.unread_count` from the event payload. Initialized from Inertia shared prop `notifications.unreadCount`. Returns `{ unreadCount, refresh }`.

**`NotificationBell.jsx`** (`resources/js/Components/NotificationBell.jsx`) — renders bell icon + red badge when `unreadCount > 0`. Accepts optional `unreadCount` prop override for testability. Clicking navigates to `/notifications` (Inertia Link).

**`TopNavi.jsx`** — add `<NotificationBell />` in the right side of the nav bar.

**`Pages/Notifications/Index.jsx`** — list page: notification rows (icon per type, message, timestamp, read/unread state), "Mark all read" button, pagination.

**`Pages/Profile/Notifications.jsx`** — preference matrix (event types × short-alias channels with toggles) + webhook URL input field. Webhook URL is read from the `webhookUrl` Inertia prop (not `auth.user`). Saves via `PATCH /profile/notifications/webhook`.

## Data Flow (operation.finished example)

1. `GenerateSslOperationJob` runs; `OperationJob::handle()` calls `markFinished(0)`.
2. `maybeNotify()` fires: `NotificationService::dispatch($user, new OperationFinishedNotification($operation))`.
3. `OperationFinishedNotification::via()` calls `NotificationService::resolveChannels($user, 'operation.finished')` → e.g. `['database', WebhookChannel::class]`.
4. Laravel dispatches to `DatabaseChannel` → inserts into `notifications`. `NotificationsObserver::created()` fires → tries `NotificationCreated::dispatch(...)` (caught on Reverb outage).
5. Laravel dispatches to `WebhookChannel::send()` → validates URL + SSRF → POSTs JSON.
6. React's `useNotifications()` receives the Reverb event → sets `unreadCount` → bell shows badge.

## Scheduler Extension

`bootstrap/app.php` `withSchedule` hook gains:
```php
$schedule->call(function () {
    Website::where('ssl_enabled', true)
        ->whereNotNull('ssl_expires_at')
        ->with('user')
        ->get()
        ->filter(fn ($site) => in_array((int) now()->diffInDays($site->ssl_expires_at, false), [14, 7]))
        ->each(fn ($site) =>
            NotificationService::dispatch($site->user, new SslExpiringNotification($site))
        );
})->dailyAt('08:00')->description('ssl.expiring notifications');
```

## Error Handling

- **Mail delivery failure:** queued via Laravel mail stack; failures go to `failed_jobs`. No silent swallowing.
- **Webhook failure:** `WebhookChannel` catches `\Throwable`, logs with `Log::warning`, does not rethrow. Non-critical — in-app notification already written.
- **Missing `webhook_url`:** `WebhookChannel::send()` returns early if null/empty.
- **SSRF / bad scheme:** `WebhookChannel::send()` silently returns (logged as warning for SSRF attempts).
- **Preference lookup failure:** `NotificationPreference::isEnabled()` returns `true` on any DB error (fail-open: deliver rather than silently suppress).
- **Broadcast failure:** `NotificationsObserver` wraps `NotificationCreated::dispatch()` in try/catch; stale count fixed on next Inertia navigation.

## Security

- **SSRF prevention:** `WebhookChannel` validates http/https scheme and rejects RFC-1918/loopback IPs before POSTing.
- **Webhook URL encrypted at rest:** `encrypted` cast on `User::$casts`; `webhook_url` in `User::$hidden` prevents leaking via `auth.user` shared prop.
- **Channel auth:** `private-notifications.{userId}` authorized to own user only (no admin cross-view; notifications are personal).
- **Notification content:** `toDatabase()` stores only display fields (no secrets, no raw output blobs).
- **Preference controller:** scoped to `auth()->user()`; no policy object needed beyond auth middleware.
- **Mass assignment:** `NotificationPreference::$fillable` restricts columns; `event_type` allowlist validated in controller.

## Testing Strategy

### Pest (backend, `QUEUE_CONNECTION=sync`, `Event::fake()`)

`tests/Feature/Notifications/`:

- **`NotificationPreferenceTest`** — `isEnabled` returns `true` on missing row; returns `false` on disabled row; unique constraint enforced; `resolveChannels` excludes disabled channels (using short alias keys).
- **`NotificationDispatchTest`** — all channels enabled → DB row written + mail sent + webhook POSTed; `database`-only → no mail, no webhook; `webhook` disabled → no HTTP call.
- **`WebhookChannelTest`** — POST to valid URL with correct JSON; null `webhook_url` → no call; HTTP 500 from webhook → no exception; `http://` URL rejected (non-https blocked); private IP rejected (SSRF).
- **`NotificationsControllerTest`** — `GET /notifications` returns 200; `markRead` sets `read_at`; `markAllRead` clears only auth user's unread (not other users'); `read-all` route not captured as `{id}` (route order).
- **`NotificationPreferencesControllerTest`** — GET returns matrix with `webhookUrl` prop; PATCH toggles preference; invalid `event_type` → 422; invalid `channel` → 422; `PATCH /profile/notifications/webhook` saves encrypted URL; non-http/https webhook URL rejected 422.
- **`SslExpiringSchedulerTest`** — website with `ssl_expires_at = now()->addDays(7)` → scheduler callback fires → `notifications` row inserted; 30-day cert → no row; schedule entry registered (`php artisan schedule:list` shows it).
- **`BroadcastChannelAuthTest`** — user authorizes own `notifications.{id}`; cannot authorize other user's channel; admin cannot either.
- **`OperationJobNotificationTest`** — job with `notifyUser` dispatches `OperationFinishedNotification` on success; on failure (exception) dispatches notification and rethrows; without `notifyUser` sends nothing.
- **`ObserverBroadcastTest`** — observer catches `\Throwable` from `NotificationCreated::dispatch()` and does not rethrow; DB notification row remains.

### Integration (`LARANODE_SYSTEM_TESTS=1` in local-dev container)

No system calls in this sub-project. Full notification flow (dispatch → DB row → broadcast → bell) exercised via Pest suite under `QUEUE_CONNECTION=sync` + `Event::fake()`.

However, the `WebhookChannel` SSRF DNS resolution (`gethostbyname`) must be verified at least once against a real DNS in the container. Add one `LARANODE_SYSTEM_TESTS=1`-gated test in `WebhookChannelTest`:
```php
test('webhook channel blocks private-IP hostname (system)', function () {
    if (!env('LARANODE_SYSTEM_TESTS')) { skip('system tests only'); }
    Http::fake(); // should never be called
    $user = User::factory()->create(['webhook_url' => 'http://localhost/hook']);
    (new WebhookChannel())->send($user, new OperationFinishedNotification($op));
    Http::assertNothingSent();
})->group('system');
```

### Vitest (frontend)

- `useNotifications.test.jsx` — mock `window.Echo`; drive `.NotificationCreated` event; assert `unreadCount` sets to `e.unread_count`.
- `NotificationBell.test.jsx` — `unreadCount=0` → no badge; `unreadCount=3` via prop override → badge shows "3".

## Back-compat / Migration

- `User` already has `Notifiable` — no model change beyond `$fillable`, `$hidden`, and `casts()`.
- `webhook_url` nullable with no default; existing rows read as `null` (encrypted cast handles null transparently).
- `notification_preferences` starts empty; `isEnabled` returns `true` on missing row; no seeder needed.
- `notifications` table is Laravel standard; confirmed absent from `database/migrations/` today.
- `OperationJob` opt-in hook (`$notifyUser`): all existing subclasses continue unchanged.
- `HandleInertiaRequests::share()` gaining `notifications.unreadCount` is additive.
- `Website::user()` select change (adding `email`) is backward-compatible — callers only read the columns they need.

## File Inventory

```
database/migrations/XXXX_create_notifications_table.php                (new — artisan generated + index added)
database/migrations/XXXX_add_webhook_url_to_users_table.php            (new)
database/migrations/XXXX_create_notification_preferences_table.php     (new)
app/Models/NotificationPreference.php                                   (new)
app/Models/User.php                                                     (modify: $fillable, $hidden, casts + webhook_url)
app/Models/Website.php                                                  (modify: user() select += email)
app/Notifications/OperationFinishedNotification.php                     (new)
app/Notifications/SslIssuedNotification.php                             (new; stub — no dispatch seam)
app/Notifications/SslExpiringNotification.php                           (new; scheduler dispatches)
app/Notifications/Fail2banBanNotification.php                           (new; stub)
app/Notifications/ResourceThresholdNotification.php                     (new; stub)
app/Notifications/BackupResultNotification.php                          (new; stub)
app/Notifications/DeployResultNotification.php                          (new; stub)
app/Notifications/Channels/WebhookChannel.php                           (new; SSRF-safe)
app/Services/Notifications/NotificationService.php                      (new; alias→FQCN map)
app/Events/NotificationCreated.php                                      (new; ShouldBroadcastNow)
app/Observers/NotificationsObserver.php                                 (new; broadcast in try/catch)
app/Http/Controllers/NotificationsController.php                        (new)
app/Http/Controllers/NotificationPreferencesController.php              (new; webhookUrl prop + updateWebhook)
routes/web.php                                                          (modify: read-all BEFORE {id}/read; prefs routes)
routes/channels.php                                                     (modify: notifications.{userId} personal-only)
app/Jobs/OperationJob.php                                               (modify: notifyUser + maybeNotify)
app/Jobs/GenerateSslOperationJob.php                                    (modify: set notifyUser; no SslIssuedNotification)
app/Providers/AppServiceProvider.php                                    (modify: register NotificationsObserver)
app/Http/Middleware/HandleInertiaRequests.php                           (modify: share notifications.unreadCount)
bootstrap/app.php                                                       (modify: ssl-expiry schedule entry)
resources/js/hooks/useNotifications.js                                  (new)
resources/js/Components/NotificationBell.jsx                            (new; prop override for testability)
resources/js/Layouts/Partials/TopNavi.jsx                               (modify: add NotificationBell)
resources/js/Pages/Notifications/Index.jsx                              (new)
resources/js/Pages/Profile/Notifications.jsx                            (new; reads webhookUrl prop not auth.user)
resources/js/Pages/Profile/Edit.jsx                                     (modify: link to /profile/notifications)
resources/js/hooks/useNotifications.test.jsx                            (new; Vitest)
resources/js/Components/NotificationBell.test.jsx                       (new; Vitest)
tests/Feature/Notifications/NotificationPreferenceTest.php              (new)
tests/Feature/Notifications/NotificationDispatchTest.php                (new)
tests/Feature/Notifications/WebhookChannelTest.php                      (new; includes system test)
tests/Feature/Notifications/NotificationsControllerTest.php             (new; no .skip())
tests/Feature/Notifications/NotificationPreferencesControllerTest.php   (new)
tests/Feature/Notifications/SslExpiringSchedulerTest.php                (new)
tests/Feature/Notifications/BroadcastChannelAuthTest.php                (new)
tests/Feature/Notifications/OperationJobNotificationTest.php            (new)
tests/Feature/Notifications/ObserverBroadcastTest.php                   (new)
```

## Boundary with `monitoring-alerts` (#11)

`monitoring-alerts` (#11) owns threshold evaluation, scheduling of resource checks, and deciding when to alert. `notifications` (#12) owns delivery (database / mail / webhook), the in-app center UI, and per-user delivery preferences. The seam: `#11` calls `NotificationService::dispatch($user, new ResourceThresholdNotification(...))`. `#12` provides the service and the stub class; `#11` provides the dispatch call site and threshold logic.

## Out of Scope (Later)

- Push notifications (browser/mobile).
- Admin broadcast to all users.
- Notification grouping / digest mode.
- Signed/HMAC-verified webhook delivery.
- Dropdown bell (v1 uses page navigation; upgrade later).
