<?php

// Reverb's periodic ConfigApplicationProvider::all() calls findById($app['app_id']) for every
// configured app. An app whose id env var is unset (the optional ESP32 / SMARTH apps) made it throw
// a TypeError and the websocket server crashed about once a minute, dropping every live connection.
test('every configured reverb app has an id', function () {
    $apps = config('reverb.apps.apps');

    expect($apps)->toBeArray();
    foreach ($apps as $app) {
        expect($app['app_id'] ?? null)->not->toBeEmpty();
    }
});

test('an app whose id is not configured is not registered', function () {
    config()->set('reverb.apps.apps', []);
    $env = ['REVERB_APP_ID' => null, 'REVERB_ESP32_APP_ID' => null, 'REVERB_SMARTH_APP_ID' => null];
    foreach ($env as $k => $v) {
        putenv($k);
        unset($_ENV[$k], $_SERVER[$k]);
    }

    $apps = (require base_path('config/reverb.php'))['apps']['apps'];

    expect($apps)->toBe([]);
});
