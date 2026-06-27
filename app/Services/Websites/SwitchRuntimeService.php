<?php

namespace App\Services\Websites;

use App\Models\Website;
use Exception;
use Illuminate\Support\Facades\Process;

class SwitchRuntimeException extends Exception {}

class SwitchRuntimeService
{
    private const SUPPORTED_RUNTIMES = ['php-fpm', 'frankenphp'];

    public function __construct(
        private Website $website,
        private string $runtime,
        private mixed $emit
    ) {}

    /**
     * Switch the website's PHP runtime.
     *
     * Ordered steps:
     * 1. Validate runtime.
     * 2. Stop old non-FPM runtime unit (if applicable).
     * 3. For non-FPM runtimes: allocate port, install, write unit, enable, start.
     *    Port is only saved after start succeeds.
     * 4. Switch Apache vhost.
     * 5. Persist runtime + port.
     * 6. Emit success.
     *
     * On FrankenPHP start failure: throws SwitchRuntimeException (port NOT persisted).
     *
     * @throws SwitchRuntimeException
     */
    public function handle(): void
    {
        if (! in_array($this->runtime, self::SUPPORTED_RUNTIMES, true)) {
            throw new SwitchRuntimeException("Unsupported runtime: {$this->runtime}");
        }

        $website = $this->website;
        $emit = $this->emit;
        $binPath = config('laranode.laranode_bin_path');
        $templateDir = base_path('laranode-scripts/templates');
        $domain = $website->url;
        $systemUser = $website->user->systemUsername;
        $phpVersion = $website->phpVersion->version;
        $documentRoot = $website->document_root;
        $oldRuntime = $website->runtime;

        // Step 2: Stop old non-FPM unit if applicable.
        if ($oldRuntime !== 'php-fpm') {
            $oldUnit = "laranode-{$oldRuntime}-{$domain}.service";
            $emit("Stopping old {$oldRuntime} unit ({$oldUnit})...");
            Process::run(['sudo', $binPath.'/laranode-runtime-manage.sh', 'stop', $oldUnit]);
            // Non-zero exit is logged but does not block switching.
        }

        $port = 0;
        $portOrNull = null;

        // Step 3: Non-FPM runtime setup.
        if ($this->runtime !== 'php-fpm') {
            // 3a. Allocate port.
            $port = (new PortAllocatorService)->allocate($website);
            $emit("Allocated port {$port} for {$this->runtime}.");

            // 3b. Install runtime binary.
            (new InstallRuntimeService)->ensureInstalled($this->runtime, $emit);

            // 3c. Write systemd unit + daemon-reload.
            $emit("Writing systemd unit for {$domain}...");
            $unitResult = Process::run([
                'sudo',
                $binPath.'/laranode-runtime-unit.sh',
                'write-unit',
                $domain,
                (string) $port,
                $systemUser,
                $documentRoot,
                $templateDir,
            ]);
            if ($unitResult->failed()) {
                throw new SwitchRuntimeException(
                    'Failed to write systemd unit: '.$unitResult->errorOutput()
                );
            }

            // 3d. Enable unit.
            $unitName = "laranode-{$this->runtime}-{$domain}.service";
            $emit("Enabling {$unitName}...");
            $enableResult = Process::run(['sudo', $binPath.'/laranode-runtime-manage.sh', 'enable', $unitName]);
            if ($enableResult->failed()) {
                throw new SwitchRuntimeException(
                    "Failed to enable {$unitName}: ".$enableResult->errorOutput()
                );
            }

            // 3e. Start unit.
            $emit("Starting {$unitName}...");
            $startResult = Process::run(['sudo', $binPath.'/laranode-runtime-manage.sh', 'start', $unitName]);
            if ($startResult->failed()) {
                // Port NOT saved on failed start (FIXED: review fix #9).
                throw new SwitchRuntimeException(
                    "Failed to start {$unitName}: ".$startResult->errorOutput()
                );
            }

            // 3f. Start succeeded — commit port for DB write.
            $portOrNull = $port;
        }

        // Step 4: Switch Apache vhost.
        $emit("Switching Apache vhost for {$domain} to {$this->runtime}...");
        $vhostResult = Process::run([
            'sudo',
            $binPath.'/laranode-vhost-switch.sh',
            $domain,
            $this->runtime,
            (string) $port,
            $systemUser,
            $phpVersion,
            $documentRoot,
            $templateDir,
        ]);
        if ($vhostResult->failed()) {
            throw new SwitchRuntimeException(
                'Failed to switch Apache vhost: '.$vhostResult->errorOutput()
            );
        }

        // Step 5: Persist runtime + port.
        $website->update([
            'runtime' => $this->runtime,
            'runtime_port' => $portOrNull,
        ]);

        // Step 6: Emit success.
        $emit("Runtime switched to {$this->runtime} successfully.");
    }
}
