# Sub-project #12 — Notifications — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persistent per-user notification center — bell with live unread count, notification list page, per-channel delivery preferences, email + webhook delivery, `OperationFinished` live event source, SSL-expiry scheduler source.

**Architecture:** Event source → `NotificationService::dispatch($user, $notification)` → preference filter → `$user->notify()` → resolved channels (database / mail / `WebhookChannel`). DB write → `NotificationsObserver::created()` → broadcasts `NotificationCreated` on `private-notifications.{userId}`. `useNotifications()` hook subscribes; `NotificationBell` shows badge live.

**Design spec:** `docs/superpowers/specs/2026-06-26-notifications-design.md`

## Global Constraints

- **Channel aliases in `notification_preferences` are short:** `database` | `mail` | `webhook`. `NotificationService::resolveChannels()` maps `webhook` → `WebhookChannel::class` via a private `CHANNEL_MAP` constant.
- **`WebhookChannel` is SSRF-safe:** validate `http`/`https` scheme only; reject RFC-1918/loopback IPs (`gethostbyname` + `FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE`). Non-critical: catch all `\Throwable`, log, never rethrow.
- **`webhook_url` on `User`:** `encrypted` cast + in `$hidden` (prevents leaking via `auth.user` Inertia prop). Saved via dedicated `PATCH /profile/notifications/webhook` endpoint, NOT via `ProfileUpdateRequest`.
- **`notifications` table composite index:** `(notifiable_type, notifiable_id, read_at)` added in the migration.
- **`Website::user()` select must include `email`:** current select is `['id', 'username', 'role']`; add `email` or mail channel sends to blank address.
- **Route order:** register `PATCH /notifications/read-all` BEFORE `PATCH /notifications/{id}/read` — literal segment must not be consumed as `{id}`.
- **`NotificationsObserver`** wraps `NotificationCreated::dispatch()` in `try/catch(\Throwable)` — `ShouldBroadcastNow` throws synchronously on Reverb outage; DB notification row must not be lost.
- **`ShouldBroadcastNow`** for `NotificationCreated` — immediate bell update, no queue lag.
- **`OperationJob` hook is opt-in:** `public ?User $notifyUser = null`; `handle()` calls `maybeNotify()` after `markFinished` on both success and failure paths.
- **`SslIssuedNotification` is a stub** — class exists with correct interface, but NO dispatch seam in this sub-project. `GenerateSslOperationJob` only sets `notifyUser`; it does not dispatch `SslIssuedNotification`.
- **No `.skip()` on any test.**
- **`notification_preferences` opt-out model:** missing row = enabled. `isEnabled()` returns `true` on any DB error (fail-open).
- **Channel auth:** `notifications.{userId}` personal only — no admin cross-view.
- **Tests run with `QUEUE_CONNECTION=sync`, `Event::fake()`, `Mail::fake()`, `Http::fake()`.**
- **Branch:** `feature/notifications` (off `main`).
- **Run suite in container:** `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test'`
- **Pint before each commit:** `./vendor/bin/pint`

---

> **Execution order:** Tasks 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9. Task 2 needs Task 1 (notifications table). Task 3 needs Tasks 1–2 (model + classes). Tasks 4–5 are independent once Task 3 is done. Tasks 6–7 need Tasks 3–5. Tasks 8–9 need Task 6 (shared prop) and Task 7 (routes).

---

### Task 1: `notifications` table + `webhook_url` on `users` + `Website::user()` fix

**Files:**
- Generate + modify: `database/migrations/XXXX_create_notifications_table.php` (add composite index)
- Create: `database/migrations/XXXX_add_webhook_url_to_users_table.php`
- Modify: `app/Models/User.php` (`$fillable` += `webhook_url`; `$hidden` += `webhook_url`; `casts()` += `'webhook_url' => 'encrypted'`)
- Modify: `app/Models/Website.php` (`user()` select += `email`)

**Acceptance criteria:**
- `php artisan migrate` runs clean.
- `User::factory()->create(['webhook_url' => 'https://example.com'])->webhook_url` returns the plaintext URL (encrypted cast round-trips).
- `$user->toArray()` does NOT include `webhook_url` key (hidden).
- `Website::first()->user->email` is not null for a seeded user.

**Notes:**
- Generate with `php artisan notifications:table`, then add inside `Schema::create('notifications', ...)`:
  ```php
  $table->index(['notifiable_type', 'notifiable_id', 'read_at']);
  ```
