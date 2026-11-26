# Redis monitor (`/admin/redis`)

Admin-only page: memory/storage, ops/s, network in/out, hit rate, keys, clients, keys per DB, top commands
(`INFO` cmdstat), restarts, and storage alerts at 50/75/80/90/95 %. Windows: live (5 s), 1h, 6h, 1d, 7d.
Off by default (`REDIS_MONITOR_ENABLED=false`); the page then shows how to turn it on.

## How it reads (read-only)

The **scheduler** (`redis-monitor:tick`, every minute, runs as the panel user that owns the ssh key) polls over ssh.
The **web process never opens ssh**: it reads the stored files and touches a `watch` file while the Live window is open.
While watched, the tick loops every 5 s for up to 55 s; otherwise it pulls history every ~4.5 min.

Remote side (the `agent` user): only `INFO all` through `redis-cli` (per port) and reading the collector
files `/var/lib/ds-metrics/<port>.jsonl`. No KEYS, CONFIG, FLUSH, writes, CLIENT LIST. A unit test asserts the
scripts contain no other command. Client count comes from `INFO clients`.

ssh options: `BatchMode=yes`, `IdentitiesOnly=yes`, `StrictHostKeyChecking=yes` with a pinned `known_hosts` file
(never accept-new), no port forwarding, `ConnectTimeout=8`. Arguments are validated (`^\d{1,5}:\d{1,12}$`).

State: `storage/app/redis-monitor` (history jsonl, `status.json`, alerts, `watch`).

## Setup

1. As the scheduler user (`laranode_ln`): `ssh-keygen -t ed25519 -f ~/.ssh/ds_redis_monitor -N ''`.
2. DS box (**production op, request PR in `Datanana-com/ops`, not by hand**): add the public key to the `agent`
   user's `authorized_keys` with `restrict` and `from="<pve ip>"`. Related read-only ACL audit: ops#4.
3. Pin the host key: `ssh-keyscan -t ed25519 51.210.3.107 > ~/.ssh/ds_redis_monitor_known_hosts`, compare the
   fingerprint with the one on the DS box before trusting it.
4. `.env`: `REDIS_MONITOR_ENABLED=true`, `REDIS_MONITOR_SSH_KEY`, `REDIS_MONITOR_SSH_KNOWN_HOSTS`
   (target defaults to `agent@51.210.3.107`). The Redis password stays on the DS box (`~agent/.redis_pass`);
   nothing secret is stored in the panel.
5. Make sure `storage/app/redis-monitor` is writable by both the scheduler user (writes) and the web user
   (touches `watch`, reads).

## Other transports

`REDIS_MONITOR_TRANSPORT=local` runs the same read-only script against a Redis on the panel host itself
(`REDIS_MONITOR_LOCAL_USER` / `_PASSFILE`). `fixture` replays files from `REDIS_MONITOR_FIXTURE_DIR` (tests, screenshots).

## Tests

`./vendor/bin/pest tests/Feature/RedisMonitor` (fixture transport only, no network), `npx vitest run resources/js/Pages/Redis`.
