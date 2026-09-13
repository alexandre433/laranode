<?php

namespace App\Services\Websites;

use Exception;
use Illuminate\Support\Facades\Process;

class InstallRuntimeException extends Exception {}

class InstallRuntimeService
{
    /**
     * Ensure the given runtime binary is installed on the host.
     * Calls the privileged laranode-runtime-install.sh script.
     *
     * An absent/unreachable runtime (e.g. FrankenPHP not installed and the host
     * cannot download it) must surface as an actionable message on the operation
     * output, never a bare stack trace.
     *
     * @throws InstallRuntimeException if the script exits non-zero.
     */
    public function ensureInstalled(string $runtime, callable $emit): void
    {
        $emit("Installing {$runtime} runtime...");

        $result = Process::run([
            'sudo',
            config('laranode.laranode_bin_path').'/laranode-runtime-install.sh',
            $runtime,
        ]);

        if ($result->failed()) {
            // The install script runs with `set -e` and silent curl, so a failed
            // download aborts it with no stderr at all. Fall back to a message
            // that still tells the operator what to check.
            $detail = trim($result->errorOutput());

            throw new InstallRuntimeException(
                "Failed to install {$runtime} runtime (exit code {$result->exitCode()}): "
                .($detail !== '' ? $detail : 'the installer produced no error output — check that this host can reach the runtime download source.')
            );
        }
    }
}