- `webhook_url` migration: `$table->string('webhook_url')->nullable()->after('email');` — nullable, no default, existing rows unaffected.
- `Website::user()` change: `->select(['id', 'username', 'role', 'email'])`.

- [ ] Generate notifications migration + add composite index
- [ ] Create webhook_url migration
- [ ] Update `User` model (`$fillable`, `$hidden`, `casts`)
- [ ] Update `Website::user()` select to include `email`
- [ ] `php artisan migrate` → verify clean
- [ ] Run `php artisan test` → no regressions
- [ ] Pint + commit

---

### Task 2: `notification_preferences` table + `NotificationPreference` model

**Files:**
- Create: `database/migrations/XXXX_create_notification_preferences_table.php`
- Create: `app/Models/NotificationPreference.php`
- Create: `tests/Feature/Notifications/NotificationPreferenceTest.php`

**Schema:** `id`, `user_id` (FK cascade), `event_type` (string), `channel` (string — short alias: `database`|`mail`|`webhook`), `enabled` (boolean default true), `timestamps`. Unique on `(user_id, event_type, channel)`.

**`isEnabled(int $userId, string $eventType, string $channel): bool`** — query by `user_id + event_type + channel`; return `true` when no row or `enabled=true`; catch `\Throwable` → return `true`.

**Acceptance criteria (Pest):**
- Missing row → `isEnabled` returns `true`.
- Disabled row → `isEnabled` returns `false`.
- Enabled row → `isEnabled` returns `true`.
- Duplicate insert → `QueryException` (unique constraint).

- [ ] Write failing test
- [ ] Write migration + model
- [ ] `php artisan test --filter=NotificationPreferenceTest` → PASS (4 tests)
- [ ] Pint + commit

---

### Task 3: `NotificationService` + `WebhookChannel` + notification classes

**Files:**
- Create: `app/Services/Notifications/NotificationService.php`
- Create: `app/Notifications/Channels/WebhookChannel.php`
- Create: `app/Notifications/OperationFinishedNotification.php`
- Create: `app/Notifications/SslIssuedNotification.php` (stub — no dispatch seam)
- Create: `app/Notifications/SslExpiringNotification.php`
- Create: `app/Notifications/Fail2banBanNotification.php` (stub)
- Create: `app/Notifications/ResourceThresholdNotification.php` (stub)
- Create: `app/Notifications/BackupResultNotification.php` (stub)
- Create: `app/Notifications/DeployResultNotification.php` (stub)
- Create: `tests/Feature/Notifications/NotificationDispatchTest.php`
- Create: `tests/Feature/Notifications/WebhookChannelTest.php`

**`NotificationService::resolveChannels()`** maps short aliases to drivers via `CHANNEL_MAP = ['database'=>'database', 'mail'=>'mail', 'webhook'=>WebhookChannel::class]`; calls `isEnabled($notifiable->id, $eventType, $alias)` per entry; returns array of enabled drivers.

**`WebhookChannel::send()`** (all guards inline — see spec §5):
1. Return early if `webhook_url` null/empty.
2. Validate `http`|`https` scheme only.
3. Reject private/loopback IP via `gethostbyname` + `FILTER_VALIDATE_IP` with `FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE`.
4. `Http::timeout(10)->post($url, $notification->toWebhook($notifiable))`.
5. Catch `\Throwable` → `Log::warning` → return.

**Acceptance criteria (Pest):**

`NotificationDispatchTest`:
- All channels enabled → `assertDatabaseHas('notifications', ...)` + `Mail::assertSent(...)` + `Http::assertSent(...)`.
- Mail disabled → `Mail::assertNothingSent()`, DB row still written.
- `resolveChannels` with `webhook` disabled → does not include `WebhookChannel::class`.

`WebhookChannelTest`:
- POST to valid URL → `Http::assertSent(fn($r) => $r->isJson() && isset($r->data()['event_type']))`.
- Null `webhook_url` → `Http::assertNothingSent()`.
- HTTP 500 response → no exception thrown.
- `http://192.168.1.1/hook` → `Http::assertNothingSent()` (SSRF blocked).
- Non-http scheme (`ftp://...`) → `Http::assertNothingSent()`.
- `LARANODE_SYSTEM_TESTS=1`-gated: `http://localhost/hook` → `Http::assertNothingSent()` (real DNS resolution).

