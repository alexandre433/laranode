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
* **AppArmor.** Ubuntu ships an enforced `usr.sbin.mysqld` profile that only allows sockets under
  `/run/mysqld/`; hostdb sleep moves the real socket to `/run/laranode-hostdb/`, which the profile would
  deny, so the database would fail to start on the first wake. Decision: **refuse, never rewrite policy.**
  `laranode-sleep.sh` refuses `hostdb enable` and `hostdb wake` (exit 3, Power page: *cannot sleep: AppArmor
  profile blocks the moved DB socket*) when AppArmor is on and a `mysqld`/`mariadbd` profile is in enforce
  mode, or when AppArmor is on but its profile list cannot be read (cannot prove it safe). Complain mode
  and AppArmor off do not deny, so they are allowed. The registry carries a root-recorded `apparmor=` hint
  for the page (the panel cannot read the kernel profile list); the script re-checks on every call and is
  authoritative. We do not write `/etc/apparmor.d/local/*` or run `apparmor_parser` from a sudo script.
  **Unproven:** the kernel enforcement itself and the exact profile-line format on a real Ubuntu 24.04
  host (containers have no AppArmor). The decision logic is tested against injected kernel files only.
  The common full-install case is already refused earlier (panel DB = hosting DB).
* **External services** (shared PostgreSQL, Redis, Percona, CloudPanel nginx, a pre-existing
  Apache/PHP-FPM/DB) are listed read-only on the Power page and can never be managed.

## Safety model

1. **One privileged script**: `laranode-scripts/bin/laranode-sleep.sh <key> <action> [idle]`, the only
   sleep-related entry in `/etc/sudoers.d/laranode-sleep`. `key` is one of `reverb|queue|hostdb|fpm`,
   `action` one of `enable|disable|wake|sleep`, `idle` an integer 1..1440. No unit names, no free-form shell.
2. **Root-owned registry** `/etc/laranode/managed.d/<key>.conf`, written by
   `laranode-managed-register.sh` (root only, run by the installer). No registry file, or a unit that does
   not match the key's own allowlist, means exit 3 (refused).
3. **Installer manifest** `/etc/laranode/service-manifest.json` is the source of truth and is
   **required (fail closed)**: a key is registered, and later operated on, only if the manifest lists its
   service as `managed:true` (installed by Laranode). `managed:false` means it was on the host first. No
   manifest (a host the current installer never ran on) means nothing is registered and every action is
   refused (exit 3) until the installer is re-run; a registry file alone never authorises anything.
   The old `LARANODE_DB_INSTALLED_BY_US=1` fallback is gone.
4. **Reversible**: `disable` restores boot enablement and running state byte-for-byte (pool files, units,
   `systemctl enable` state).
5. Test-only path overrides (`LARANODE_SLEEP_TEST=1`) are ignored whenever `SUDO_UID` is set.
6. **php-fpm sandbox escape.** The stock `php*-fpm` unit runs with `ProtectSystem=full`, and a `sudo` child
   inherits that mount namespace, so `/etc` is read-only even for root when the panel calls a script. When
   `/etc/systemd/system` is not writable, `laranode-sleep.sh` re-runs itself once through `systemd-run
   --wait --pipe` (a transient unit owned by PID 1, clean namespace, no environment carried over, same
   validated arguments, exit code preserved). No sudoers widening and the pre-existing php-fpm unit is not
   modified. Other privileged scripts that write under `/etc` meet the same read-only mount when called from
   the web; they are out of scope here.

Exit codes: 0 ok, 1 failed (rolled back), 2 bad arguments, 3 refused, 4 not privileged.

## Bind address (Reverb)

The Reverb sleep socket listens exactly where Reverb itself did. The installer binds Reverb to
`127.0.0.1` on Proxmox/CloudPanel (`REVERB_SERVER_HOST`); `laranode-managed-register.sh` records that as
`bind_host=` and the socket unit is `ListenStream=<bind_host>:<port>`. Default (`0.0.0.0`) when unset.
A registry without a valid dotted-quad `bind_host`, or a `REVERB_SERVER_HOST` that is not a plain IPv4
address (e.g. `::1`), is refused / not registered rather than widened. Enabling sleep can never make a
loopback-only Reverb public (matrix test: only `127.0.0.1:<port>` listens, asleep and awake).

## Re-running the installer with sleep ON

A re-run re-copies the unit templates and enables/starts reverb + queue. The installer then calls
`_reassert_sleep_wake`: for every key whose `/etc/laranode/sleep/<key>.state` says `enabled=1` it runs
`laranode-sleep.sh <key> enable <stored idle>` again, which re-renders the drop-in from the NEW unit's
`ExecStart` (no stale pinned command line after a PHP-version or template change) and puts the service
back to sleep. The original boot-enablement bookkeeping is kept, so a later `disable` still restores it.
The installer re-picks the Reverb port on every run (8080 can become 8081 because the first run's own
sleep socket holds 8080), so the registry `public_port` may change. Sleep follows the registry: `enable`
stops the old sleep socket + proxy before starting the freshly written socket unit, so it binds the NEW
port/host instead of staying on the stale one (found by the `rerun-sleep` scenario).
Proven by the `rerun-sleep` install-test scenario.

## Queue wake dedupe (5 s)

When a job is dispatched while the queue sleeps, the `JobQueued` listener wakes the worker through the
allowlist. Wake requests are deduplicated for 5 s (`Cache::add`, a burst of dispatches wakes once). If the
worker drains the first job and exits (`--stop-when-empty`) and a second job is dispatched inside that same
5 s window, no new wake is requested: the job waits for the 30 s timer tick, so the worst case is about 30 s
of extra latency. Nothing is lost (jobs sit in the database queue). Cron/`schedule:run`, backups and
Reverb clients are unaffected.

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
* `local-dev/install-test/scenarios/rerun-sleep.sh`: installer re-run with sleep ON.

Known limits: a stale `public_port`/`bind_host` after an in-place Reverb port change is only picked up on the
next installer run (re-register + `_reassert_sleep_wake`); `fpm` is gated on the global `php` manifest role,
not per PHP version; with the manifest missing even `disable` is refused (re-run the installer).
