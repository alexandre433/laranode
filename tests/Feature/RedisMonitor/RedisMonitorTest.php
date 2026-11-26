<?php

use App\Models\User;
use App\Services\RedisMonitor\Alerts;
use App\Services\RedisMonitor\RedisMonitor;
use App\Services\RedisMonitor\RemoteScripts;
use App\Services\RedisMonitor\SampleParser;
use App\Services\RedisMonitor\SeriesBuilder;
use App\Services\RedisMonitor\Transport\FixtureTransport;
use App\Services\RedisMonitor\Transport\LocalTransport;
use App\Services\RedisMonitor\Transport\SshTransport;
use Illuminate\Support\Facades\Process;

const FIXTURES = __DIR__.'/../../Fixtures/redis-monitor';

function row(int $ts, array $o = []): array
{
    return array_merge([
        'ts' => $ts, 'port' => 6379, 'ver' => '8.0.2', 'up' => 1000 + $ts, 'ops' => 10, 'cmds' => $ts * 10, 'hits' => $ts * 8, 'miss' => $ts * 2,
        'mem' => 500, 'max' => 1000, 'rx' => $ts * 100, 'tx' => $ts * 400, 'cli' => 5, 'keys' => 42, 'dbs' => ['0' => 42],
    ], $o);
}

function tmpDir(): string
{
    $d = sys_get_temp_dir().'/redis-monitor-test-'.bin2hex(random_bytes(4));
    mkdir($d);

    return $d;
}

// ---- the box is only ever read ---------------------------------------------------------------------------------

test('remote scripts only ever send INFO: no write, config, key-scan or client command can appear', function () {
    foreach ([RemoteScripts::PULL, RemoteScripts::LIVE] as $script) {
        expect($script)->not->toMatch('/\b(KEYS|SCAN|FLUSHALL|FLUSHDB|CONFIG|SET|DEL|CLIENT|DEBUG|SHUTDOWN|EVAL|ACL|SLAVEOF|REPLICAOF|MONITOR|MIGRATE|RESTORE|SAVE|BGSAVE|SCRIPT|MODULE)\b/i');
    }
    // Every redis-cli call in LIVE ends in INFO all, nothing after it but the pipe.
    preg_match_all('/redis-cli[^\n|]*/', RemoteScripts::LIVE, $m);
    expect($m[0])->toHaveCount(1);
    expect(trim($m[0][0]))->toEndWith('INFO all 2>/dev/null');
    expect(RemoteScripts::PULL)->not->toContain('redis-cli');
});

test('ssh transport pins the host key, never prompts and never forwards', function () {
    Process::fake(['*' => Process::result('#6379')]);
    $t = new SshTransport(['target' => 'agent@box', 'key' => '/k/id', 'known_hosts' => '/k/kh', 'redis_user' => 'agent', 'redis_passfile' => '$HOME/.redis_pass', 'metrics_dir' => '/var/lib/ds-metrics']);
    $t->run('live', RemoteScripts::LIVE, ['6379:0', '6381:1']);
    Process::assertRan(function ($p) {
        $c = is_array($p->command) ? implode(' ', $p->command) : $p->command;

        return str_contains($c, 'BatchMode=yes') && str_contains($c, 'StrictHostKeyChecking=yes') && str_contains($c, 'UserKnownHostsFile=/k/kh')
            && ! str_contains($c, 'accept-new') && ! str_contains($c, ' -L ') && ! str_contains($c, ' -R ')
            && str_contains($c, 'agent@box sh -s -- 6379:0 6381:1')
            && str_contains($p->input ?? '', 'INFO all') && str_contains($p->input ?? '', 'RM_USER=agent');
    });
});

test('ssh transport refuses to run without a pinned host key or key file', function () {
    $t = new SshTransport(['target' => 'agent@box', 'key' => '/k/id', 'known_hosts' => null]);
    expect(fn () => $t->run('live', RemoteScripts::LIVE, ['6379:0']))->toThrow(RuntimeException::class, 'not configured');
});

test('transports reject an argument that is not port:number (nothing reaches a shell)', function () {
    $t = new LocalTransport([]);
    foreach (['6379;rm -rf /', '$(id):0', '6379', '6379:0 6381:1'] as $bad) {
        expect(fn () => $t->run('live', RemoteScripts::LIVE, [$bad]))->toThrow(InvalidArgumentException::class);
    }
});

test('a failing ssh surfaces as an error, with stderr trimmed', function () {
    Process::fake(['*' => Process::result('', 'Host key verification failed.', 255)]);
    $t = new SshTransport(['target' => 'a@b', 'key' => '/k', 'known_hosts' => '/kh']);
    expect(fn () => $t->run('live', RemoteScripts::LIVE, ['6379:0']))->toThrow(RuntimeException::class, 'Host key verification failed');
});

// ---- parsing ---------------------------------------------------------------------------------------------------

