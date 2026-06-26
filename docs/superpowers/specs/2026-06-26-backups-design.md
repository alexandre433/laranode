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
- A scheduled backup runs daily (or at a user-configured cron expression) per entry; old backups beyond the retention count are pruned in the same run.
- A user can browse, download, and delete their own backup files through the UI.
- Restore creates the target (new database name or new file path) — it never touches the original. The UI requires the user to name the restore target and confirm before dispatching.
- S3 credentials are stored encrypted (same `encrypted` cast pattern as `Database::$db_password`). The local disk stores files under the site owner's homedir backup path, not under `storage/app`.
- Feature tests (queue `sync`, faked Process + Storage) cover the dump, tar, upload, prune, and restore paths. Run green in the `local-dev` container.

## Architecture

Pattern: **Controller → FormRequest → Service (orchestration) → `BackupJob`/`RestoreJob` extends `OperationJob`** → bash scripts (privileged). Storage uses the Laravel filesystem abstraction (`Storage::disk()`), so local and S3 are interchangeable behind the same interface — no branching in the job logic beyond disk resolution.

```
User triggers on-demand backup (POST /backups)
  → BackupController@store
    → CreateBackupRequest (validation, including target-ownership check)
      → BackupService::handle() — creates Backup row, resolves disk key, dispatches BackupJob
        → BackupJob extends OperationJob::run($emit)
            → DumpDatabaseAction (if type=db)  OR  TarFilesAction (if type=files)
            → UploadToStorageAction  (streams to disk — local or S3)
            → Backup row updated with path, size, disk_name
Scheduler (bootstrap/app.php withSchedule)
  → RunScheduledBackupsJob (ShouldBeUnique, everyMinute) — iterates due ScheduledBackup rows,
      dispatches BackupJob per entry, updates last_run_at, dispatches RetainBackupsJob
  → RetainBackupsJob — prunes backups over retention_count for each schedule
```

### Components

**1. `backups` table + `Backup` model**

Migration `create_backups_table`:
- `id`, `user_id` (FK users, cascade), `operation_id` (FK operations, nullable, set null on delete), `type` (`db` | `files`), `target` (source: database name or website url), `storage` (`local` | `s3`), `disk_name` (string, non-nullable after creation — the `config/filesystems.php` key resolved at backup time, e.g. `backups` for local or `backups_s3` for S3), `path` (string, nullable — relative path on the disk, set after upload), `size_bytes` (bigInteger, nullable), `status` (`pending` | `completed` | `failed`), `timestamps`.

`Backup` model (`App\Models\Backup`):
- `$fillable` for all above; `$casts`: `size_bytes` → integer.
- `belongsTo(User)`, `belongsTo(Operation)`.
- `scopeMine(Builder)` — mirrors `Database::scopeMine()` (line 49) exactly.
- `MassPrunable` targeting rows `where('created_at', '<', now()->subDays(90))`. The `pruning` Eloquent hook also deletes any orphaned files from the disk before the row is deleted, so disk and DB stay in sync.

**2. `scheduled_backups` table + `ScheduledBackup` model**

Migration `create_scheduled_backups_table`:
- `id`, `user_id` (FK users, cascade), `type` (`db` | `files`), `target` (db name or website url), `storage` (`local` | `s3`), `disk_name` (string, nullable — resolved disk key, same as on `Backup`), `cron_expression` (string, default `0 2 * * *` — 2 AM daily), `retention_count` (integer, default 7), `s3_key` (text, encrypted, nullable), `s3_secret` (text, encrypted, nullable), `s3_region` (string, nullable), `s3_bucket` (string, nullable), `s3_endpoint` (string, nullable — for non-AWS S3-compatible endpoints), `enabled` (boolean, default true), `last_run_at` (timestamp, nullable), `timestamps`.

`ScheduledBackup` model (`App\Models\ScheduledBackup`):
- `$casts`: `s3_key` → `encrypted`, `s3_secret` → `encrypted`, `enabled` → `boolean`. Pattern matches `Database::$db_password` (`app/Models/Database.php` line 21-23).
- `scopeMine(Builder)` — same pattern.
- `belongsTo(User)`.

