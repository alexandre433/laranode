<?php

namespace App\Http\Controllers;

use App\Databases\EngineManager;
use App\Http\Requests\DbServiceRequest;
use App\Jobs\DbServiceOperationJob;
use App\Models\Operation;
use App\Services\Database\DbServiceStatusService;
use App\Services\Sleep\ManagedRegistry;
use Illuminate\Http\JsonResponse;

class DbServiceController extends Controller
{
    public function __construct(private EngineManager $engineManager) {}

    public function action(DbServiceRequest $request): JsonResponse
    {
        $validated = $request->validated();
        $engine = $validated['engine'];
        $action = $validated['action'];

        // Sleep mode owns the hosting DB lifecycle; a manual start/stop would fight it.
        if ($engine !== 'postgres' && ManagedRegistry::fromConfig()->isEnabled('hostdb')) {
            return response()->json([
                'ok' => false,
                'reason' => 'sleep_managed',
                'message' => 'Database sleep mode is on. Use the Power page to wake or sleep it.',
            ], 409);
        }

        $service = config('laranode.db_engines')[$engine]['service'];

        $operation = Operation::create([
            'user_id' => $request->user()->id,
            'type' => "db.service.{$action}",
            'target' => "{$engine}:{$service}",
            'status' => 'queued',
        ]);

        DbServiceOperationJob::dispatch($operation, $engine, $action);

        return response()->json(['operation_id' => $operation->id]);
    }

    public function status(): JsonResponse
    {
        $statuses = (new DbServiceStatusService($this->engineManager))->handle();

        return response()->json(['statuses' => $statuses]);
    }
}
