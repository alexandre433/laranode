# Sub-project #12 — Notifications (in-app center + email/webhook channels)

- **Date:** 2026-06-26
- **Status:** Approved design (ready for writing-plans)
- **Roadmap:** Phase 4, sub-project #12 of `docs/superpowers/specs/2026-06-25-laranode-feature-roadmap.md`
- **Branch:** `feature/notifications` (off `main`)

## Goal

Deliver a persistent, per-user notification center: a bell icon with unread count in the layout, a slide-out or page listing recent notifications, and opt-in delivery to email and/or a webhook/Slack URL. Notifications are fed by event sources that already exist or ship in later sub-projects. This sub-project owns **delivery** and the in-app center; alert-trigger logic (thresholds, monitoring decisions) belongs to `monitoring-alerts` (#11).

**Why here in the sequence:** the `platform-async-progress` foundation (#1) ships the `operations` table, `OperationUpdated` broadcast, and Reverb/queue infrastructure that this feature builds on. The dispatch seam is designed now so wiring a new event source later is a one-line addition.

## Architecture

A thin pipeline: **event source fires a Laravel `Notification` → `NotificationService` applies per-user preference filtering → `User::notify()` dispatches to the resolved channels (database, mail, webhook) → in-app center reads from the `notifications` table → Reverb pushes a live unread-count bump to the open session.**

```
Event Source
  └─> NotificationService::dispatch(User $user, Notification $notification)
        └─> preference filter (NotificationPreference rows for $user x $type x $channel)
              └─> $user->notify($notification)   // resolves enabled channels
                    ├─> DatabaseChannel  → notifications table
                    │     └─> OperationUpdated-style broadcast → Bell/unread bump
                    ├─> MailChannel      → queued Mailable (Laravel mail)
                    └─> WebhookChannel   → HTTP POST to stored URL (custom driver)
```

No polling. The bell count updates live via Reverb the same way `OperationProgress` receives job output.

## Components

### 1. `notifications` table (Laravel default schema)

Laravel's `php artisan notifications:table` migration creates `notifications` (`id` UUIDv4, `type`, `notifiable_type`, `notifiable_id`, `data` JSON, `read_at` nullable, `created_at`, `updated_at`). Use this unchanged; no custom columns needed. The `type` column stores the FQCN of the notification class (e.g. `App\Notifications\OperationFinishedNotification`).

`User` already uses the `Notifiable` trait (confirmed in `app/Models/User.php` line 10). No model change needed.

### 2. `notification_preferences` table + model

New migration `create_notification_preferences_table`:
- `id`, `user_id` (FK users, cascade), `event_type` (string — enum-like key, e.g. `operation.finished`, `ssl.issued`, `ssl.expiring`, `fail2ban.ban`, `resource.threshold`, `backup.result`, `deploy.success`, `deploy.failed`), `channel` (string: `database` | `mail` | `webhook`), `enabled` (boolean default true), `timestamps`.
- Unique index on `(user_id, event_type, channel)`.

`App\Models\NotificationPreference`:
- `$fillable`: `user_id`, `event_type`, `channel`, `enabled`.
- `$casts`: `enabled => 'boolean'`.
- `belongsTo(User)`.
- Static helper `App\Models\NotificationPreference::isEnabled(int $userId, string $eventType, string $channel): bool` — single query; returns `true` when no row exists (opt-out model: everything on by default, user turns things off).

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
        return NotificationService::resolveChannels($notifiable, 'operation.finished');
    }

    public function toDatabase(object $notifiable): array { ... }
    public function toMail(object $notifiable): MailMessage { ... }
    public function toWebhook(object $notifiable): array { ... }
}
```

Initial notification classes (wire up as their source features ship):
- `OperationFinishedNotification` (`operation.finished` | `operation.failed`) — sources from the `#1` OperationJob foundation
- `SslIssuedNotification` (`ssl.issued`) — from `GenerateSslOperationJob`
- `SslExpiringNotification` (`ssl.expiring`) — scheduled check (see scheduler section)
- `Fail2banBanNotification` (`fail2ban.ban`) — from `security-fail2ban` (#6)
- `ResourceThresholdNotification` (`resource.threshold`) — from `monitoring-alerts` (#11)
- `BackupResultNotification` (`backup.result`) — from `backups` (#9)
- `DeployResultNotification` (`deploy.success` | `deploy.failed`) — from `deploy-git-push` (#7)

For this sub-project, only `OperationFinishedNotification` and `SslIssuedNotification` are wired (the sources exist). The rest are created as stub classes (correct interface, no dispatch seam yet) so the channel + preference infrastructure is exercised end-to-end.

### 4. `NotificationService`

`app/Services/Notifications/NotificationService.php` — orchestrates dispatch; no sudo scripts needed.

```php
class NotificationService
{
    /**
     * Resolve which channels are enabled for a given user + event type.
     * Returns channel driver names that Laravel's Notification system understands.
     */
    public static function resolveChannels(object $notifiable, string $eventType): array
    {
        $available = ['database', 'mail', WebhookChannel::class];
        return array_filter($available, fn ($channel) =>
            NotificationPreference::isEnabled($notifiable->id, $eventType, $channel)
        );
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

Callers use `NotificationService::dispatch($user, new OperationFinishedNotification($operation))`. The notification's `via()` method calls `NotificationService::resolveChannels()` and Laravel routes to the correct channel drivers.

### 5. Custom `WebhookChannel`

`app/Notifications/Channels/WebhookChannel.php` — implements `send(object $notifiable, Notification $notification): void`. Reads `$notifiable->webhook_url` (new nullable column on `users`, see data model) and POSTs `$notification->toWebhook($notifiable)` as JSON using Laravel's `Http` facade with a 10-second timeout. Failures are caught and logged; they do not bubble (non-critical delivery path).

### 6. Webhook URL stored on `User`

Add `webhook_url` (nullable string) to `users` via a new migration. `User::$fillable` gains `webhook_url`. The Profile page (`Pages/Profile/Edit.jsx` / `ProfileController`) gains a webhook URL field. No encrypted cast needed (the URL is not a secret; the payload is informational).

### 7. `NotificationPreferencesController`

`app/Http/Controllers/NotificationPreferencesController.php` (thin — delegates to `NotificationService`):
- `index()` — returns the current user's preferences as Inertia props (all supported event types × channels, with enabled state per row). Uses `NotificationPreference::where('user_id', $user->id)->get()` joined against the known event-type/channel matrix.
- `update(Request $request)` — validates `event_type` (in-list) + `channel` (in-list) + `enabled` (boolean); upserts a `NotificationPreference` row; returns updated state.

Route: `GET/PATCH /profile/notifications` (under existing auth middleware, not admin-only).

### 8. `NotificationsController`

`app/Http/Controllers/NotificationsController.php`:
- `index()` — `Inertia::render('Notifications/Index', ['notifications' => auth()->user()->notifications()->latest()->paginate(30)])`. Lists all (read + unread). Uses `$user->notifications` (Laravel's polymorphic relation on the `notifications` table).
- `markRead(string $id)` — marks a single notification read (`$user->notifications()->findOrFail($id)->markAsRead()`); returns JSON.
- `markAllRead()` — `$user->unreadNotifications->markAsRead()`; returns JSON.

Route: `GET /notifications` (bell page), `PATCH /notifications/{id}/read`, `PATCH /notifications/read-all`.

### 9. Live unread-count via Reverb

When a `database` channel notification is written, dispatch a broadcast event `NotificationCreated implements ShouldBroadcast` on `private-notifications.{userId}`. The payload carries `{ unread_count: int }` only — no notification content over the wire (avoids leaking data in the channel payload).

`routes/channels.php` gains:
```php
Broadcast::channel('notifications.{userId}', function ($user, $userId) {
    return (int) $user->id === (int) $userId;
});
```
(Admin does not need to watch other users' notification channels — this is personal delivery, not an audit stream.)

`App\Events\NotificationCreated` is fired from inside `NotificationsObserver` (an `Eloquent\Observer` on the `DatabaseNotification` model from `Illuminate\Notifications\DatabaseNotification`) on `created`. The observer counts `$model->notifiable->unreadNotifications()->count()` and broadcasts.

### 10. React — bell + unread count + notification center

**`useNotifications()`** (`resources/js/hooks/useNotifications.js`) — subscribes to `Echo.private('notifications.'+userId)`, listens for `.NotificationCreated`, maintains `unreadCount` state. Initialized from an Inertia shared prop `notifications.unreadCount` (added to `HandleInertiaRequests::share()`). Returns `{ unreadCount, refresh }`.

**`NotificationBell.jsx`** (`resources/js/Components/NotificationBell.jsx`) — renders the bell icon (from the existing `react-icons` library, e.g. `IoNotificationsOutline`) + a red badge when `unreadCount > 0`. Clicking navigates to `/notifications` (Inertia link) or opens a slide-out dropdown (decision: see Open Questions).

**`TopNavi.jsx`** (`resources/js/Layouts/Partials/TopNavi.jsx`) — add `<NotificationBell />` alongside the existing logout/impersonate controls in the right side of the nav bar (line 34 area).

**`Pages/Notifications/Index.jsx`** — list page: notification rows (icon per type, message, timestamp, read/unread state), "Mark all read" button, pagination. Mark-read fires axios PATCH, updates local state.

**`Pages/Profile/Edit.jsx`** — extend with a "Notification Preferences" section: a matrix of event types × channels with toggles, and a webhook URL input field. Calls `PATCH /profile/notifications`.

## Data Flow (operation.finished example)

1. `GenerateSslOperationJob` calls `Operation::markFinished(0)` (existing, `#1`).
2. Job's `handle()` calls `NotificationService::dispatch($user, new OperationFinishedNotification($operation))` after `markFinished`.
3. `OperationFinishedNotification::via()` calls `NotificationService::resolveChannels($user, 'operation.finished')` — returns e.g. `['database', 'mail']` (webhook not enabled by this user).
4. Laravel dispatches to `DatabaseChannel` → inserts a row into `notifications`. `NotificationsObserver::created()` fires → dispatches `NotificationCreated` broadcast on `private-notifications.{userId}`.
5. Laravel dispatches to `MailChannel` → queued mailable (existing queue worker picks it up).
6. React's `useNotifications()` receives the Reverb event → increments `unreadCount` → `NotificationBell` shows the badge without a page reload.

## Wiring Existing Event Sources

`GenerateSslOperationJob::run()` already calls `$emit()` lines and returns 0. The dispatch call is added to the job's `handle()` in `OperationJob` base class — but only for the finished/failed lifecycle, not per-line events. Option: override `markFinished` to fire notifications, or add a hook in `OperationJob::handle()`. **Chosen approach:** add an optional `protected ?User $notifyUser = null` property to `OperationJob`; subclasses that want completion notifications set it; `handle()` calls `NotificationService::dispatch()` after `markFinished`. This keeps the base class opt-in and non-breaking.

## Scheduler Extension

The existing `bootstrap/app.php` `withSchedule` hook (added by `#1`) gains:
```php
$schedule->call(function () {
    // Notify users about SSL certs expiring in 14 or 7 days
    Website::where('ssl_enabled', true)
        ->whereNotNull('ssl_expires_at')
        ->whereIn(\Illuminate\Support\Facades\DB::raw('DATEDIFF(ssl_expires_at, NOW())'), [14, 7])
        ->with('user')
        ->get()
        ->each(fn ($site) =>
            NotificationService::dispatch($site->user, new SslExpiringNotification($site))
        );
})->dailyAt('08:00');
```

## Error Handling

- **Mail delivery failure:** Laravel queues mail; if the queue driver processes it and the mail server rejects, the job fails and goes to `failed_jobs`. No silent swallowing.
- **Webhook failure:** `WebhookChannel` catches `\Throwable`, logs with `Log::warning(...)`, does not rethrow. Non-critical — the in-app notification is already written.
- **Missing `webhook_url`:** `WebhookChannel::send()` returns early if `$notifiable->webhook_url` is null.
- **Preference lookup:** on any DB error, `NotificationPreference::isEnabled()` returns `true` (fail-open: deliver rather than silently suppress).
- **Broadcast failure:** `NotificationCreated` implements `ShouldBroadcastNow` so it does not queue separately. If Reverb is down, the broadcast fails silently; the unread count will be stale until next page load (where Inertia refreshes the shared prop).

## Security

- **Channel auth:** `private-notifications.{userId}` authorized to own user only (no admin cross-user; notifications are personal). The existing `operations.{userId}` allows admin cross-view; notifications deliberately do not.
- **Notification content:** `toDatabase()` stores only the fields needed for display (no secrets, no raw output blobs — reference the `Operation::id` for lookups). Webhook payload includes `event_type`, `operation_id`, `url`, `status` — no credential data.
- **Webhook URL:** stored plaintext (it's a URL, not a secret). Panel admin can view it via the accounts UI; document this. If a Slack incoming-webhook URL is considered sensitive (it authorizes posting), we can add a dedicated `encrypted_webhook_url` cast — see Open Questions.
- **Preference controller:** scoped to `auth()->user()`; no policy object needed beyond the auth middleware since users can only edit their own preferences.
- **Mass assignment:** `NotificationPreference::$fillable` restricts `event_type` to an allowlist validated in the FormRequest.

## Testing Strategy

### Pest (backend, `QUEUE_CONNECTION=sync`, `Event::fake()`)

`tests/Feature/Notifications/`:

- **`NotificationPreferenceTest`** — upsert creates row; missing row returns `isEnabled=true` (fail-open); `resolveChannels()` excludes disabled channels; unique constraint on (user, event_type, channel).
- **`NotificationDispatchTest`** — `NotificationService::dispatch($user, new OperationFinishedNotification($op))` with all channels enabled → `assertDatabaseHas('notifications', ...)` + `Event::assertDispatched(NotificationCreated::class)` + assert `SentMessage` via `Mail::fake()`. With database-only → no mail sent.
- **`WebhookChannelTest`** — `Http::fake()` → assert POST to `$user->webhook_url` with correct JSON; null `webhook_url` → no HTTP call; HTTP 500 from webhook → no exception thrown.
- **`NotificationsControllerTest`** — `GET /notifications` returns 200; mark-read sets `read_at`; mark-all-read clears all unread for user, not other users'.
- **`NotificationPreferencesControllerTest`** — GET returns full matrix; PATCH toggles a channel; invalid event_type rejected 422.
- **`SslExpiringSchedulerTest`** — seed a website with `ssl_expires_at = now()->addDays(7)` → run the scheduled callback → `assertDatabaseHas('notifications', ['type' => SslExpiringNotification::class])`.
- **`BroadcastChannelAuthTest`** — user can authorize `notifications.{own_id}`; cannot authorize `notifications.{other_id}`; admin also cannot (unlike `operations.{userId}`).

### Vitest (frontend)

`resources/js/hooks/useNotifications.test.jsx`:
- Mock `window.Echo` (same pattern as `useOperation.test.jsx`); drive a `.NotificationCreated` event; assert `unreadCount` increments.

`resources/js/Components/NotificationBell.test.jsx`:
- Render with `unreadCount=0` → no badge; `unreadCount=3` → badge shows "3".

### Container integration (`LARANODE_SYSTEM_TESTS=1` not needed — no system calls)

Full notification flow (dispatch → DB row → broadcast → bell update) exercised via the Pest suite under `QUEUE_CONNECTION=sync` + `Event::fake()` in the local-dev container, same as `#1`.

## Back-compat / Migration

- `User` already has `Notifiable` — no model change. New `webhook_url` column is nullable with no default, so existing rows are unaffected.
- `notification_preferences` starts empty for all users; `NotificationPreference::isEnabled()` returns `true` on a missing row, so existing users get all notifications until they opt out. No seeder needed.
- The `notifications` table is Laravel standard; no conflict with any existing table (confirmed — `database/migrations/` does not contain it today).
- `OperationJob::handle()` gains an opt-in hook (`$this->notifyUser`). All existing subclasses (`GenerateSslOperationJob`) continue to work unchanged with no notification behavior until they set the property.
- `HandleInertiaRequests::share()` adding `notifications.unreadCount` is additive; no existing JS reads it, so no breakage.

## File Inventory

```
database/migrations/XXXX_create_notification_preferences_table.php   (new)
database/migrations/XXXX_add_webhook_url_to_users_table.php           (new)
app/Models/NotificationPreference.php                                  (new)
app/Notifications/OperationFinishedNotification.php                    (new)
app/Notifications/SslIssuedNotification.php                            (new)
app/Notifications/SslExpiringNotification.php                          (new; stub dispatch seam)
app/Notifications/Fail2banBanNotification.php                          (new; stub)
app/Notifications/ResourceThresholdNotification.php                    (new; stub)
app/Notifications/BackupResultNotification.php                         (new; stub)
app/Notifications/DeployResultNotification.php                         (new; stub)
app/Notifications/Channels/WebhookChannel.php                          (new)
app/Services/Notifications/NotificationService.php                     (new)
app/Events/NotificationCreated.php                                     (new; ShouldBroadcast)
app/Observers/NotificationsObserver.php                                (new)
app/Http/Controllers/NotificationsController.php                       (new)
app/Http/Controllers/NotificationPreferencesController.php             (new)
routes/web.php                                                         (modify: notifications + prefs routes)
routes/channels.php                                                    (modify: notifications.{userId})
app/Jobs/OperationJob.php                                              (modify: opt-in notifyUser hook)
app/Jobs/GenerateSslOperationJob.php                                   (modify: set notifyUser)
app/Http/Middleware/HandleInertiaRequests.php                          (modify: share unreadCount)
bootstrap/app.php                                                      (modify: ssl-expiry schedule)
app/Models/User.php                                                    (modify: $fillable += webhook_url)
resources/js/hooks/useNotifications.js                                 (new)
resources/js/Components/NotificationBell.jsx                           (new)
resources/js/Layouts/Partials/TopNavi.jsx                              (modify: add NotificationBell)
resources/js/Pages/Notifications/Index.jsx                             (new)
resources/js/Pages/Profile/Edit.jsx                                    (modify: prefs + webhook URL)
resources/js/hooks/useNotifications.test.jsx                           (new; Vitest)
resources/js/Components/NotificationBell.test.jsx                      (new; Vitest)
tests/Feature/Notifications/NotificationPreferenceTest.php             (new)
tests/Feature/Notifications/NotificationDispatchTest.php               (new)
tests/Feature/Notifications/WebhookChannelTest.php                     (new)
tests/Feature/Notifications/NotificationsControllerTest.php            (new)
tests/Feature/Notifications/NotificationPreferencesControllerTest.php  (new)
tests/Feature/Notifications/SslExpiringSchedulerTest.php               (new)
tests/Feature/Notifications/BroadcastChannelAuthTest.php               (new)
```

## Boundary with `monitoring-alerts` (#11)

`monitoring-alerts` (#11) owns:
- Reading `failed_jobs` and deciding whether a failure is alert-worthy.
- Evaluating CPU/disk/memory thresholds against the `SystemStatsService` data.
- Scheduling periodic resource-check runs.

`notifications` (#12) owns:
- How to deliver a triggered alert to a user (database / mail / webhook).
- The in-app notification center UI.
- Per-user delivery preferences.

The seam: `monitoring-alerts` calls `NotificationService::dispatch($user, new ResourceThresholdNotification(...))` when it decides a threshold has been crossed. `#12` provides that service and the notification class stub; `#11` provides the dispatch call site and the threshold logic. They can ship in either order — stubs in `#12` allow `#11` to wire into a real delivery channel immediately.

## Out of Scope (Later)

- Push notifications (browser/mobile) — not on this host's stack.
- Admin broadcast to all users — design it if teams/RBAC (#17) introduces a need.
- Notification grouping / digest mode — add if volume becomes noisy after several event sources are live.
- Signed/HMAC-verified webhook delivery (like GitHub webhooks) — add to `WebhookChannel` if requested; the stub URL is the simplest secure approach for a self-hosted panel.

## Open Questions

1. **Bell interaction — page vs dropdown:** does clicking the bell navigate to `/notifications` (simplest, reuses `Notifications/Index.jsx`) or open a slide-out dropdown with the last 5 unread items + "View all" link? The dropdown is better UX but adds a more complex React component; the page is simpler. Recommend: page for v1, upgrade to dropdown later.
2. **Webhook URL sensitivity:** should `webhook_url` use an `encrypted` cast (to protect Slack incoming-webhook tokens at rest in the DB)? The database is on the same host, so the threat model is limited, but Slack tokens are arguably secrets. Decision needed before migration is written.
3. **`NotificationsObserver` registration:** register in `AppServiceProvider::boot()` via `DatabaseNotification::observe(NotificationsObserver::class)`, or use a model lifecycle hook in `NotificationPreference`? The Observer approach is cleaner; confirm no conflict with `lab404/laravel-impersonate`.
4. **Shared prop cost:** `HandleInertiaRequests::share()` adding `notifications.unreadCount` fires a COUNT query on every Inertia page load. Acceptable for v1 (one cheap indexed query). Confirm this is tolerable or cache with a 30-second TTL in a later pass.
5. **`ShouldBroadcastNow` vs `ShouldBroadcast`:** `NotificationCreated` using `ShouldBroadcastNow` bypasses the queue (immediate delivery, no queue worker lag for the bell bump). This is the right call for a count-only event, but confirm it works when Reverb is under load.
6. **`OperationJob` hook design:** the `protected ?User $notifyUser` property requires subclasses to set it explicitly. Alternative: `handle()` always notifies `$this->operation->user` on terminal status, with a per-subclass opt-out. The explicit opt-in is safer (avoids surprising behavior for jobs that don't want notifications), but the opt-out default would auto-wire all future `OperationJob` subclasses. Which default is preferred?
