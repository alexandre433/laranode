# Sub-project #9 — Backups (`backups`)

- **Date:** 2026-06-26
- **Status:** Draft spec (pending user review)
- **Roadmap:** Phase 4, sub-project #9 of `docs/superpowers/specs/2026-06-25-laranode-feature-roadmap.md`
- **Branch:** `feature/backups` (off `main`)
- **Dependencies:** #1 `platform-async-progress` (shipped — `OperationJob`, `Operation` model, `OperationUpdated` event, `bootstrap/app.php` scheduler hook all present)

## Goal

Give every Laranode user on-demand and scheduled backups of their databases and website files, stored either locally on the host or uploaded to any S3-compatible bucket. Retain N recent backups and prune old ones automatically. Allow restore from any backup into a **new** named target only — never silent overwrite. Every backup and restore runs as an `OperationJob` so the user sees live progress, the audit table records it, and nothing blocks an HTTP request.

**Why now:** the `OperationJob` / Reverb / scheduler foundation from #1 makes this straightforward to implement correctly. Without that foundation this would have been blocking HTTP + no live progress + no audit.

## Success criteria

- Triggering an on-demand backup returns immediately with an `operation_id`; the dump/tar runs on the queue with live output streamed to the user.
- A scheduled backup runs daily (or at a user-configured cron expression) per job; old backups beyond the retention count are pruned in the same run.
- A user can browse, download, and delete their own backup files through the UI.
- Restore creates the target (new database name or new file path) — it never touches the original. The UI requires the user to name the restore target and confirm before dispatching.
- S3 credentials are stored encrypted (same `encrypted` cast pattern as `Database::$db_password`). The local disk stores files under the site owner's homedir backup path, not under `storage/app`.
- Feature tests (queue `sync`, faked Process + Storage) cover the dump, tar, upload, prune, and restore paths. Run green in the `local-dev` container.

## Architecture

Pattern: **Controller → FormRequest → Service (orchestration) → Action (single step) → `BackupJob`/`RestoreJob` extends `OperationJob`**. Storage uses the Laravel filesystem abstraction (`Storage::disk()`), so local and S3 are interchangeable behind the same interface — no branching in the job logic.

```
User triggers on-demand backup (POST /backups)
  → BackupController@store
    → CreateBackupRequest (validation)
      → BackupService::handle() — creates Backup row, resolves disk, dispatches BackupJob
        → BackupJob extends OperationJob::run($emit)
            → DumpDatabaseAction (if type=db)  OR  TarFilesAction (if type=files)
            → UploadToStorageAction  (streams to disk — local or S3)
            → Backup row updated with path, size
Scheduler (bootstrap/app.php withSchedule)
  → BackupSchedulerJob  — iterates due ScheduledBackup rows, dispatches BackupJob per entry
  → RetainBackupsAction — prunes backups over retention_count for each schedule
```

### Components

**1. `backups` table + `Backup` model**

Migration `create_backups_table`:
- `id`, `user_id` (FK users, cascade), `operation_id` (FK operations, nullable — null if created by scheduler before the operation row exists), `type` (`db` | `files`), `target` (the source: database name or website url), `storage` (`local` | `s3`), `disk_name` (string, nullable — the `config/filesystems.php` disk key resolved at backup time), `path` (string, nullable — relative path on the disk, set after upload), `size_bytes` (bigInteger, nullable), `status` (`pending` | `completed` | `failed`), `timestamps`.

`Backup` model (`App\Models\Backup`):
- `$fillable` for all above; `$casts`: `size_bytes` → integer.
- `belongsTo(User)`, `belongsTo(Operation)`.
- `scopeMine(Builder)` — mirrors `Website::scopeMine()` and `Database::scopeMine()` exactly: non-admins see own, admins see all.
- `MassPrunable` targeting rows `where('created_at', '<', now()->subDays(90))` (separate from `Operation` pruning; backup rows live longer).

**2. `scheduled_backups` table + `ScheduledBackup` model**

