<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\MassPrunable;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Facades\Storage;

class Backup extends Model
{
    use HasFactory;
    use MassPrunable;

    protected $fillable = [
        'user_id',
        'operation_id',
        'type',
        'target',
        'storage',
        'disk_name',
        'path',
        'size_bytes',
        'status',
    ];

    protected $attributes = [
        'status' => 'pending',
    ];

    protected $casts = [
        'size_bytes' => 'integer',
    ];

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function operation(): BelongsTo
    {
        return $this->belongsTo(Operation::class);
    }

    public function scopeMine(Builder $query): Builder
    {
        $user = auth()->user();

        return $query->when($user && ! $user->isAdmin(), fn ($q) => $q->where('user_id', $user->id));
    }

    public function prunable(): Builder
    {
        return static::where('created_at', '<', now()->subDays(90));
    }

    /**
     * Hook called before each model is mass-pruned.
     * Deletes the backup file from its disk so we don't leave orphaned files.
     */
    public function pruning(): void
    {
        if ($this->disk_name && $this->path) {
            Storage::disk($this->disk_name)->delete($this->path);
        }
    }
}
