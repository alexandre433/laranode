<?php

namespace App\Jobs;

use App\Models\Operation;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;

abstract class OperationJob implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public function __construct(public Operation $operation) {}

    /** Do the work; call $emit($line) per output line; return the exit code. */
    abstract protected function run(callable $emit): int;

    public function handle(): void
    {
        $this->operation->markRunning();

        try {
            $exit = $this->run(fn (string $line) => $this->operation->appendOutput($line));
            $this->operation->markFinished($exit);
        } catch (\Throwable $e) {
            $this->operation->appendOutput('ERROR: ' . $e->getMessage());
            $this->operation->markFinished(1);
            throw $e; // also record in failed_jobs
        }
    }
}