Migration `create_scheduled_backups_table`:
- `id`, `user_id` (FK users, cascade), `type` (`db` | `files`), `target` (db name or website url), `storage` (`local` | `s3`), `cron_expression` (string, default `0 2 * * *` — 2 AM daily), `retention_count` (integer, default 7), `s3_key` (text, encrypted, nullable), `s3_secret` (text, encrypted, nullable), `s3_region` (string, nullable), `s3_bucket` (string, nullable), `s3_endpoint` (string, nullable — for non-AWS S3), `enabled` (boolean, default true), `last_run_at` (timestamp, nullable), `timestamps`.

`ScheduledBackup` model (`App\Models\ScheduledBackup`):
- `$casts`: `s3_key` → `encrypted`, `s3_secret` → `encrypted`, `enabled` → `boolean`. Pattern matches `Database::$db_password`.
- `scopeMine(Builder)` — same pattern.
- `belongsTo(User)`.
- Note: for an on-demand backup with S3 storage, S3 credentials are passed through the `CreateBackupRequest` and stored transiently on the `BackupJob` constructor (not persisted to `Backup`). Only `ScheduledBackup` persists credentials. This avoids adding creds to the one-off `backups` table row.

**3. DB dump contract — `BackupEngineDriver` interface**

```php
// App\Contracts\Backup\BackupEngineDriver
interface BackupEngineDriver {
    /** Run the dump; stream output lines via $emit; return the local temp file path. */
    public function dump(string $dbName, string $dbUser, string $dbPassword, callable $emit): string;
}
```

