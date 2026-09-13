<?php

namespace App\Rules;

use Closure;
use Illuminate\Contracts\Validation\ValidationRule;

class PublicHttpsUrl implements ValidationRule
{
    public function validate(string $attribute, mixed $value, Closure $fail): void
    {
        // The requests keep 'nullable' — an absent value means "not configured".
        if ($value === null || $value === '') {
            return;
        }

        $parsed = is_string($value) ? parse_url($value) : false;

        if ($parsed === false || ! isset($parsed['scheme'], $parsed['host'])) {
            $fail('The :attribute must be a valid URL.');

            return;
        }

        if ($parsed['scheme'] !== 'https') {
            $fail('The :attribute must use the https scheme.');

            return;
        }

        $host = $parsed['host'];

        // IPv6 literal hosts are wrapped in brackets — strip them
        if (str_starts_with($host, '[') && str_ends_with($host, ']')) {
            $host = substr($host, 1, -1);
        }

        // gethostbyname() returns its input unchanged when resolution fails, so an
        // unresolvable host fails the public-IP check below instead of passing.
        $ip = gethostbyname($host);

        if (! filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE)) {
            $fail('The :attribute must resolve to a public IP address (private, reserved, and unresolvable hosts are not allowed).');
        }
    }
}
