<?php

namespace App\Services\RedisMonitor\Transport;

interface Transport
{
    /**
     * Run one of RemoteScripts on the target and return its stdout.
     *
     * @param  'pull'|'live'  $kind
     * @param  list<string>  $args  "<port>:<n>" tokens
     *
     * @throws \RuntimeException on any failure (timeout, ssh error)
     */
    public function run(string $kind, string $script, array $args): string;
}
