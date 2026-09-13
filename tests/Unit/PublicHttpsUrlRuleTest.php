<?php

use App\Rules\PublicHttpsUrl;

// Pure unit test — does not need the Laravel app container.
// IP-literal URLs mean gethostbyname() needs no DNS resolution.

function validatePublicHttpsUrlDirect(mixed $value): bool
{
    $rule = new PublicHttpsUrl;
    $failed = false;
    $rule->validate('s3_endpoint', $value, function () use (&$failed) {
        $failed = true;
    });

    return ! $failed;
}

// ---- ACCEPTED values ----

test('PublicHttpsUrl accepts an https URL on a public IP', function () {
    // 93.184.216.34 is example.com's public IP — passes the SSRF filter.
    expect(validatePublicHttpsUrlDirect('https://93.184.216.34'))->toBeTrue();
    expect(validatePublicHttpsUrlDirect('https://93.184.216.34:9000/bucket'))->toBeTrue();
});

test('PublicHttpsUrl accepts null and empty (endpoint is optional)', function () {
    expect(validatePublicHttpsUrlDirect(null))->toBeTrue();
    expect(validatePublicHttpsUrlDirect(''))->toBeTrue();
});

// ---- REJECTED values ----

test('PublicHttpsUrl rejects a non-https scheme', function () {
    expect(validatePublicHttpsUrlDirect('http://93.184.216.34'))->toBeFalse();
});

test('PublicHttpsUrl rejects a private-range host', function (string $url) {
    expect(validatePublicHttpsUrlDirect($url))->toBeFalse();
})->with([
    'loopback' => ['https://127.0.0.1'],
    'rfc1918 10/8' => ['https://10.0.0.5'],
    'rfc1918 192.168/16' => ['https://192.168.1.10'],
    'rfc1918 172.16/12' => ['https://172.16.0.1'],
]);

test('PublicHttpsUrl rejects an unresolvable host', function () {
    // .invalid is reserved and must never resolve, so gethostbyname() returns it
    // unchanged and the public-IP check fails.
    expect(validatePublicHttpsUrlDirect('https://no-such-host.invalid'))->toBeFalse();
});

test('PublicHttpsUrl rejects a value that is not a URL', function () {
    expect(validatePublicHttpsUrlDirect('not a url'))->toBeFalse();
    expect(validatePublicHttpsUrlDirect('https://'))->toBeFalse();
});