test('parseLive reads INFO numbers, keys per db and the top commands', function () {
    $out = (new FixtureTransport(FIXTURES))->run('live', '', []);
    $s = SampleParser::parseLive($out);
    expect(array_keys($s))->toBe([6379, 6381, 6382]);
    expect($s[6379])->toMatchArray(['ver' => '8.0.2', 'max' => 3000000000, 'cli' => 24, 'blk' => 0, 'keys' => 6005, 'dbs' => [0 => 6000, 1 => 5]]);
    expect(array_key_first($s[6379]['cs']))->toBe('get');
    expect($s[6379]['cs']['set'])->toBe(310000);
});

test('parseLive skips an instance whose INFO failed (empty section)', function () {
    $s = SampleParser::parseLive("#ts 1700000000.5\n#6379\n#6381\nuptime_in_seconds:5\nused_memory:1\n");
    expect(array_keys($s))->toBe([6381]);
});

test('parseJsonl drops torn lines and duplicate timestamps', function () {
    $rows = SampleParser::parseJsonl(json_encode(row(100))."\n".json_encode(row(100))."\n{\"ts\":101,\"cmds\":\n".json_encode(row(90))."\n");
    expect(array_column($rows, 'ts'))->toBe([90, 100]);
});

// ---- the maths: a restart or an outage is a hole, never a spike ------------------------------------------------

test('series: ops/s and bandwidth come from counter deltas', function () {
    $now = 100000;
    $rows = [row($now - 120, ['cmds' => 0, 'rx' => 0, 'tx' => 0, 'hits' => 0, 'miss' => 0]), row($now - 60, ['cmds' => 6000, 'rx' => 60000, 'tx' => 240000, 'hits' => 4000, 'miss' => 1000]), row($now, ['cmds' => 12000, 'rx' => 120000, 'tx' => 480000, 'hits' => 8000, 'miss' => 2000])];
    $r = SeriesBuilder::build($rows, $now, '1h');
    expect($r['summary']['opsAvg'])->toEqual(100)
        ->and($r['summary']['rx'])->toBe(120000)
        ->and($r['summary']['tx'])->toBe(480000)
        ->and($r['summary']['bytes'])->toBe(600000)
        ->and($r['summary']['hitRate'])->toBe(0.8)
        ->and($r['summary']['restarts'])->toBe(0);
});

test('series: a counter reset (restart) contributes no delta and is counted', function () {
    $now = 100000;
    $rows = [row($now - 120, ['cmds' => 1000000, 'up' => 5000]), row($now - 60, ['cmds' => 50, 'up' => 10]), row($now, ['cmds' => 6050, 'up' => 70])];
    $r = SeriesBuilder::build($rows, $now, '1h');
    expect($r['summary']['restarts'])->toBe(1)
        ->and($r['summary']['opsAvg'])->toEqual(100);
    foreach ($r['series'] as $s) {
        expect($s['ops'] ?? 0)->toBeGreaterThanOrEqual(0);
    }
});

test('series: a gap longer than 5 min (collector outage) is a hole, not a spike', function () {
    $now = 100000;
    $rows = [row($now - 3000, ['cmds' => 0]), row($now - 60, ['cmds' => 9999999]), row($now, ['cmds' => 10005999])];
    $r = SeriesBuilder::build($rows, $now, '1h');
    expect($r['summary']['opsAvg'])->toEqual(100);
});

test('series: stale flag when the newest sample is older than 15 min', function () {
    $r = SeriesBuilder::build([row(1000), row(1060)], 5000, '7d');
    expect($r['summary']['stale'])->toBeTrue();
    expect(SeriesBuilder::build([], 5000, '1d')['summary']['samples'])->toBe(0);
});

test('series: an unknown window falls back to 1d', function () {
    expect(SeriesBuilder::window('bogus'))->toBe('1d');
    expect(SeriesBuilder::window('live'))->toBe('live');
});

test('top commands: rate over the window, sorted by rate, restart falls back to lifetime calls', function () {
    $now = 100000;
    $a = row($now - 100, ['cs' => ['get' => 1000, 'set' => 100]]);
    $b = row($now, ['cs' => ['get' => 1500, 'set' => 4100], 'cmds' => $a['cmds'] + 100, 'up' => $a['up'] + 100]);
    $top = SeriesBuilder::topCommands([$a, $b], $b);
    expect($top[0]['cmd'])->toBe('set')->and($top[0]['rate'])->toEqual(40)
        ->and($top[1]['cmd'])->toBe('get')->and($top[1]['rate'])->toEqual(5);
    $b['up'] = 3; // restarted
    $top = SeriesBuilder::topCommands([$a, $b], $b);
    expect($top[0]['rate'])->toBeNull()->and($top[0]['cmd'])->toBe('set');
});

// ---- alerts ----------------------------------------------------------------------------------------------------

