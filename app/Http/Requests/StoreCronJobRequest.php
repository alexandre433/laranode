<?php

namespace App\Http\Requests;

use App\Models\CronJob;
use App\Rules\AllowedCronCommand;
use App\Rules\ValidCronExpression;
use Illuminate\Foundation\Http\FormRequest;

class StoreCronJobRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            'schedule' => ['required', 'string', 'max:100', new ValidCronExpression],
            'command' => ['required', 'string', 'max:500', new AllowedCronCommand($this->user())],
            'label' => ['nullable', 'string', 'max:255'],
        ];
    }

    protected function withValidator($validator): void
    {
        $validator->after(function ($validator) {
            $user = $this->user();
            if (! $user) {
                return;
            }

            $count = CronJob::where('user_id', $user->id)->count();
            if ($count >= 50) {
                $validator->errors()->add('command', 'You have reached the maximum of 50 cron jobs.');
            }
        });
    }
}