**S3 credential lifecycle:** S3 credentials for a `ScheduledBackup` are persisted encrypted on the row and read inside the job (never passed as job constructor arguments in plaintext). For on-demand S3 backups, `BackupService` resolves a runtime disk key (registered in config at dispatch time) and persists that key on the `Backup` row — the raw key/secret are never placed in the queue payload.

**3. `backups` filesystem disk in `config/filesystems.php`**

Add a dedicated `backups` disk (local driver), root configurable via `BACKUP_LOCAL_ROOT` env var defaulting to the panel root's relative `../backups` or, more practically, resolved per-job from the user's homedir. Because each backup's path already encodes `{userId}/`, a single disk root of `/home` is sufficient and simple:

```php
'backups' => [
    'driver' => 'local',
    'root'   => env('BACKUP_LOCAL_ROOT', '/home'),
    'throw'  => true,
],
```

Resolved `disk_name` values: `'backups'` for local; `'backups_s3_{scheduledBackupId}'` (runtime-registered per S3 schedule, never persisted to the disk config, registered by the job from the encrypted row). The `disk_name` stored on a `Backup` row is what `download` and `delete` use — so S3 backups require the S3 disk to be re-registered at download/delete time (same pattern as at backup time, reading from the `ScheduledBackup` row or the request payload).

**4. Composer dependency: `league/flysystem-aws-s3-v3`**

`composer require league/flysystem-aws-s3-v3` is an explicit required task. Without it every S3 path throws a `League\Flysystem\FilesystemException` at runtime. This must be done before any S3 code is written.

**5. DB password to dump script — `--defaults-extra-file`**

The dump script receives the DB password via a temp `--defaults-extra-file` (a `.cnf` file written to a `chmod 0600` temp path, deleted after the dump), not via argv. This prevents the password appearing in `ps aux` output or command logs:

```bash
# laranode-db-backup.sh receives: <engine> <dbName> <dbUser> <cnfFile> <outFile>
# The cnfFile contains: [client]\npassword=...
mysqldump --defaults-extra-file="$CNF_FILE" --user="$DB_USER" \
  --single-transaction --quick --lock-tables=false \
  "$DB_NAME" | gzip > "$OUT_FILE"
```

The PHP side writes the temp `.cnf` file before calling the script, passes its path, and cleans up in a `finally` block — same pattern as the temp dump file.

**6. DB restore — route through `CreateDatabaseService`**

`RestoreJob` for a DB restore does NOT issue a bare `CREATE DATABASE` SQL statement. Instead it calls `CreateDatabaseService` to provision the new database and a per-site MySQL user with grants, then pipes the dump. This ensures the restored DB gets a panel `Database` row and a properly privileged user — not an orphaned schema with no panel record.

The `new_target` for a DB restore is validated in `RestoreBackupRequest` with strict identifier rules: `/^[a-zA-Z0-9_]{1,64}$/` — no spaces, no backticks, no SQL-injectable characters. The same regex is re-validated inside `RestoreJob::run()` before any database operation (defence in depth).

**7. `BackupEngineDriver` interface + `MysqlBackupDriver`**

```php
// App\Contracts\Backup\BackupEngineDriver
interface BackupEngineDriver {
    /** Run the dump; stream output lines via $emit; return the local temp file path. */
    public function dump(string $dbName, string $dbUser, string $cnfFile, callable $emit): string;
}
```

`MysqlBackupDriver` shells out to `laranode-db-backup.sh`. It writes the temp `.cnf` file, passes its path as an argument (not the password itself), and cleans up the `.cnf` file in a `finally` block.

