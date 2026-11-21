<?php

namespace App\Services\Sleep;

use App\Models\Operation;
use App\Models\User;
use Illuminate\Support\Facades\Process;

/**
 * Runs the ONE privileged entry point: `sudo laranode-sleep.sh <key> <action> [idle]`.
 * Every argument is a fixed key/action or a validated integer; the unit names
 * come from the root-owned registry inside the script, never from here.
 */
class SleepControlService
{
    public function __construct(
        private ManagedRegistry $registry,
        private SleepStatusService $status,
    ) {}

    /**
     * @return array{http: int, body: array<string, mixed>}
     */
    public function handle(User $user, string $key, string $action, ?int $idle): array
    {
        if (! $this->registry->isManaged($key)) {
            return $this->refuse(403, "'{$key}' is not managed by Laranode (external service, never touched).", 'external');
        }

        // disable is always allowed (it only restores the original state)
        if ($action !== 'disable' && ($reason = $this->status->blockReason($key)) !== null) {
            return $this->refuse(409, $this->reasonText($reason), $reason);
        }

        $args = ['sudo', config('laranode.laranode_bin_path').'/laranode-sleep.sh', $key, $action];
        if ($action === 'enable' && $key !== 'queue' && $idle !== null) {
            $args[] = (string) $idle;
        }

        $op = Operation::create([
            'user_id' => $user->id,
            'type' => "power.{$action}",
            'target' => $key,
            'status' => 'queued',
        ]);
        $op->markRunning();

        $result = Process::timeout(150)->run($args);
        $op->appendOutput(trim($result->output().$result->errorOutput()));
        $op->markFinished($result->successful() ? 0 : ($result->exitCode() ?: 1));

        if ($result->successful()) {
            return ['http' => 200, 'body' => ['ok' => true, 'operation_id' => $op->id]];
        }

        $http = match ($result->exitCode()) {
            2 => 422,
            3 => 409,
            default => 500,
        };

        return ['http' => $http, 'body' => [
            'ok' => false,
            'operation_id' => $op->id,
            'message' => trim($result->errorOutput()) ?: 'Sleep script failed.',
        ]];
    }

    /** @return array{http: int, body: array<string, mixed>} */
    private function refuse(int $http, string $message, string $reason): array
    {
        return ['http' => $http, 'body' => ['ok' => false, 'message' => $message, 'reason' => $reason]];
    }

    private function reasonText(string $reason): string
    {
        return match ($reason) {
            'panel_db' => 'Cannot sleep: the panel database lives on this database instance and must stay up.',
            'apparmor' => 'Cannot sleep: an enforced AppArmor profile for the database would deny the moved socket and the database would not start on wake.',
            'stale' => 'Cannot sleep: this service is no longer registered by the installer (stale entry). Wake it with Disable, then re-run the installer to manage it again.',
            'unsupported_engine' => 'Cannot sleep: only MySQL/MariaDB hosting databases can sleep.',
            default => 'Cannot sleep this service.',
        };
    }
}