- [ ] Write failing tests (dispatch + webhook)
- [ ] Write `NotificationService`
- [ ] Write `WebhookChannel` (SSRF-safe)
- [ ] Write `OperationFinishedNotification` (live), `SslExpiringNotification` (live), five stubs
- [ ] `php artisan test --filter="NotificationDispatchTest|WebhookChannelTest"` → PASS
- [ ] Pint + commit

---

### Task 4: `NotificationCreated` event + `NotificationsObserver` + channel auth

**Files:**
- Create: `app/Events/NotificationCreated.php`
- Create: `app/Observers/NotificationsObserver.php`
- Modify: `routes/channels.php` (add `notifications.{userId}`)
- Modify: `app/Providers/AppServiceProvider.php` (register observer on `DatabaseNotification`)
- Create: `tests/Feature/Notifications/BroadcastChannelAuthTest.php`
- Create: `tests/Feature/Notifications/ObserverBroadcastTest.php`

**`NotificationCreated`:** `ShouldBroadcastNow`; `broadcastOn()` → `PrivateChannel('notifications.'.$userId)`; `broadcastAs()` → `'NotificationCreated'`; `broadcastWith()` → `['unread_count' => $unreadCount]`.

**`NotificationsObserver::created()`:** get `$notifiable`, count `unreadNotifications()`, wrap `NotificationCreated::dispatch(...)` in `try/catch(\Throwable)` → `Log::warning` on error.

**Channel auth:** `(int)$user->id === (int)$userId` only — no admin cross-view.

**Acceptance criteria (Pest):**

`BroadcastChannelAuthTest`:
- Own channel → 200.
- Other user's channel → 403.
- Admin on another user's channel → 403.

`ObserverBroadcastTest`:
- `Event::fake([NotificationCreated::class])` + insert `DatabaseNotification` → `Event::assertDispatched(NotificationCreated::class)`.
- Observer does NOT throw when `NotificationCreated::dispatch()` throws (mock the dispatch to throw `\RuntimeException`; assert no exception propagates and DB notification row still exists).

- [ ] Write failing tests (channel auth + observer)
- [ ] Write `NotificationCreated` event
- [ ] Write `NotificationsObserver` (broadcast in try/catch)
- [ ] Add channel auth to `routes/channels.php`
- [ ] Register observer in `AppServiceProvider::boot()`
- [ ] `php artisan test --filter="BroadcastChannelAuthTest|ObserverBroadcastTest"` → PASS
- [ ] Pint + commit

---

### Task 5: `OperationJob` notification hook + wire `GenerateSslOperationJob`

**Files:**
- Modify: `app/Jobs/OperationJob.php` (add `public ?User $notifyUser = null`; add `maybeNotify()`)
- Modify: `app/Jobs/GenerateSslOperationJob.php` (set `$this->notifyUser = $website->user` in constructor)
- Create: `tests/Feature/Notifications/OperationJobNotificationTest.php`

**`handle()` change:** call `$this->maybeNotify()` after `markFinished()` on both success and catch paths. `maybeNotify()` dispatches `NotificationService::dispatch($this->notifyUser, new OperationFinishedNotification($this->operation))` when `$notifyUser !== null`. The exception is still rethrown after `maybeNotify()` in the catch block.

**Note:** `GenerateSslOperationJob` does NOT dispatch `SslIssuedNotification`. Only `notifyUser` is set.

**Acceptance criteria (Pest):**

`OperationJobNotificationTest`:
- Inline subclass with `notifyUser` set → `Notification::assertSentTo($user, OperationFinishedNotification::class)` on success.
- Throwing subclass with `notifyUser` set → notification dispatched AND exception still propagates.
- Subclass without `notifyUser` → `Notification::assertNothingSent()`.

Run existing operations suite → zero regressions.

- [ ] Write failing test
- [ ] Add `notifyUser` property + `maybeNotify()` to `OperationJob`
- [ ] Set `$this->notifyUser` in `GenerateSslOperationJob` constructor
- [ ] `php artisan test --filter=OperationJobNotificationTest` → PASS
- [ ] `php artisan test --filter=Operations` → zero regressions
- [ ] Pint + commit

---

### Task 6: SSL-expiry scheduler + `HandleInertiaRequests` unread-count prop

**Files:**
- Modify: `bootstrap/app.php` (add SSL-expiry `$schedule->call(...)` inside existing `withSchedule`)
- Modify: `app/Http/Middleware/HandleInertiaRequests.php` (add `notifications.unreadCount` to `share()`)
- Create: `tests/Feature/Notifications/SslExpiringSchedulerTest.php`

