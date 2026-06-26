<?php

namespace App\Jobs;

use App\Actions\Backup\RetainBackupsAction;
use App\Models\ScheduledBackup;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Facades\Storage;

class RetainBackupsJob implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public function __construct(public readonly int $scheduledBackupId) {}

    public function handle(RetainBackupsAction $action): void
    {
        $schedule = ScheduledBackup::findOrFail($this->scheduledBackupId);

        $diskName = $schedule->disk_name ?? 'backups';
        $disk = Storage::disk($diskName);

        $action->execute(
            $schedule->user_id,
            $schedule->type,
            $schedule->target,
            $schedule->retention_count,
            $disk,
        );
    }
}
