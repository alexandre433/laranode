<?php

use App\Listeners\WakeQueueOnJobQueued;
use Illuminate\Queue\Events\JobQueued;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Process;
use Tests\Support\SleepFixtures;

beforeEach(function () {
    Cache::flush();
    Process::fake(['*' => Process::result(output: 'inactive', exitCode: 3)]);
    config(['laranode.laranode_bin_path' => '/opt/ln/bin']);
});
afterEach(fn () => isset($this->dir) && SleepFixtures::cleanup($this->dir));

function fireJobQueued(): void
{
    (new WakeQueueOnJobQueued)->handle(new JobQueued('database', null, 'id1', 'Job', '{}', 0));
}

function wakeCalls(): int
{
    $n = 0;
    Process::assertRan(function ($p) use (&$n) {
        if ($p->command === ['sudo', '/opt/ln/bin/laranode-sleep.sh', 'queue', 'wake']) {
            $n++;
        }

        return true;
    });

    return $n;
}

test('queue sleep on and worker down: dispatch wakes it via the allowlisted script', function () {
    $this->dir = SleepFixtures::registry(SleepFixtures::fullInstall(), ['queue' => ['enabled' => '1']]);
    config(['laranode.managed_dir' => $this->dir]);
    fireJobQueued();
    expect(wakeCalls())->toBe(1);
});

test('queue sleep off: dispatch does nothing', function () {
    $this->dir = SleepFixtures::registry(SleepFixtures::fullInstall());
    config(['laranode.managed_dir' => $this->dir]);
    fireJobQueued();
    Process::assertNothingRan();
});

test('no registry (DS pre-install): dispatch does nothing', function () {
    config(['laranode.managed_dir' => '/nonexistent/x'.uniqid()]);
    fireJobQueued();
    Process::assertNothingRan();
});

test('wake is throttled: a burst of dispatches wakes once', function () {
    $this->dir = SleepFixtures::registry(SleepFixtures::fullInstall(), ['queue' => ['enabled' => '1']]);
    config(['laranode.managed_dir' => $this->dir]);
    fireJobQueued();
    fireJobQueued();
    fireJobQueued();
    expect(wakeCalls())->toBe(1);
});

test('wake failure never breaks dispatch', function () {
    $this->dir = SleepFixtures::registry(SleepFixtures::fullInstall(), ['queue' => ['enabled' => '1']]);
    config(['laranode.managed_dir' => $this->dir]);
    Process::fake(['*' => fn () => throw new RuntimeException('sudo missing')]);
    fireJobQueued();
    expect(true)->toBeTrue();
});

test('a stale queue entry never calls sudo (the script would always refuse with exit 3)', function () {
    $e = SleepFixtures::fullInstall();
    $e['queue']['stale'] = '1';
    $this->dir = SleepFixtures::registry($e, ['queue' => ['enabled' => '1']]);
    config(['laranode.managed_dir' => $this->dir]);
    fireJobQueued();
    Process::assertNothingRan();
});
