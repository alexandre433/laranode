<?php

namespace App\Jobs;

use App\Actions\Backup\DumpDatabaseAction;
use App\Actions\Backup\TarFilesAction;
use App\Actions\Backup\UploadToStorageAction;
use App\Models\Backup;
use App\Models\Database as DatabaseModel;
use App\Models\Operation;
use App\Models\Website;
use Illuminate\Support\Facades\Storage;

class BackupJob extends OperationJob
{
    public function __construct(Operation $operation, public Backup $backup)
    {
        parent::__construct($operation);
    }

    protected function run(callable $emit): int
    {
        $backup = $this->backup;
        $user = $backup->user;

        // Storage path: "{userId}/{type}/{target}/{Y-m-d-His}.{ext}"
        $ext = $backup->type === 'db' ? 'sql.gz' : 'tar.gz';
        $remotePath = sprintf(
            '%d/%s/%s/%s.%s',
            $user->id,
            $backup->type,
            $backup->target,
            now()->format('Y-m-d-His'),
            $ext
        );

        // Pre-create temp path; the action may replace it (e.g. MysqlBackupDriver
        // creates its own temp file and returns that path instead).
        $tempBase = tempnam(sys_get_temp_dir(), 'laranode-backup-');
        $tempPath = $tempBase.'.'.$ext;
        rename($tempBase, $tempPath);

        try {
            if ($backup->type === 'db') {
                $database = DatabaseModel::where('name', $backup->target)
                    ->where('user_id', $user->id)
                    ->firstOrFail();

                // Driver may return a different temp path (e.g. the one it created)
                $tempPath = app(DumpDatabaseAction::class)
                    ->execute($database, $tempPath, $emit);
            } else {
                $website = Website::where('url', $backup->target)
                    ->where('user_id', $user->id)
                    ->firstOrFail();

                $tempPath = app(TarFilesAction::class)
                    ->execute($website, $tempPath, $emit);
            }

            $disk = Storage::disk($backup->disk_name);

            app(UploadToStorageAction::class)
                ->execute($tempPath, $remotePath, $disk, $emit);

            $sizeBytes = file_exists($tempPath) ? filesize($tempPath) : null;

            $backup->update([
                'status' => 'completed',
                'path' => $remotePath,
                'size_bytes' => $sizeBytes,
            ]);

            $emit('Backup completed successfully.');

            return 0;
        } finally {
            if (file_exists($tempPath)) {
                unlink($tempPath);
            }
        }
    }
}
