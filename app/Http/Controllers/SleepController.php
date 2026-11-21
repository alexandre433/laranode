<?php

namespace App\Http\Controllers;

use App\Http\Requests\SleepActionRequest;
use App\Services\Sleep\ManagedRegistry;
use App\Services\Sleep\PanelDatabaseGuard;
use App\Services\Sleep\SleepControlService;
use App\Services\Sleep\SleepStatusService;
use Illuminate\Http\JsonResponse;
use Inertia\Inertia;
use Inertia\Response;

class SleepController extends Controller
{
    public function index(): Response
    {
        return Inertia::render('Power/Index');
    }

    public function status(): JsonResponse
    {
        return response()->json($this->statusService()->handle());
    }

    public function action(SleepActionRequest $request): JsonResponse
    {
        $registry = ManagedRegistry::fromConfig();
        $result = (new SleepControlService($registry, new SleepStatusService($registry, new PanelDatabaseGuard)))
            ->handle($request->user(), $request->validated()['key'], $request->validated()['action'], $request->idleMinutes());

        return response()->json($result['body'], $result['http']);
    }

    private function statusService(): SleepStatusService
    {
        return new SleepStatusService(ManagedRegistry::fromConfig(), new PanelDatabaseGuard);
    }
}
