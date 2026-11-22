<?php

// Reverb's periodic ConfigApplicationProvider::all() calls findById($app['app_id']) for every
// configured app. An app whose id env var is unset (the optional ESP32 / SMARTH apps) made it throw
// a TypeError and the websocket server crashed about once a minute, dropping every live connection.
use Illuminate\Support\Facades\Log;

const REVERB_ID_ENV = ['REVERB_APP_ID', 'REVERB_ESP32_APP_ID', 'REVERB_SMARTH_APP_ID'];

beforeEach(function () {
    $this->savedReverbEnv = [];
    foreach (REVERB_ID_ENV as $k) {
        $this->savedReverbEnv[$k] = [getenv($k), $_ENV[$k] ?? null, $_SERVER[$k] ?? null];
    }
});

// the second test unsets the ids: put them back so no other test sees a changed environment
afterEach(function () {
    foreach ($this->savedReverbEnv as $k => [$proc, $env, $server]) {
        $proc === false ? putenv($k) : putenv("$k=$proc");
        $env === null ? null : $_ENV[$k] = $env;
        $server === null ? null : $_SERVER[$k] = $server;
    }
});

test('every configured reverb app has an id', function () {
    $apps = config('reverb.apps.apps');

    expect($apps)->toBeArray();
    foreach ($apps as $app) {
        expect($app['app_id'] ?? null)->not->toBeEmpty();
    }
});

test('an app whose id is not configured is not registered', function () {
    foreach (REVERB_ID_ENV as $k) {
        putenv($k);
        unset($_ENV[$k], $_SERVER[$k]);
    }

    $apps = (require base_path('config/reverb.php'))['apps']['apps'];

    expect($apps)->toBe([]);
});

// with REVERB_APP_ID empty the config above leaves zero apps and live stats die silently
test('a host with no reverb app logs a warning', function () {
    config(['reverb.apps.apps' => []]);
    Log::spy();

    app()->getProvider(App\Providers\AppServiceProvider::class)->warnWhenNoReverbApp();

    Log::shouldHaveReceived('warning')->once()->withArgs(fn ($m) => str_contains($m, 'REVERB_APP_ID'));
});

test('a host with a reverb app logs nothing', function () {
    config(['reverb.apps.apps' => [['app_id' => 'x', 'key' => 'k', 'secret' => 's']]]);
    Log::spy();

    app()->getProvider(App\Providers\AppServiceProvider::class)->warnWhenNoReverbApp();

    Log::shouldNotHaveReceived('warning');
});