**Scheduler call:** daily at `08:00`, description `ssl.expiring notifications`. Queries `Website::where('ssl_enabled', true)->whereNotNull('ssl_expires_at')->with('user')->get()`, filters for `diffInDays === 14 || 7`, dispatches `SslExpiringNotification`.

**Shared prop:** `'notifications' => ['unreadCount' => $request->user()?->unreadNotifications()->count() ?? 0]`.

**Acceptance criteria (Pest):**

`SslExpiringSchedulerTest`:
- Website with `ssl_expires_at = now()->addDays(7)` → run scheduler closure → `assertDatabaseHas('notifications', ['type' => SslExpiringNotification::class])`.
- Website with `ssl_expires_at = now()->addDays(30)` → `Notification::assertNothingSent()`.
- `php artisan schedule:list` output contains `ssl.expiring notifications`.

- [ ] Write failing test
- [ ] Add SSL-expiry schedule entry to `bootstrap/app.php`
- [ ] Add `notifications.unreadCount` to `HandleInertiaRequests::share()`
- [ ] `php artisan test --filter=SslExpiringSchedulerTest` → PASS (3 tests)
- [ ] Confirm `php artisan schedule:list` shows entry
- [ ] Pint + commit

---

### Task 7: `NotificationsController` + `NotificationPreferencesController` + routes

**Files:**
- Create: `app/Http/Controllers/NotificationsController.php`
- Create: `app/Http/Controllers/NotificationPreferencesController.php`
- Modify: `routes/web.php` (notifications + prefs routes — read-all BEFORE `{id}/read`)
- Create: `tests/Feature/Notifications/NotificationsControllerTest.php`
- Create: `tests/Feature/Notifications/NotificationPreferencesControllerTest.php`

**Route registration order (critical):**
```php
Route::middleware('auth')->group(function () {
    Route::get('/notifications', [NotificationsController::class, 'index'])->name('notifications.index');
    Route::patch('/notifications/read-all', [NotificationsController::class, 'markAllRead'])->name('notifications.readAll');
    Route::patch('/notifications/{id}/read', [NotificationsController::class, 'markRead'])->name('notifications.read');
    Route::get('/profile/notifications', [NotificationPreferencesController::class, 'index'])->name('notifications.preferences');
    Route::patch('/profile/notifications', [NotificationPreferencesController::class, 'update'])->name('notifications.preferences.update');
    Route::patch('/profile/notifications/webhook', [NotificationPreferencesController::class, 'updateWebhook'])->name('notifications.preferences.webhook');
});
```

**`NotificationPreferencesController`:**
- `index()` — returns Inertia page `Profile/Notifications` with `eventTypes`, `channels` (short aliases), `preferences` matrix, `webhookUrl` (decrypted from `$request->user()->webhook_url`).
- `update()` — validates `event_type` in known list, `channel` in `['database','mail','webhook']`, `enabled` boolean; upserts `NotificationPreference`.
- `updateWebhook()` — validates `webhook_url` as `nullable|url|max:2048`; also validate scheme is `http` or `https` (422 otherwise); saves encrypted.

**Acceptance criteria (Pest):**

`NotificationsControllerTest`:
- `GET /notifications` → 200 for auth user; redirect to `/login` for guest.
- `PATCH /notifications/read-all` → read-all is NOT captured as `{id}` parameter (assert response 200, not 404/model-not-found).
- Insert 3 unread notifications for user A, 1 for user B → `PATCH /notifications/read-all` as user A → user A unread count = 0, user B unread count = 1.
- Insert notification directly via `DB::table('notifications')` → `PATCH /notifications/{id}/read` → `read_at` set.

`NotificationPreferencesControllerTest`:
- `GET /profile/notifications` → Inertia page has `eventTypes`, `channels`, `preferences`, `webhookUrl` props.
- `PATCH /profile/notifications` with valid data → row upserted → 200.
- Invalid `event_type` → 422.
- Invalid `channel` (`telegram`) → 422.
- `PATCH /profile/notifications/webhook` with `https://hooks.slack.com/x` → saved encrypted → 200.
- `PATCH /profile/notifications/webhook` with `ftp://bad.example` → 422.

