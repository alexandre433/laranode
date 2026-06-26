<?php

namespace App\Services\Backups;

use App\Jobs\BackupJob;
use App\Models\Backup;
use App\Models\Operation;
use App\Models\User;
use Exception;
use Illuminate\Support\Facades\Config;

class BackupException extends Exception {}

class BackupService
{
    /**
     * Create the Backup + Operation rows, register any runtime S3 disk, and dispatch BackupJob.
     *
     * @param  array{type: string, target: string, storage: string, s3_key?: string, s3_secret?: string, s3_region?: string, s3_bucket?: string, s3_endpoint?: string}  $data
     */
    public function handle(array $data, User $user): Operation
    {
        $storage = $data['storage'] ?? 'local';

        if ($storage === 's3') {
            // Register a runtime S3 disk from the request params (not persisted to config file).
            // BackupJob will re-register it at run() time by reading credentials off the Backup row.
            // For on-demand backups we register it now so the disk name is resolvable immediately.
            $diskName = 'backups_s3_'.$user->id;

            Config::set("filesystems.disks.{$diskName}", [
                'driver' => 's3',
                'key' => $data['s3_key'] ?? '',
                'secret' => $data['s3_secret'] ?? '',
                'region' => $data['s3_region'] ?? 'us-east-1',
                'bucket' => $data['s3_bucket'] ?? '',
                'url' => $data['s3_endpoint'] ?? null,
                'endpoint' => $data['s3_endpoint'] ?? null,
                'use_path_style_endpoint' => ! empty($data['s3_endpoint']),
            ]);
        } else {
            $diskName = 'backups';
        }

        $operation = Operation::create([
            'user_id' => $user->id,
            'type' => 'backup.'.($data['type'] ?? 'db'),
            'target' => $data['target'] ?? '',
            'status' => 'queued',
        ]);

        $backup = Backup::create([
            'user_id' => $user->id,
            'operation_id' => $operation->id,
            'type' => $data['type'] ?? 'db',
            'target' => $data['target'] ?? '',
            'storage' => $storage,
            'disk_name' => $diskName,
            'status' => 'pending',
        ]);

        BackupJob::dispatch($operation, $backup);

        return $operation;
    }
}
