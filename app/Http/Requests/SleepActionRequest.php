<?php

namespace App\Http\Requests;

use App\Services\Sleep\ManagedRegistry;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

class SleepActionRequest extends FormRequest
{
    public function authorize(): bool
    {
        return $this->user()?->isAdmin() ?? false;
    }

    /** @return array<string, mixed> */
    public function rules(): array
    {
        $key = $this->input('key');
        $action = $this->input('action');

        $rules = [
            'key' => ['required', 'string', Rule::in(ManagedRegistry::KEYS)],
            'action' => ['required', 'string', Rule::in(['enable', 'disable', 'wake', 'sleep'])],
            'idle_minutes' => ['nullable'],
        ];

        if ($action === 'enable' && $key !== 'queue') {
            $rules['idle_minutes'] = ['required', 'integer', 'between:1,1440'];
        }
        if ($key === 'fpm') {
            $rules['action'][] = Rule::notIn(['wake', 'sleep']);
        }

        return $rules;
    }

    public function idleMinutes(): ?int
    {
        $v = $this->validated()['idle_minutes'] ?? null;

        return $v === null ? null : (int) $v;
    }
}
