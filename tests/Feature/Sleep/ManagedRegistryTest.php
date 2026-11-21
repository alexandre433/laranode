<?php

use App\Services\Sleep\ManagedRegistry;
use Tests\Support\SleepFixtures;

afterEach(function () {
    if (isset($this->dir)) {
        SleepFixtures::cleanup($this->dir);
    }
});

test('missing registry directory: nothing is managed', function () {
    $r = new ManagedRegistry('/nonexistent/laranode-'.uniqid());
    expect($r->entry('reverb'))->toBeNull()
        ->and($r->isManaged('reverb'))->toBeFalse()
        ->and($r->keys())->toBe([]);
});

test('reads registered entries and per-key state', function () {
    $this->dir = SleepFixtures::registry(
        ['reverb' => ['kind' => 'reverb', 'unit' => 'laranode-reverb.service', 'public_port' => '8080']],
        ['reverb' => ['enabled' => '1', 'idle_minutes' => '7']],
    );
    $r = new ManagedRegistry($this->dir);

    expect($r->isManaged('reverb'))->toBeTrue()
        ->and($r->entry('reverb')['unit'])->toBe('laranode-reverb.service')
        ->and($r->state('reverb'))->toMatchArray(['enabled' => '1', 'idle_minutes' => '7'])
        ->and($r->state('queue'))->toBe([]);
});

test('key outside the fixed allowlist is never read, even if a file exists', function () {
    $this->dir = SleepFixtures::registry(['postgresql' => ['kind' => 'db', 'unit' => 'postgresql@16-main.service']]);
    $r = new ManagedRegistry($this->dir);
    expect($r->isManaged('postgresql'))->toBeFalse()
        ->and($r->entry('postgresql'))->toBeNull()
        ->and($r->keys())->toBe([]);
});

test('path traversal in key is rejected', function () {
    $this->dir = SleepFixtures::registry(['reverb' => ['kind' => 'reverb']]);
    $r = new ManagedRegistry($this->dir);
    expect($r->entry('../managed.d/reverb'))->toBeNull();
});

test('malformed lines are ignored, values trimmed', function () {
    $this->dir = SleepFixtures::registry();
    file_put_contents($this->dir.'/managed.d/queue.conf', "# c\nkind=queue\n garbage line\nunit = laranode-queue-worker.service \n");
    $r = new ManagedRegistry($this->dir);
    expect($r->entry('queue'))->toBe(['kind' => 'queue', 'unit' => 'laranode-queue-worker.service']);
});
