<?php

namespace App\Http\Requests;

use App\Rules\PublicHttpsUrl;
use Cron\CronExpression;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

class CreateScheduledBackupRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        $userId = $this->user()?->id;
        $type = $this->input('type', 'db');

        if ($type === 'files') {
            $targetRule = Rule::exists('websites', 'url')->where('user_id', $userId);
        } else {
            // PostgreSQL backups are not implemented — reject the target here
            // instead of failing deep inside the queued BackupJob.
            $targetRule = Rule::exists('databases', 'name')
                ->where('user_id', $userId)
                ->whereNot('engine', 'postgres');
        }

        return [
            'type' => ['required', 'string', Rule::in(['db', 'files'])],
            'target' => ['required', 'string', $targetRule],
            'storage' => ['required', 'string', Rule::in(['local', 's3'])],
            'cron_expression' => [
                'required',
                'string',
                function (string $attribute, mixed $value, \Closure $fail) {
                    if (! CronExpression::isValidExpression($value)) {
                        $fail('The cron expression is not valid.');
                    }
                },
            ],
            'retention_count' => ['required', 'integer', 'min:1', 'max:365'],
            's3_key' => ['required_if:storage,s3', 'nullable', 'string'],
            's3_secret' => ['required_if:storage,s3', 'nullable', 'string'],
            's3_region' => ['required_if:storage,s3', 'nullable', 'string'],
            's3_bucket' => ['required_if:storage,s3', 'nullable', 'string'],
            's3_endpoint' => ['nullable', 'url', new PublicHttpsUrl],
            'enabled' => ['boolean'],
        ];
    }

    public function messages(): array
    {
        if ($this->input('type', 'db') === 'files') {
            return [
                'target.exists' => 'The selected target does not belong to your account.',
            ];
        }

        return [
            // 'exists' also fires for the postgres engine exclusion above, so the
            // message names both causes (the UI surfaces this as a toast).
            'target.exists' => 'The selected database does not belong to your account, or its engine is not supported for backups (PostgreSQL backups are not implemented yet).',
        ];
    }
}
