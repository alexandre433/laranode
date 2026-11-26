<?php

/*
 * Redis monitor (admin page /admin/redis). Read-only: only INFO is ever sent to a Redis instance.
 *
 * transport  ssh      run the read scripts on a remote box over SSH (the DS box: `agent` user, read-only Redis ACL)
 *            local    run them on this host (a local Redis)
 *            fixture  read canned output from fixture_dir (tests, screenshots)
 */
return [
    'enabled' => (bool) env('REDIS_MONITOR_ENABLED', false),
    'transport' => env('REDIS_MONITOR_TRANSPORT', 'ssh'),

    'ssh' => [
        'target' => env('REDIS_MONITOR_SSH_TARGET', 'agent@51.210.3.107'),
        // Private key file readable by the panel user (never in the repo).
        'key' => env('REDIS_MONITOR_SSH_KEY'),
        // Pinned host key file (known_hosts format); StrictHostKeyChecking=yes, no accept-new.
        'known_hosts' => env('REDIS_MONITOR_SSH_KNOWN_HOSTS'),
        // Remote side: Redis ACL user + its password file (on the remote box, never here).
        'redis_user' => env('REDIS_MONITOR_REMOTE_USER', 'agent'),
        'redis_passfile' => env('REDIS_MONITOR_REMOTE_PASSFILE', '$HOME/.redis_pass'),
        // Remote directory where the DS collector timer writes <port>.jsonl history.
        'metrics_dir' => env('REDIS_MONITOR_REMOTE_METRICS_DIR', '/var/lib/ds-metrics'),
    ],

    'local' => [
        'redis_user' => env('REDIS_MONITOR_LOCAL_USER'),
        'redis_passfile' => env('REDIS_MONITOR_LOCAL_PASSFILE'),
    ],

    'fixture_dir' => env('REDIS_MONITOR_FIXTURE_DIR'),

    // port => label, tls. DS: 6379 plain (the TLS door 6380 is the same process), 6381 + 6382 TLS.
    'instances' => [
        6379 => ['label' => 'Main (6379 plain + 6380 TLS)', 'tls' => false],
        6381 => ['label' => 'Cache + sessions (6381 TLS)', 'tls' => true],
        6382 => ['label' => 'Statistics (6382 TLS)', 'tls' => true],
    ],

    // Minimum seconds between two real polls for the Live view (protects a weak host and the remote box).
    'live_min_interval' => 3,
];