- [ ] Write failing tests
- [ ] Write `NotificationsController`
- [ ] Write `NotificationPreferencesController` (includes `updateWebhook`)
- [ ] Add routes (read-all first)
- [ ] `php artisan test --filter="NotificationsControllerTest|NotificationPreferencesControllerTest"` → PASS
- [ ] Pint + commit

---

### Task 8: React — `useNotifications` hook + `NotificationBell` component

**Files:**
- Create: `resources/js/hooks/useNotifications.js`
- Create: `resources/js/Components/NotificationBell.jsx`
- Create: `resources/js/hooks/useNotifications.test.jsx`
- Create: `resources/js/Components/NotificationBell.test.jsx`

**`useNotifications()`:** reads `notifications.unreadCount` from `usePage().props` as initial value. Subscribes to `Echo.private('notifications.'+userId)`.listen('.NotificationCreated', e => setUnreadCount(e.unread_count))`. Cleanup: `channel.stopListening('.NotificationCreated')`. Returns `{ unreadCount, refresh }` where `refresh` resets count to 0 (for after mark-all-read).

**`NotificationBell`:** accepts optional `unreadCount` prop override (for testability — bypasses hook). When override absent, uses hook value. Renders `<Link href="/notifications">` + badge with `data-testid="notification-badge"` when count > 0.

**Acceptance criteria (Vitest):**

`useNotifications.test.jsx`:
- Initializes `unreadCount` from shared prop (mocked `usePage` returning `notifications.unreadCount: 2`).
- `.NotificationCreated` event with `{ unread_count: 5 }` → `unreadCount` becomes 5.

`NotificationBell.test.jsx`:
- `unreadCount` prop = 0 → no element with `data-testid="notification-badge"`.
- `unreadCount` prop = 3 → badge renders with text "3".

Run `npm run test` → all Vitest tests pass.

- [ ] Write failing Vitest tests
- [ ] Write `useNotifications.js`
- [ ] Write `NotificationBell.jsx` (prop override for testability)
- [ ] `npm run test` → PASS
- [ ] Commit

---

### Task 9: React pages + `TopNavi` integration

**Files:**
- Modify: `resources/js/Layouts/Partials/TopNavi.jsx` (add `<NotificationBell />`)
- Create: `resources/js/Pages/Notifications/Index.jsx`
- Create: `resources/js/Pages/Profile/Notifications.jsx` (reads `webhookUrl` prop, NOT `auth.user.webhook_url`)
- Modify: `resources/js/Pages/Profile/Edit.jsx` (link to `/profile/notifications`)

**`Pages/Profile/Notifications.jsx`:** reads `webhookUrl` from `props.webhookUrl` (passed by controller). Saves via `axios.patch('/profile/notifications/webhook', { webhook_url: ... })`. Shows preference matrix with short alias channel labels: `database`→"In-app", `mail`→"Email", `webhook`→"Webhook".

**Acceptance criteria:**
- `npm run build` → clean (no import errors).
- `npm run test` → all tests still pass.
- Manual: bell visible in nav, `/notifications` lists notifications, `/profile/notifications` shows matrix + webhook URL field (value populated from controller prop, not `auth.user`).

- [ ] Add `<NotificationBell />` to `TopNavi.jsx`
- [ ] Create `Pages/Notifications/Index.jsx`
- [ ] Create `Pages/Profile/Notifications.jsx` (use `props.webhookUrl`, not `auth.user`)
- [ ] Add link to `/profile/notifications` in `Profile/Edit.jsx`
- [ ] `npm run build` → clean
- [ ] `npm run test` → PASS
- [ ] Commit

---

## Final Verification Gate

- [ ] `docker exec laranode-lab bash -lc 'cd /home/laranode_ln/panel && php artisan test'` → all tests pass, zero skips (non-system tests)
- [ ] `npm run test` → all Vitest tests pass
- [ ] `./vendor/bin/pint --test` → exit 0
- [ ] `npm run build` → clean
- [ ] `php artisan schedule:list` → shows both `model:prune` (daily) and `ssl.expiring notifications` (08:00 daily)
- [ ] `LARANODE_SYSTEM_TESTS=1 php artisan test --filter=WebhookChannelTest --group=system` → SSRF localhost test passes
- [ ] Manual in-container: queue worker + Reverb active → enable SSL → operation finishes → bell increments without reload → `/notifications` shows entry → mark all read → badge clears → `/profile/notifications` matrix renders + webhook URL field populated (from controller prop) + toggle fires PATCH + webhook URL saves correctly → `notification_preferences` row appears in DB
