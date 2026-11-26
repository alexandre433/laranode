<?php

namespace App\Http\Controllers;

use App\Services\RedisMonitor\RedisMonitor;
use App\Services\RedisMonitor\SeriesBuilder;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Inertia\Inertia;
use Inertia\Response;

/** Admin-only Redis page. Reads files the scheduler wrote; never contacts the remote box itself. */
class RedisMonitorController extends Controller
{
    public function index(RedisMonitor $monitor): Response
    {
        $now = time();

        return Inertia::render('Redis/Index', [
            'enabled' => (bool) config('redis_monitor.enabled'),
            'instances' => collect($monitor->instances())->map(fn ($i, $port) => ['port' => $port, 'label' => $i['label']])->values(),
            'status' => $monitor->status(),
            'alerts' => $monitor->alerts($now),
            'now' => $now,
        ]);
    }

    public function data(Request $request, RedisMonitor $monitor): JsonResponse
    {
        $instances = $monitor->instances();
        $port = (int) $request->query('port', array_key_first($instances));
        abort_unless(isset($instances[$port]), 404);
        $window = SeriesBuilder::window($request->query('window'));
        $now = time();
        if ($window === 'live') {
            $monitor->touchWatch();
        }

        return response()->json([
            'port' => $port,
            'data' => $monitor->series($port, $window, $now),
            'status' => $monitor->status(),
            'alerts' => $monitor->alerts($now),
            'now' => $now,
        ]);
    }
}