Implementations:
- `App\Backup\Drivers\MysqlBackupDriver` — shells out to `laranode-db-backup.sh mysql $dbName $dbUser $dbPassword $tempFile` (a new whitelisted bash script). Streams the process output. Returns `$tempFile`.
- `App\Backup\Drivers\PostgresBackupDriver` — same convention for `pg_dump`; added when `db-postgres` (#3) ships. Skeleton can be registered to the manager immediately to prove extensibility without blocking.

`App\Backup\BackupEngineManager` — resolves a driver from a `Database` model's `engine` column (once #2 ships the `engine` column; until then, defaults to `mysql`). Mirrors the `EngineManager` pattern from #2.

**4. `DumpDatabaseAction`** (`App\Actions\Backup\DumpDatabaseAction`)

`execute(Database $database, string $tempPath, callable $emit): string` — resolves the engine driver via `BackupEngineManager`, calls `driver->dump(...)`, returns the temp file path.

**5. `TarFilesAction`** (`App\Actions\Backup\TarFilesAction`)

`execute(Website $website, string $tempPath, callable $emit): string` — runs:
```php
Process::run([
    'sudo', config('laranode.laranode_bin_path') . '/laranode-backup-files.sh',
    $website->websiteRoot, $tempPath, $website->user->systemUsername,
], fn ($type, $buf) => ...);
```
Runs as the site owner's system user (`{username}_ln`) via the script — consistent with how all other per-site privileged ops work. Returns `$tempPath`.

**6. `UploadToStorageAction`** (`App\Actions\Backup\UploadToStorageAction`)

`execute(string $localPath, string $storagePath, \Illuminate\Contracts\Filesystem\Filesystem $disk, callable $emit): void` — streams the local temp file to `$disk->putStream($storagePath, fopen($localPath, 'r'))`. The resolved disk is injected (not instantiated here) so the action is pure and easily faked in tests.

**7. New bash scripts** in `laranode-scripts/bin/`:
- `laranode-db-backup.sh $engine $dbName $dbUser $dbPassword $outFile` — runs `mysqldump` (or `pg_dump` later) as the appropriate user, writes to `$outFile`. **Not run inline; called by DumpDatabaseAction via the sudo-script convention.**
- `laranode-backup-files.sh $siteRoot $outFile $sysUser` — runs `tar czf $outFile -C $siteRoot .` as `$sysUser`, sets ownership back to `www-data`. Both scripts added to the `sudoers.d` drop-in, not the monolithic sudoers line, per the cross-cutting convention.

**8. `BackupJob extends OperationJob`** (`App\Jobs\BackupJob`)

```php
class BackupJob extends OperationJob {
    public function __construct(
        Operation $operation,
        public Backup $backup,
        public ?array $s3Config = null,   // null = use local disk
    ) { parent::__construct($operation); }

    protected function run(callable $emit): int {
        $tempFile = sys_get_temp_dir() . '/laranode-backup-' . uniqid() . '.tmp';
        try {
            if ($this->backup->type === 'db') {
                $db = \App\Models\Database::where('name', $this->backup->target)
                    ->where('user_id', $this->backup->user_id)->firstOrFail();
                (new DumpDatabaseAction)->execute($db, $tempFile, $emit);
            } else {
                $site = \App\Models\Website::where('url', $this->backup->target)
                    ->where('user_id', $this->backup->user_id)->firstOrFail();
                (new TarFilesAction)->execute($site, $tempFile, $emit);
            }
            $disk = $this->resolveDisk();
            $storagePath = $this->storagePath();
            (new UploadToStorageAction)->execute($tempFile, $storagePath, $disk, $emit);
            $this->backup->update([
                'path' => $storagePath,
                'size_bytes' => filesize($tempFile),
                'status' => 'completed',
            ]);
            $emit('Backup complete: ' . $storagePath);
            return 0;
        } finally {
            @unlink($tempFile); // always clean up the local temp file
        }
    }

    private function resolveDisk(): \Illuminate\Contracts\Filesystem\Filesystem { ... }
    private function storagePath(): string {
        // e.g. backups/{userId}/{type}/{target}/{Y-m-d-His}.tar.gz
    }
}
```

`SerializesModels` handles the `Backup` model across queue serialization. The `s3Config` array (plain values) serializes safely. The `finally` block ensures the temp file is removed even on failure — avoids orphaned disk usage.

**9. `RestoreJob extends OperationJob`** (`App\Jobs\RestoreJob`)

```php
class RestoreJob extends OperationJob {
    public function __construct(
        Operation $operation,
        public Backup $backup,
        public string $newTarget,        // NEW db name or NEW website url — never the original
        public ?array $s3Config = null,
    ) { parent::__construct($operation); }

    protected function run(callable $emit): int { ... }
}
```

For DB restores: downloads the dump to a temp file, creates the new DB (calls `CreateDatabaseService` to provision MySQL user + grant), then pipes the dump into the new schema. For file restores: downloads the tar, extracts to a new directory under the user's homedir. The `newTarget` is validated against existing names before dispatch so the job doesn't reach a destructive step only to fail there.

**10. `BackupService`** (`App\Services\Backups\BackupService`)

`handle(array $validated, User $user): Operation` — creates the `Backup` row, creates the `Operation` row (`type='backup.db'` or `'backup.files'`), dispatches `BackupJob`, returns the `Operation`. Pattern mirrors `CreateWebsiteService::handle()`.

`BackupException` — sibling class in the same file per project convention.

**11. `BackupController`** (`App\Http\Controllers\BackupController`)

Routes (auth-gated; non-admins see only own via `scopeMine`):
- `GET /backups` → `index` — Inertia `Backups/Index`, paginated `Backup::mine()->with('operation')->latest()->paginate(20)` + `ScheduledBackup::mine()->get()`.
- `POST /backups` → `store` — on-demand backup, returns JSON `{ operation_id }` (same pattern as `WebsiteController::toggleSsl`).
- `DELETE /backups/{backup}` → `destroy` — deletes the file from disk + the row; policy-gated.
- `GET /backups/{backup}/download` → `download` — streams from the storage disk; policy-gated; name reveals no internal paths.
- `POST /backups/{backup}/restore` → `restore` — validates `new_target`, creates `RestoreJob`, returns JSON `{ operation_id }`.
- `POST /backups/schedules` → `storeSchedule` — `CreateScheduledBackupRequest`, creates `ScheduledBackup` row.
- `DELETE /backups/schedules/{scheduledBackup}` → `destroySchedule`.

**12. Scheduler hook** — extends the existing `withSchedule` in `bootstrap/app.php`:

```php
$schedule->job(new \App\Jobs\RunScheduledBackupsJob)->everyMinute();
```

`RunScheduledBackupsJob` (a plain `ShouldQueue` job, not an `OperationJob`) queries `ScheduledBackup::where('enabled', true)->get()`, evaluates `CronExpression::isDue($entry->cron_expression)`, dispatches a `BackupJob` for each due entry, updates `last_run_at`. Also dispatches a `RetainBackupsJob` per entry to prune backups beyond `retention_count` on that target. The `everyMinute` cadence matches how Laravel's own scheduler works — `RunScheduledBackupsJob` itself is the "schedule runner" for user-defined schedules.

**13. React UI**

- `resources/js/Pages/Backups/Index.jsx` — table of backups (date, type, target, size, status badge, download / delete / restore actions) + a "Scheduled Backups" sub-table + an "On-demand backup" form (select type + target + storage). On form submit: POST via axios, receive `operation_id`, render `<OperationProgress operationId={...} onDone={() => router.reload()} />` inline (reusing the shipped component from #1).
- Restore flow: clicking Restore opens a modal with an input for `new_target` + a prominent warning ("This creates a new database/directory — the original is not touched"). Submit POSTs and shows the same `<OperationProgress>`.
- Reuses `useOperation` hook + `OperationProgress` component unchanged.

## Data model summary

```
backups
  id, user_id, operation_id (nullable FK), type, target, storage,
  disk_name, path, size_bytes, status, created_at, updated_at

scheduled_backups
  id, user_id, type, target, storage, cron_expression, retention_count,
  s3_key (encrypted), s3_secret (encrypted), s3_region, s3_bucket,
  s3_endpoint, enabled, last_run_at, created_at, updated_at
```

No new columns on `Website` or `Database`. Backups are a separate domain.

## Request / data flow (on-demand DB backup)

```
POST /backups { type: 'db', target: 'mydb', storage: 'local' }
  BackupController@store
    CreateBackupRequest validates: type ∈ {db,files}, target exists + mine, storage ∈ {local,s3}; if s3: key/secret/bucket required
    BackupService::handle($validated, $user)
      Backup::create([user_id, type, target, storage='local', status='pending'])
      Operation::create([user_id, type='backup.db', target='mydb', status='queued'])
      BackupJob::dispatch($operation, $backup)
    return response()->json(['operation_id' => $operation->id])   // 200
  (queue worker picks up BackupJob)
    operation->markRunning()
    DumpDatabaseAction->execute($db, $tempFile, $emit)  →  laranode-db-backup.sh (sudo)
    UploadToStorageAction->execute($tempFile, $storagePath, Storage::disk('local'), $emit)
    $backup->update(['path' => $storagePath, 'size_bytes' => ..., 'status' => 'completed'])
    operation->markFinished(0)
    (OperationUpdated events broadcast live via Reverb → useOperation hook → OperationProgress renders)
```

## Error handling

- Dump failure (nonzero exit from `laranode-db-backup.sh`): `DumpDatabaseAction` throws; `OperationJob::handle()` catches → `appendOutput('ERROR: ...')` + `markFinished(1)` + rethrows → `failed_jobs` records it. `Backup` row remains `pending` (not `completed`). The partial temp file is removed by the `finally` block.
- S3 upload failure: `UploadToStorageAction` throws `\League\Flysystem\FilesystemException`; same catch path.
- Restore target already exists: validated in `RestoreJob::run()` before any destructive step; emits an error line and returns exit code 1 without touching anything.
- Disk full (local): the tar/dump will fail; the error is captured and the temp file cleaned up. Log + mark failed.
- Queue worker down: operations sit `queued`; UI shows `queued` status honestly.

## Security

- **Restore requires explicit new_target:** the controller and job both assert `$newTarget !== $backup->target`. No implicit overwrite path exists.
- **Policy gates:** `BackupPolicy` (mirroring existing `DatabasePolicy`) — a user may only act on their own backups (`$user->id === $backup->user_id || $user->isAdmin()`).
- **S3 credentials** stored via `encrypted` cast on `ScheduledBackup`. Never logged or included in `OperationUpdated` broadcast payload. For on-demand S3 backups the creds travel only inside the queued job payload (queue payloads are stored in the DB encrypted-at-rest via MySQL; not exposed in the `Backup` row or any API response).
- **Local file path** — backups stored under the user's homedir, e.g. `/home/{username}_ln/backups/{type}/{target}/`, not under `storage/app` (which is the panel's private space). The `laranode-backup-files.sh` script runs as the `{username}_ln` system user and sets ownership appropriately. Download routes stream via Laravel's `Storage::disk()->readStream()` with no public URL exposed.
- **Sudo scripts** added via a new `sudoers.d` drop-in (`/etc/sudoers.d/laranode-backups`) — not appended to the monolithic sudoers line.
- **Footgun: restore is destructive.** UI must show an explicit warning. Controller rejects any `new_target` that already exists (a new `CREATE DATABASE` or `mkdir` would fail; better to fail early at validation with a clear message than deep in the job).

## Testing strategy

### Pest (feature tests, `tests/Feature/Backups/`)

- **`BackupModelTest`** — `Backup` + `ScheduledBackup` factories, `scopeMine` scoping, prunable target date.
- **`BackupJobTest`** — `Process::fake()` for the dump script (success + failure); `Storage::fake('local')`; assert temp file removed in both paths; assert `Backup` status `completed` vs `pending`; assert `Operation` lifecycle (`succeeded`/`failed`).
- **`BackupControllerTest`** — POST `/backups` as owner returns `{ operation_id }`; non-owner cannot trigger backup on another user's DB; delete removes file + row; download returns a streamed response; restore endpoint validates `new_target` not-empty + not-same-as-source.
- **`SchedulerBackupTest`** — `RunScheduledBackupsJob` dispatches `BackupJob` for due entries and skips disabled or not-yet-due ones; `RetainBackupsJob` deletes the oldest `Backup` rows beyond `retention_count` (ordered by `created_at` asc).
- **`RestoreJobTest`** — `Process::fake()`; `Storage::fake()`; assert new DB created by `CreateDatabaseService` (mock); assert error on duplicate `new_target`.
- **Engine-driver seam test** — a `NullBackupDriver` (in-test double implementing `BackupEngineDriver`) registered on `BackupEngineManager` in tests; proves the interface contract without a real mysqldump.

All tests use `QUEUE_CONNECTION=sync` (already set in `phpunit.xml`) so jobs run inline. `Event::fake()` for broadcast assertions.

### Container integration (`make test-system` with `LARANODE_SYSTEM_TESTS=1`)

- Real `laranode-db-backup.sh` dumps a known MySQL DB; verifies the output file is non-empty and valid SQL.
- Real `laranode-backup-files.sh` tars a small test directory; verifies the archive can be extracted.
- Restore job restores to a new DB name; verifies the restored DB contains the expected tables.

These are gated behind `LARANODE_SYSTEM_TESTS=1`, exercised in the `local-dev` Docker container only — same pattern as the SSL tests.

### Vitest (front-end)

- `Backups/Index.jsx` — render with static props; assert backup rows rendered; assert restore modal opens on button click; assert `new_target` input present before submission.
- Restore flow — mock axios POST; assert `<OperationProgress>` mounts with the returned `operation_id` (reuses the existing Echo mock pattern from `OperationProgress.test.jsx`).

## Back-compat / migration

No changes to existing models or migrations. Two new migrations, two new models, no column alterations. The existing `bootstrap/app.php` `withSchedule` callback gains one `$schedule->job(...)` line — additive only. Existing routes unchanged. The `BackupEngineDriver` interface is designed from the start to slot in the `PostgresBackupDriver` from #3 without modifying the `BackupJob` or `DumpDatabaseAction`.

If #2 (`db-engine-abstraction`) has not shipped yet when this branch lands, `BackupEngineManager` defaults to `mysql` unconditionally (no `engine` column to read). Once #2 ships, swapping to `$database->engine` is a one-line change.

## File inventory

```
database/migrations/XXXX_create_backups_table.php               (new)
database/migrations/XXXX_create_scheduled_backups_table.php     (new)
app/Models/Backup.php                                           (new)
app/Models/ScheduledBackup.php                                  (new)
app/Contracts/Backup/BackupEngineDriver.php                     (new)
app/Backup/Drivers/MysqlBackupDriver.php                        (new)
app/Backup/Drivers/PostgresBackupDriver.php                     (new — skeleton only)
app/Backup/BackupEngineManager.php                              (new)
app/Actions/Backup/DumpDatabaseAction.php                       (new)
app/Actions/Backup/TarFilesAction.php                           (new)
app/Actions/Backup/UploadToStorageAction.php                    (new)
app/Actions/Backup/RetainBackupsAction.php                      (new)
app/Services/Backups/BackupService.php                          (new, + BackupException)
app/Services/Backups/RestoreService.php                         (new, + RestoreException)
app/Jobs/BackupJob.php                                          (new)
app/Jobs/RestoreJob.php                                         (new)
app/Jobs/RunScheduledBackupsJob.php                             (new)
app/Jobs/RetainBackupsJob.php                                   (new)
app/Http/Controllers/BackupController.php                       (new)
app/Http/Requests/CreateBackupRequest.php                       (new)
app/Http/Requests/CreateScheduledBackupRequest.php              (new)
app/Http/Requests/RestoreBackupRequest.php                      (new)
app/Policies/BackupPolicy.php                                   (new)
routes/web.php                                                  (modify: backup routes)
bootstrap/app.php                                               (modify: add RunScheduledBackupsJob)
laranode-scripts/bin/laranode-db-backup.sh                      (new)
laranode-scripts/bin/laranode-backup-files.sh                   (new)
laranode-scripts/etc/sudoers.d/laranode-backups                 (new, sudoers drop-in)
resources/js/Pages/Backups/Index.jsx                            (new)
tests/Feature/Backups/BackupModelTest.php                       (new)
tests/Feature/Backups/BackupJobTest.php                         (new)
tests/Feature/Backups/BackupControllerTest.php                  (new)
tests/Feature/Backups/SchedulerBackupTest.php                   (new)
tests/Feature/Backups/RestoreJobTest.php                        (new)
resources/js/Pages/Backups/Backups.test.jsx                     (new, Vitest)
```

## Out of scope

- Encrypting the backup archive at rest (beyond S3 server-side encryption, which the S3 disk handles transparently).
- Cross-user restores (admin restoring a user's backup into a different user's account).
- Incremental backups (full dump/tar only for v1).
- Backup verification (checking the dump is valid SQL before marking complete) — defer; add `verify` step later.
- A dedicated `BackupStorageDriver` abstraction for SFTP/Backblaze — S3-compatible covers the common case; revisit if needed.

## Open questions

1. **On-demand S3 creds UX:** Should the UI offer "use the same S3 config as an existing scheduled backup" as a shortcut, or always require re-entering for one-off S3 backups? (Re-entering is simpler and avoids surfacing persisted secrets to the UI; shortcut is more ergonomic.)
2. **Local storage path:** Storing under `/home/{username}_ln/backups/` puts backup files on the same disk as user data. Should there be a global `BACKUP_LOCAL_ROOT` config value (defaulting to the homedir path) so an admin can point it at a separate volume or mount?
3. **Retention granularity:** Is `retention_count` (keep last N) sufficient, or should the spec add a `retention_days` alternative? Keeping only one knob simplifies the UI; YAGNI unless asked.
4. **RunScheduledBackupsJob cadence:** `everyMinute()` means at most 1-minute delay for any user-defined schedule. If the user base grows and many schedules run at 2 AM, this could pile up. For now the `database` queue serializes them naturally. Flag this if load becomes a concern.
5. **File backup scope:** should "files" back up the entire `websiteRoot` (including `node_modules`/`.git` etc.) or only the `fullDocumentRoot`? Backing up `fullDocumentRoot` is smaller and more useful; backing up `websiteRoot` captures more (git repo, uploads above docroot). Decision needed before writing the bash script.
6. **Download security for large backups:** streaming through Laravel is fine for small/medium archives, but a 2 GB tarball streaming through PHP is inefficient. A pre-signed S3 URL (for S3 storage) or an Apache `X-Sendfile` passthrough (for local) would be better for large files. Decide whether to handle this in v1 or defer.
