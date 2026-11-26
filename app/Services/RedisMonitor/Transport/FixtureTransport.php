<?php

namespace App\Services\RedisMonitor\Transport;

/** Tests and screenshots: <dir>/pull.txt is the PULL output, <dir>/live-*.txt the LIVE outputs, used in turn. */
final class FixtureTransport implements Transport
{
    private int $polls = 0;

    public function __construct(private readonly string $dir) {}

    public function run(string $kind, string $script, array $args): string
    {
        if ($kind === 'pull') {
            return (string) @file_get_contents($this->dir.'/pull.txt');
        }
        $files = glob($this->dir.'/live-*.txt') ?: [];
        sort($files);
        if (! $files) {
            throw new \RuntimeException('no live fixture');
        }
        $n = $this->polls++;
        $out = (string) file_get_contents($files[$n % count($files)]);

        // Stamp "now" (+5 s per poll, like a real 5 s cadence) so samples land in the window and stay ordered.
        return preg_replace('/^#ts .*/m', '#ts '.sprintf('%.3f', microtime(true) + 5 * $n), $out);
    }
}