test('alerts fire once per upward crossing, only the highest line, and re-arm 5 points below', function () {
    [$st, $f] = Alerts::evaluate([], [['port' => 6379, 'mem' => 760, 'max' => 1000]], 1);
    expect($f)->toHaveCount(1)->and($f[0]['threshold'])->toBe(75);
    [$st, $f] = Alerts::evaluate($st, [['port' => 6379, 'mem' => 770, 'max' => 1000]], 2);
    expect($f)->toBeEmpty();
    [$st, $f] = Alerts::evaluate($st, [['port' => 6379, 'mem' => 960, 'max' => 1000]], 3);
    expect($f)->toHaveCount(1)->and($f[0]['threshold'])->toBe(95);
    [$st, $f] = Alerts::evaluate($st, [['port' => 6379, 'mem' => 910, 'max' => 1000]], 4); // 91 %: not 5 points below 95
    expect($f)->toBeEmpty()->and($st[6379]['level'])->toBe(95);
    [$st] = Alerts::evaluate($st, [['port' => 6379, 'mem' => 890, 'max' => 1000]], 5);
    expect($st[6379]['level'])->toBe(80);
});

test('alerts: maxmemory 0 means no limit and never alerts', function () {
    [, $f] = Alerts::evaluate([], [['port' => 6379, 'mem' => 999999, 'max' => 0]], 1);
    expect($f)->toBeEmpty();
});

// ---- scheduler tick (fixture transport, temp dir) --------------------------------------------------------------

function monitor(?string $dir = null): RedisMonitor
{
    config(['redis_monitor.enabled' => true]);

    return new RedisMonitor(new FixtureTransport(FIXTURES), $dir ?? tmpDir());
}

test('tick: not watched = one history pull, no live buffer', function () {
    $m = monitor();
    $did = $m->tick(fn () => 1700000000, fn () => null);
    expect($did)->toBe('idle+pull');
    expect($m->status()['ok'])->toBeTrue();
    expect($m->rows(6379))->toHaveCount(1); // own sample (no collector rows in the fixture pull)
    expect($m->liveRows(6379))->toBe([]);
    // a second tick right after does not pull again
    expect($m->tick(fn () => 1700000010, fn () => null))->toBe('idle');
});

test('tick: while the page watches, polls every interval for the budget, then stops when the watch goes stale', function () {
    $m = monitor();
    $clock = 1700000000;
    $m->touchWatch(); // real mtime, so drive the clock from it
    $base = filemtime($m->dir().'/watch');
    $now = function () use (&$clock, $base) {
        return $base + $clock - 1700000000;
    };
    $m->tick($now, function ($s) use (&$clock) {
        $clock += $s;
    }, 5, 20);
    expect(count($m->liveRows(6379)))->toBeGreaterThanOrEqual(2)->toBeLessThanOrEqual(4);
});

test('pull failure is recorded, not thrown', function () {
    config(['redis_monitor.enabled' => true]);
    $m = new RedisMonitor(new FixtureTransport(tmpDir().'/missing'), tmpDir());
    $s = $m->pull(1700000000);
    expect($s['ok'])->toBeFalse()->and($s['error'])->toContain('no live fixture');
});

test('history keeps 8 days and merges by timestamp', function () {
    $now = 2000000;
    $m = SeriesBuilder::merge([row($now - 9 * 86400), row($now - 100)], [row($now - 100, ['mem' => 7]), row($now - 50)], $now);
    expect(array_column($m, 'ts'))->toBe([$now - 100, $now - 50])->and($m[0]['mem'])->toBe(7);
});

// ---- the page --------------------------------------------------------------------------------------------------

test('redis page: login required, non-admin refused, admin gets the Inertia page', function () {
    $this->get(route('redis.index'))->assertRedirect(route('login'));
    $this->actingAs(User::factory()->isNotAdmin()->create())->get(route('redis.index'))->assertForbidden();
    $this->actingAs(User::factory()->isNotAdmin()->create())->getJson(route('redis.data'))->assertForbidden();
    $this->actingAs(User::factory()->create(['role' => 'admin']))->withoutVite()->get(route('redis.index'))
        ->assertOk()
        ->assertInertia(fn ($p) => $p->component('Redis/Index')->has('instances', 3)->where('enabled', false));
});

test('redis data: unknown port is 404, live window touches the watch flag, series comes from files', function () {
    $dir = tmpDir();
    $this->app->instance(RedisMonitor::class, $m = monitor($dir));
    $admin = User::factory()->create(['role' => 'admin']);
    $this->actingAs($admin)->getJson(route('redis.data', ['port' => 1234]))->assertNotFound();

    $m->pull(time());
    expect(is_file($dir.'/watch'))->toBeFalse();
    $r = $this->actingAs($admin)->getJson(route('redis.data', ['port' => 6379, 'window' => 'live']))->assertOk();
    expect(is_file($dir.'/watch'))->toBeTrue();
    $r->assertJsonPath('data.window', 'live')->assertJsonPath('status.ok', true);

    $r = $this->actingAs($admin)->getJson(route('redis.data', ['port' => 6379, 'window' => '1h']))->assertOk();
    $r->assertJsonPath('data.summary.samples', 1)->assertJsonPath('data.topCommands.0.cmd', 'get');
});
