# Service sleep / wake

Optional (OFF by default). Frees RAM on small hosts by stopping idle Laranode services and
waking them on the first connection. Admin-only, from **Power** in the panel sidebar.

One build for every host. Unit names and OS differences (Ubuntu 24.04 `mysql.service`, Debian 13
`mariadb.service`, PHP versions) are detected at runtime, never hard-coded per host.

## What can sleep

| Key | Service | How it sleeps | Wakes on |
|---|---|---|---|
| `reverb` | `laranode-reverb.service` | systemd socket owns the public port; `systemd-socket-proxyd --exit-idle-time` stops it when idle | a websocket connect |
| `queue` | `laranode-queue-worker.service` | a 30 s timer runs `queue:work --stop-when-empty`; worker is no longer a resident process | next timer tick, or immediately when a job is dispatched (`JobQueued` listener) |
| `fpm` | per-site `*_ln.conf` pools | `pm = ondemand`, idle workers exit after N minutes | first request |
| `hostdb` | the hosting MySQL/MariaDB | proxy socket owns TCP 3306 and the canonical unix socket; the real server moves to a private socket | a client connect (also backups and `schedule:run`) |

## What never sleeps

sshd, tailscaled, Apache, the PHP-FPM master, the panel's own database, and any service Laranode
did not install.

* **Panel DB guard.** If the panel's database is the same instance as the hosting DB (the default
  full install), `hostdb` shows **cannot sleep: panel DB** and the script refuses it.
* **PostgreSQL** hosting DBs are refused (peer auth over the unix socket cannot be proxied).
* **External services** (shared PostgreSQL, Redis, Percona, CloudPanel nginx, a pre-existing
  Apache/PHP-FPM/DB) are listed read-only on the Power page and can never be managed.

## Safety model

1. **One privileged script**: `laranode-scripts/bin/laranode-sleep.sh <key> <action> [idle]`, the only
   sleep-related entry in `/etc/sudoers.d/laranode-sleep`. `key` is one of `reverb|queue|hostdb|fpm`,
   `action` one of `enable|disable|wake|sleep`, `idle` an integer 1..1440. No unit names, no free-form shell.
2. **Root-owned registry** `/etc/laranode/managed.d/<key>.conf`, written by
   `laranode-managed-register.sh` (root only, run by the installer). No registry file, or a unit that does
   not match the key's own allowlist, means exit 3 (refused).
3. **Installer manifest** `/etc/laranode/service-manifest.json` is the source of truth when present:
   a key is registered, and later operated on, only if the manifest lists its service as `managed:true`
   (installed by Laranode). `managed:false` means it was on the host first.
4. **Reversible**: `disable` restores boot enablement and running state byte-for-byte (pool files, units,
   `systemctl enable` state).
5. Test-only path overrides (`LARANODE_SLEEP_TEST=1`) are ignored whenever `SUDO_UID` is set.

Exit codes: 0 ok, 1 failed (rolled back), 2 bad arguments, 3 refused, 4 not privileged.

## Turn it on

1. Admin, **Power** page. Each managed service shows a state badge (running / sleeping / on-demand).
2. Set **idle minutes**, tick the sleep checkbox. Untick to restore everything.
3. **wake** / **sleep now** buttons are manual overrides.

## Trade-offs

* **Hosting DB root CLI.** The canonical unix socket now belongs to the proxy, so root `auth_socket`
  logins through it are denied. Use the private socket `/run/laranode-hostdb/mysqld.sock` for root CLI
  while hostdb sleep is on. TCP and app users are unaffected.
* **First request after sleep** pays the wake time (measured on real systemd: Reverb about 1.4-1.6 s,
  MariaDB/MySQL about 0.6-2 s).
* While hostdb sleep is on, `laranode-db-service.sh` refuses start/stop for that engine (409 in the panel).
* Optional follow-up, not built: split the panel DB onto its own small instance (or SQLite) so the
  hosting DB can sleep on a full install.

## Tests

* `tests/Feature/Sleep/*`: Pest. Real bash against a stub `systemctl` (toggle-off no-op, refusals, panel
  DB guard, rollback, manifest gate, control/status API, non-admin 403, queue wake on dispatch).
* `resources/js/Pages/Power/Power.test.jsx`, `SidebarNavi.test.jsx`: Vitest.
* `tests/system/sleep/matrix.sh [ubuntu|debian|all]`: real systemd + real MySQL (Ubuntu 24.04) / MariaDB
  (Debian 13) in throw-away containers. Measures wake time and idle RSS. SKYTOP only, needs Docker.
* `tests/e2e/power.spec.js`: Playwright against the lab container.
