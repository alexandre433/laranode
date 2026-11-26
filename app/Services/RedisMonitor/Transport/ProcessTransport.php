<?php

namespace App\Services\RedisMonitor\Transport;

use Illuminate\Support\Facades\Process;

/** Shared piece of the ssh and local transports: validate args, prepend the env preamble, pipe the script on stdin. */
abstract class ProcessTransport implements Transport
{
    /** @return list<string> command that runs `sh -s -- <args>` where the Redis boxes are reachable */
    abstract protected function command(array $args): array;

    /** Shell lines run before the script: env for the script, never secrets. */
    abstract protected function preamble(): string;

    public function run(string $kind, string $script, array $args): string
    {
        foreach ($args as $a) {
            if (! preg_match('/^\d{1,5}:\d{1,12}$/', $a)) {
                throw new \InvalidArgumentException('bad argument');
            }
        }
        $result = Process::timeout($kind === 'live' ? 12 : 45)
            ->input($this->preamble()."\n".$script)
            ->run($this->command($args));
        if ($result->failed()) {
            throw new \RuntimeException('transport exit '.$result->exitCode().': '.substr(trim($result->errorOutput()), 0, 200));
        }

        return $result->output();
    }
}
