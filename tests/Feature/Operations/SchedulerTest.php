<?php // tests/Feature/Operations/SchedulerTest.php

use Illuminate\Console\Scheduling\Schedule;

test('the operation prune command is scheduled', function () {
    $events = app(Schedule::class)->events();
    $commands = collect($events)->map(fn ($e) => $e->command ?? '')->implode(' | ');

    expect($commands)->toContain('model:prune')
        ->and($commands)->toContain('Operation');
});
