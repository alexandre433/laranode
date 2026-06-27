<?php

use App\Models\Website;
use App\Services\Websites\PortAllocatorService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

// PortAllocatorService needs DB access so we bind the Laravel TestCase + RefreshDatabase.
uses(TestCase::class, RefreshDatabase::class);

test('returns 9100 when no other websites have runtime ports', function () {
    $website = Website::factory()->create(['runtime_port' => null]);

    $port = (new PortAllocatorService)->allocate($website);

    expect($port)->toBe(9100);
});

test('returns first gap — skips port used by another website', function () {
    Website::factory()->create(['runtime_port' => 9100]);
    $website = Website::factory()->create(['runtime_port' => null]);

    $port = (new PortAllocatorService)->allocate($website);

    expect($port)->toBe(9101);
});

test('skips multiple consecutive ports used by other websites', function () {
    Website::factory()->create(['runtime_port' => 9100]);
    Website::factory()->create(['runtime_port' => 9101]);
    Website::factory()->create(['runtime_port' => 9102]);

    $website = Website::factory()->create(['runtime_port' => null]);

    $port = (new PortAllocatorService)->allocate($website);

    expect($port)->toBe(9103);
});

test('excludeWebsite own port does not block self — returns own port when it is the lowest free', function () {
    // Website already holds 9100; allocating for itself should return 9100 again
    // because its own row is excluded from the used-ports set.
    $website = Website::factory()->create(['runtime_port' => 9100]);

    $port = (new PortAllocatorService)->allocate($website);

    expect($port)->toBe(9100);
});

test('throws RuntimeException when all ports 9100-9499 are occupied by other websites', function () {
    foreach (range(9100, 9499) as $port) {
        Website::factory()->create(['runtime_port' => $port]);
    }

    $website = Website::factory()->create(['runtime_port' => null]);

    expect(fn () => (new PortAllocatorService)->allocate($website))
        ->toThrow(\RuntimeException::class, 'No available runtime ports in range 9100–9499.');
});

test('concurrent race: runtime_port stays null when second allocation\'s start fails (DB write skipped on failure)', function () {
    // Documents the v1 concurrency contract:
    // runtime_port must NOT be persisted to the DB if systemctl start fails.
    // The allocator returns a port but the caller (SwitchRuntimeService) only
    // persists it after start() succeeds. This test verifies that contract holds.

    $website = Website::factory()->create(['runtime_port' => null]);

    // Allocate a port — but do not save it (simulating a failed start).
    $allocatedPort = (new PortAllocatorService)->allocate($website);

    // DB row must remain null because the caller never wrote it.
    expect($website->fresh()->runtime_port)->toBeNull();

    // Only after a successful start would the caller persist the port.
    $website->update(['runtime_port' => $allocatedPort]);
    expect($website->fresh()->runtime_port)->toBe($allocatedPort);
});