`BackupEngineManager` resolves the driver from the `engine` field (defaults to `mysql` until #2 ships). `PostgresBackupDriver` is a skeleton stub throwing `LogicException`.

**8. `DumpDatabaseAction`** (`App\Actions\Backup\DumpDatabaseAction`)

`execute(Database $database, string $tempPath, callable $emit): string` — resolves engine driver, calls `driver->dump(dbName, dbUser, cnfPath, $emit)`. The decrypted password (`$database->db_password` via the `encrypted` cast) is written to the temp `.cnf` by the driver, never passed to PHP's `Process::run` argv.

**9. `TarFilesAction`** (`App\Actions\Backup\TarFilesAction`)

`execute(Website $website, string $tempPath, callable $emit): string` — archives `$website->websiteRoot` (the full site directory — includes git repos, uploads, everything above docroot; `fullDocumentRoot` is inside `websiteRoot` and is the served content; backing up `websiteRoot` is the safer complete snapshot). Calls `laranode-backup-files.sh` via sudo.

**10. `UploadToStorageAction`** (`App\Actions\Backup\UploadToStorageAction`)

`execute(string $localPath, string $storagePath, Filesystem $disk, callable $emit): void` — streams via `putStream`. The disk is injected, not instantiated here.

**11. `RetainBackupsAction`** (`App\Actions\Backup\RetainBackupsAction`)

`execute(int $userId, string $type, string $target, int $retentionCount, Filesystem $disk): void` — fetches completed backups oldest-first, deletes files and rows for any beyond `retentionCount`. Also deletes the orphaned file from disk when removing a row.

**12. New bash scripts** in `laranode-scripts/bin/`:
- `laranode-db-backup.sh <engine> <dbName> <dbUser> <cnfFile> <outFile>` — runs `mysqldump --defaults-extra-file=$cnfFile` as the appropriate user, pipes through `gzip`. Does not log the password. Checks exit code of mysqldump and gzip separately (use `pipefail`).
- `laranode-backup-files.sh <siteRoot> <outFile> <sysUser>` — `tar czf $outFile -C $siteRoot .`; sets ownership to `www-data` on the output file.
- `laranode-restore-files.sh <tarFile> <destDir> <sysUser>` — `mkdir -p $destDir && tar xzf $tarFile -C $destDir`; sets ownership to `$sysUser:$sysUser`.

All three scripts are listed in the sudoers drop-in `laranode-scripts/etc/sudoers.d/laranode-backups`. The installer's monolithic `/etc/sudoers` line (which uses a `*.sh` wildcard and already covers all scripts in `bin/`) is **narrowed once** in this feature: replace the wildcard with explicit paths for each existing script plus the three new ones. This is safer than adding a redundant drop-in that conflicts with the existing wildcard. The installer change is: replace the `>> /etc/sudoers` append with a `visudo`-safe write via a heredoc to `/etc/sudoers.d/laranode-panel` (explicit list, mode 0440).

**13. `BackupJob extends OperationJob`** (`App\Jobs\BackupJob`)

Constructor: `(Operation $operation, Backup $backup)`. The backup row already has `disk_name` set by `BackupService` before dispatch. For S3 schedules, `RunScheduledBackupsJob` sets `disk_name` to `'backups_s3'` and registers a runtime disk config keyed on that name from the encrypted `ScheduledBackup` credentials — the job reads the credentials from the `ScheduledBackup` row via the model, not from the job payload.

The `run(callable $emit)` method:
1. Resolves disk from `$this->backup->disk_name`.
2. Calls dump or tar action to a `sys_get_temp_dir()` temp file.
3. Calls `UploadToStorageAction` to stream the file to disk.
4. Updates `Backup` with `path`, `size_bytes`, `status='completed'`.
5. Temp file removed in `finally`.

**14. `BackupService`** (`App\Services\Backups\BackupService`)

`handle(array $validated, User $user): Operation` — creates the `Backup` row (with `disk_name` resolved), creates the `Operation` row, dispatches `BackupJob`, returns the `Operation`. For on-demand S3: registers a named runtime disk in `config(['filesystems.disks.backups_s3' => ...])` from the request's (validated, not persisted) S3 params, sets `disk_name = 'backups_s3'` on the `Backup` row, then dispatches the job. The raw credentials are not stored on the `Backup` row or in the job payload — they are lost after the request; the user must re-enter them for a new on-demand S3 backup. (This is the resolved default: always re-enter for one-off S3 — simpler, avoids surfacing secrets to UI.)

`BackupException` — sibling class in same file per project convention.

**15. `RestoreJob extends OperationJob`** (`App\Jobs\RestoreJob`)

Constructor: `(Operation $operation, Backup $backup, string $newTarget)`. No S3 config in constructor. The job reads the disk from `$backup->disk_name` (and for S3, re-registers the runtime disk from the `ScheduledBackup` row linked to the backup).

For DB restores:
1. Downloads dump to temp file from `Storage::disk($backup->disk_name)`.
2. Re-validates `$newTarget` against `/^[a-zA-Z0-9_]{1,64}$/` and asserts it differs from `$backup->target`.
3. Calls `CreateDatabaseService` to create the MySQL DB + user + grant + panel row.
4. Pipes the dump into the new schema via `laranode-restore-db.sh` (a new script that takes `<cnfFile> <dumpFile> <dbName>` and runs `zcat $dumpFile | mysql --defaults-extra-file=$cnfFile $dbName`).

For file restores: downloads tar, calls `laranode-restore-files.sh` via sudo.

**16. `RestoreService`** (`App\Services\Backups\RestoreService`)

`handle(Backup $backup, string $newTarget, User $user): Operation` — creates `Operation`, dispatches `RestoreJob`. `RestoreException` sibling.

**17. `ScheduledBackupPolicy`** (`App\Policies\ScheduledBackupPolicy`)

Explicit policy for `ScheduledBackup` mirroring `DatabasePolicy`. The `destroySchedule` controller action calls `Gate::authorize('delete', $scheduledBackup)` — without this policy the gate is unguarded and any authenticated user can delete any schedule.

**18. `BackupPolicy`** (`App\Policies\BackupPolicy`)

Mirrors `DatabasePolicy` exactly. `view`, `update`, `delete` methods check `$user->isAdmin() || $user->id === $backup->user_id`.

**19. `BackupController`** (`App\Http\Controllers\BackupController`)

Routes (auth-gated; non-admins see only own via `scopeMine`):
- `GET /backups` → `index` — Inertia `Backups/Index`, paginated `Backup::mine()->with('operation')->latest()->paginate(20)` + `ScheduledBackup::mine()->get()`.
- `POST /backups` → `store` — on-demand backup, returns JSON `{ operation_id }`.
- `DELETE /backups/{backup}` → `destroy` — deletes file from disk + row; policy-gated.
- `GET /backups/{backup}/download` → `download` — for S3 storage: returns a presigned URL (redirect); for local storage: streams via `Storage::disk()->readStream()`. Policy-gated. No size cap in v1 for local; presigned URL is the efficient path for S3.
- `POST /backups/{backup}/restore` → `restore` — validates `new_target`, dispatches `RestoreJob`, returns JSON `{ operation_id }`.
- `POST /backups/schedules` → `storeSchedule` — `CreateScheduledBackupRequest`, creates `ScheduledBackup` row.
- `DELETE /backups/schedules/{scheduledBackup}` → `destroySchedule` — policy-gated via `ScheduledBackupPolicy`.

Add a **nav link** for `/backups` in the authenticated layout (alongside Websites, MySQL, etc.) so the page is discoverable.

**20. Scheduler hook** — extends the existing `withSchedule` in `bootstrap/app.php`:

```php
$schedule->job(new \App\Jobs\RunScheduledBackupsJob)->everyMinute();
```

`RunScheduledBackupsJob` implements both `ShouldQueue` and `ShouldBeUnique`. The `ShouldBeUnique` constraint means if the `everyMinute` tick fires while a previous invocation is still running (e.g. many schedules are due at 2 AM), a second instance will not be dispatched — preventing double-fires and the resulting duplicate backups.

As an additional guard, `RunScheduledBackupsJob::handle()` skips any entry whose `last_run_at` is within the last 50 seconds, preventing re-processing if uniqueness is temporarily bypassed (e.g. the unique lock expired before the job finished).

**21. React UI**

- `resources/js/Pages/Backups/Index.jsx` — table of backups (date, type, target, size, status badge, download / delete / restore actions) + a "Scheduled Backups" sub-table + an "On-demand backup" form (select type + target + storage). On form submit: POST via axios, receive `operation_id`, render `<OperationProgress operationId={...} onDone={() => router.reload()} />` inline (reusing the shipped component from #1).
- Restore flow: clicking Restore opens a modal with a labelled `new_target` input + a prominent warning ("This creates a new database/directory — the original is not touched"). Submit POSTs to `backups.restore` and shows the same `<OperationProgress>`.
- Reuses `useOperation` hook + `OperationProgress` component unchanged.
- Add nav link in `AuthenticatedLayout` pointing to `route('backups.index')`.

## Data model summary

```
backups
  id, user_id, operation_id (nullable FK), type, target, storage,
  disk_name, path, size_bytes, status, created_at, updated_at

scheduled_backups
  id, user_id, type, target, storage, disk_name, cron_expression, retention_count,
  s3_key (encrypted), s3_secret (encrypted), s3_region, s3_bucket,
  s3_endpoint, enabled, last_run_at, created_at, updated_at
```

No new columns on `Website` or `Database`. Backups are a separate domain.

## Request / data flow (on-demand DB backup)

```
POST /backups { type: 'db', target: 'mydb', storage: 'local' }
  BackupController@store
    CreateBackupRequest validates:
      type ∈ {db,files}
      target exists in databases WHERE user_id = auth user (ownership enforced at FormRequest)
      storage ∈ {local,s3}
      if s3: s3_key, s3_secret, s3_bucket, s3_region required
    BackupService::handle($validated, $user)
      Backup::create([user_id, type, target, storage='local', disk_name='backups', status='pending'])
      Operation::create([user_id, type='backup.db', target='mydb', status='queued'])
      $backup->update(['operation_id' => $operation->id])
      BackupJob::dispatch($operation, $backup)
    return response()->json(['operation_id' => $operation->id])   // 200
  (queue worker picks up BackupJob)
    operation->markRunning()
    DumpDatabaseAction->execute($db, $tempFile, $emit)
      MysqlBackupDriver->dump() writes .cnf, calls sudo laranode-db-backup.sh, cleans .cnf
    UploadToStorageAction->execute($tempFile, $storagePath, Storage::disk('backups'), $emit)
    $backup->update(['path' => $storagePath, 'size_bytes' => ..., 'status' => 'completed'])
    operation->markFinished(0)
    (OperationUpdated events broadcast live via Reverb → useOperation hook → OperationProgress renders)
```

## Error handling

- Dump failure (nonzero exit from `laranode-db-backup.sh`): `MysqlBackupDriver` throws; `OperationJob::handle()` catches → `appendOutput('ERROR: ...')` + `markFinished(1)` + rethrows → `failed_jobs` records it. `Backup` row remains `pending`. Temp file and `.cnf` file removed by `finally` blocks.
- S3 upload failure: `UploadToStorageAction` throws `\League\Flysystem\FilesystemException`; same catch path.
- Restore `new_target` fails identifier validation: `RestoreBackupRequest` returns 422 before dispatch. `RestoreJob` re-validates as defence in depth and emits an error line returning exit code 1.
- `CreateDatabaseService` fails during restore (e.g. name collision): throws `CreateDatabaseException`; job marks failed; no partial DB state (the service rolls back on user-creation failure).
- Disk full (local): the tar/dump fails; error captured; temp file cleaned up; operation marked failed.
- Queue worker down: operations sit `queued`; UI shows `queued` status honestly.

## Security

- **Restore requires explicit new_target:** validated in `RestoreBackupRequest` (regex `/^[a-zA-Z0-9_]{1,64}$/`, must differ from source) AND re-validated inside `RestoreJob::run()`. No implicit overwrite path exists.
- **DB restore goes through `CreateDatabaseService`:** no orphaned database schemas; every restored DB gets a panel row + per-site user.
- **Policy gates:** `BackupPolicy` (own backups) and `ScheduledBackupPolicy` (own schedules) — both gate every destructive action. `destroySchedule` is explicitly gated, not unguarded.
- **S3 credentials** stored via `encrypted` cast on `ScheduledBackup`. Never logged, never in `OperationUpdated` broadcast payload, never in the job constructor payload for scheduled backups. For on-demand S3 the creds are used transiently in the request lifecycle to register a runtime disk; they are not persisted.
- **DB password to dump script** travels via a `--defaults-extra-file` temp `.cnf` file (mode 0600), not via argv — invisible to `ps aux`. The `.cnf` is deleted in a `finally` block.
- **Local file path** — backups stored under `/home/{username}_ln/` (via the `backups` disk with root `/home`), not under `storage/app`.
- **Sudoers** — the monolithic wildcard line in `/etc/sudoers` is narrowed to an explicit list in `/etc/sudoers.d/laranode-panel` (mode 0440). The backup scripts are added to the same explicit list. One change, not two conflicting mechanisms.
- **Download** — local backups stream via `Storage::disk()->readStream()`; S3 backups return a presigned URL (short TTL redirect). No public URL exposed.

## Testing strategy

### Pest (feature tests, `tests/Feature/Backups/`)

- **`BackupModelTest`** — `Backup` + `ScheduledBackup` factories, `scopeMine` scoping, prunable target date.
- **`BackupJobTest`** — `Process::fake()` for the dump script (success + failure); `Storage::fake('backups')`; assert temp file removed in both paths; assert `Backup` status `completed` vs `pending`; assert `Operation` lifecycle (`succeeded`/`failed`).
- **`BackupControllerTest`** — POST `/backups` as owner returns `{ operation_id }`; non-owner cannot trigger backup on another user's DB (422); delete removes file + row; download returns a streamed response; restore endpoint returns 422 for empty or same-as-source `new_target`; restore endpoint returns 422 for `new_target` that fails identifier regex; `destroySchedule` returns 403 for non-owner.
- **`SchedulerBackupTest`** — `RunScheduledBackupsJob` dispatches `BackupJob` for due entries; skips disabled entries; skips recently-run entries (`last_run_at` within 50 seconds); updates `last_run_at`; `RetainBackupsJob` deletes oldest `Backup` rows beyond `retention_count`; scheduler registration asserts both `RunScheduledBackupsJob everyMinute` and `model:prune` with `Backup`.
- **`RestoreJobTest`** — `Process::fake()`; `Storage::fake('backups')`; assert `CreateDatabaseService` called (mock); assert error on duplicate `new_target`; assert error on `new_target` failing identifier validation; assert error when `new_target === source`.
- **Engine-driver seam test** — a `NullBackupDriver` (in-test double) proves the interface without real mysqldump.

All tests use `QUEUE_CONNECTION=sync`. `Event::fake()` for broadcast assertions.

### Container integration (`make test-system` with `LARANODE_SYSTEM_TESTS=1`)

- Real `laranode-db-backup.sh` dumps a known MySQL DB via `--defaults-extra-file`; verifies the output file is non-empty gzip (magic bytes `1f8b`).
- Real `laranode-backup-files.sh` tars a small test directory; verifies the archive extracts correctly.
- Restore job restores to a new DB name via `CreateDatabaseService`; verifies the restored DB contains the expected tables and a panel `Database` row exists.

These are gated behind `LARANODE_SYSTEM_TESTS=1`, exercised in the `local-dev` Docker container — same pattern as the SSL tests.

### Vitest (front-end)

- `Backups/Index.jsx` — render with static props; assert backup rows rendered; assert restore modal opens on button click; assert `new_target` input present and warning text visible before submission.
- Restore flow — mock axios POST; assert `<OperationProgress>` mounts with the returned `operation_id` (reuses the existing Echo mock pattern from `OperationProgress.test.jsx`).

## Back-compat / migration

No changes to existing models or migrations. Two new migrations, two new models, no column alterations. `bootstrap/app.php` `withSchedule` gains `RunScheduledBackupsJob` and `Backup` added to the `model:prune` array — additive only. Existing routes unchanged. The nav link addition to `AuthenticatedLayout` is additive.

The `BackupEngineDriver` interface slots in the `PostgresBackupDriver` from #3 without modifying `BackupJob` or `DumpDatabaseAction`.

If #2 (`db-engine-abstraction`) has not shipped, `BackupEngineManager` defaults to `mysql` unconditionally. Once #2 ships, swapping to `$database->engine` is a one-line change.

## File inventory

```
config/filesystems.php                                          (modify: add backups disk)
database/migrations/XXXX_create_backups_table.php               (new)
database/migrations/XXXX_create_scheduled_backups_table.php     (new)
app/Models/Backup.php                                           (new)
app/Models/ScheduledBackup.php                                  (new)
app/Contracts/Backup/BackupEngineDriver.php                     (new)
app/Backup/Drivers/MysqlBackupDriver.php                        (new)
app/Backup/Drivers/PostgresBackupDriver.php                     (new — skeleton stub)
app/Backup/BackupEngineManager.php                              (new)
app/Actions/Backup/DumpDatabaseAction.php                       (new)
app/Actions/Backup/TarFilesAction.php                           (new)
app/Actions/Backup/UploadToStorageAction.php                    (new)
app/Actions/Backup/RetainBackupsAction.php                      (new)
app/Services/Backups/BackupService.php                          (new, + BackupException)
app/Services/Backups/RestoreService.php                         (new, + RestoreException)
app/Jobs/BackupJob.php                                          (new)
app/Jobs/RestoreJob.php                                         (new)
app/Jobs/RunScheduledBackupsJob.php                             (new, ShouldBeUnique)
app/Jobs/RetainBackupsJob.php                                   (new)
app/Http/Controllers/BackupController.php                       (new)
app/Http/Requests/CreateBackupRequest.php                       (new)
app/Http/Requests/CreateScheduledBackupRequest.php              (new)
app/Http/Requests/RestoreBackupRequest.php                      (new, identifier regex validation)
app/Policies/BackupPolicy.php                                   (new)
app/Policies/ScheduledBackupPolicy.php                          (new)
routes/web.php                                                  (modify: backup routes)
bootstrap/app.php                                               (modify: add RunScheduledBackupsJob + Backup to prune)
laranode-scripts/bin/laranode-db-backup.sh                      (new, --defaults-extra-file)
laranode-scripts/bin/laranode-backup-files.sh                   (new)
laranode-scripts/bin/laranode-restore-files.sh                  (new)
laranode-scripts/bin/laranode-restore-db.sh                     (new, --defaults-extra-file)
laranode-scripts/etc/sudoers.d/laranode-panel                   (new — replaces monolithic wildcard)
laranode-scripts/bin/laranode-installer.sh                      (modify: install sudoers.d/laranode-panel)
resources/js/Pages/Backups/Index.jsx                            (new)
resources/js/Layouts/AuthenticatedLayout.jsx                    (modify: add nav link)
tests/Feature/Backups/BackupModelTest.php                       (new)
tests/Feature/Backups/BackupJobTest.php                         (new)
tests/Feature/Backups/BackupControllerTest.php                  (new)
tests/Feature/Backups/SchedulerBackupTest.php                   (new)
tests/Feature/Backups/RestoreJobTest.php                        (new)
tests/Feature/Backups/BackupSystemTest.php                      (new, LARANODE_SYSTEM_TESTS=1)
resources/js/Pages/Backups/Backups.test.jsx                     (new, Vitest)
```

## Out of scope

- Encrypting the backup archive at rest (beyond S3 server-side encryption).
- Cross-user restores (admin restoring a user's backup into a different user's account).
- Incremental backups (full dump/tar only for v1).
- Backup verification (checking the dump is valid SQL before marking complete).
- A dedicated `BackupStorageDriver` abstraction for SFTP/Backblaze — S3-compatible covers the common case.
- "Use an existing schedule's S3 config" shortcut for on-demand backups (re-entering is simpler and avoids surfacing persisted secrets to the UI — **resolved default: always re-enter for one-off S3**).
- Size cap or progress for large local downloads — streamed via PHP for v1; presigned URL for S3 (**resolved default: presigned S3 URL / streamed local, no size cap v1**).
- `retention_days` alternative to `retention_count` — single `retention_count` knob is sufficient for v1 (**resolved default: count only**).
