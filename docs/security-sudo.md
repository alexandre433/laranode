# Privileged scripts: trust model and layout

The panel runs as `www-data`. Every privileged operation is a root script that `www-data`
may start through `sudo`. A compromised web process controls every argument it passes, so
the scripts, the directories they live in and every value they accept are part of the
security boundary.

## Layout

| Path | Owner / mode | Purpose |
|------|--------------|---------|
| `/usr/local/lib/laranode/bin/*.sh` | root:root 755 | the only scripts sudoers names |
| `/usr/local/lib/laranode/lib/validate.sh` | root:root 644 | shared guards (sourced by every script) |
| `/usr/local/lib/laranode/templates/*` | root:root 644 | Apache vhost, PHP-FPM pool, systemd templates |
| `/usr/local/lib/laranode/etc/sudoers.d/*` | root:root 644 | staged drop-ins, installed to `/etc/sudoers.d` at 440 |
| `/home/laranode_ln/panel` | laranode_ln:laranode_ln, dirs 750 / files 640 | the checkout; `www-data` (group) reads, never writes |
| `…/panel/storage`, `/home/laranode_ln/logs` | 770 / 660 | the only web-writable places (`bootstrap/cache` is NOT: Laravel `require`s it on every artisan call) |
| `…/panel/.env` | 640 | not group-writable |

The panel finds the scripts through `.env`: `LARANODE_BIN_PATH=/usr/local/lib/laranode/bin` and
`LARANODE_TEMPLATES_PATH=/usr/local/lib/laranode/templates`.
Sudoers drop-ins grant one explicit path per script, never a glob, never a directory, never a
bare binary (there is no grant for `ufw`, `a2dissite`, `rm`, `tar` or `systemctl`).

## Updating the panel

The root-owned copy does not change when the checkout does. After pulling new code:

```bash
sudo -u laranode_ln git -C /home/laranode_ln/panel pull
sudo /usr/local/lib/laranode/bin/laranode-sync-scripts.sh      # re-copies scripts, lib, templates, drop-ins
```

Never run git as root in the checkout. The sync script is root-only, but root never opens a path in
the checkout itself: every directory listing and file read runs as `laranode_ln` (`runuser`), so a
`laranode_ln` that races a symlink swap (`templates -> /etc`) can only hand over what it could read
anyway, never a root-only file. Root writes the bytes (names checked, size capped at 2 MiB) into a
root-only staging directory and judges the COPY, so the panel account cannot swap a file between
the check and the install. It `bash -n`s every script, validates each sudoers drop-in with
`visudo -c`, holds the four templates the installer installs verbatim as root (the queue and reverb
systemd units, the scheduler cron line, the panel Apache vhost) to an exact-line allowlist (a unit
with `User=root`/`ExecStartPre=`, a cron line for root, a `LoadModule`/`Include` in the vhost refuses
the sync), and then applies a strict allowlist to the sudoers drop-ins: a drop-in
may only hold blank lines, plain comments (never `#include`/`#includedir`, never a trailing ``),
`Defaults!<dest>/bin/laranode-<name>.sh !requiretty`, and
`www-data ALL=(ALL|www-data) NOPASSWD: <dest>/bin/laranode-<name>.sh` (optionally followed by `""`).
`NOPASSWD: ALL`, a comma list, another user, a wildcard, CR/NUL bytes or an unterminated last line
refuse the whole sync. Then the staged directory is swapped in atomically. Re-running the installer
does the same.

## Root never executes panel PHP

Part of the checkout is writable by the web user (`storage/`). Laravel `require`s
`bootstrap/cache/*.php` and the whole `vendor/` tree on every `php artisan` call, and composer
runs the project's scripts. So the installer and the upgrade path run `composer` and `php artisan`
as `laranode_ln` (`_as_panel_user` / `_artisan` in the installer), never as root; the tree is
`chown`ed to `laranode_ln` and the generated `bootstrap/cache/*.php` deleted and rebuilt before the
first PHP run, and `bootstrap/cache` stays 750 / 640. The `.env` file is owned by `laranode_ln`.
Run admin commands the same way: `sudo -u laranode_ln php8.4 artisan …`. The same holds for
`npm install`/`npm run build` (node build scripts run project code) and for every `find -exec chmod`
over the tree (a root `chmod <path>` follows a symlink swapped in after `find` looked): all run as
`laranode_ln`.

Root-run installer steps render only from the root-owned copy in `/usr/local/lib/laranode/templates`
(the scheduler cron line, the systemd units, the panel vhost), never from the checkout.
`phase_fetch_panel` publishes that copy (through the sync, which judges it) before `phase_webserver`
needs it; a re-run uses the already installed, root-owned sync script. The first install takes the
sync script from the fresh clone ONCE, into a root-only temp dir, before the tree is handed to
`laranode_ln` (`_stash_sync_script`; `cp -P`, must be a regular file), and runs that private copy.
The panel `.env` is seeded from `.env.example` (`_seed_env`) and edited (`env_set`) AS `laranode_ln`
(the value travels on stdin, not in argv): a root `cp`/`sed -i`/`>>` there follows a symlink
`laranode_ln` planted (`.env.example -> /root/.laranode-credentials`, `.env -> any file`). A unit test
fails when any root-run cp/mv/sed/chown/chmod/chgrp/install/tee/ln/rm/mkdir/bash/find or `>`/`>>` hits
a path derived from `PANEL_PATH` (`$p`, `$env`, `$sync`, ...) outside `_as_panel_user` or a short
reasoned allowlist; `sudo-hardening/assert-installer-env.sh` proves the two symlink cases in a real
container.

The installer also refuses a host with `fs.protected_hardlinks` other than 1 (see Known limits), and
every sudo-able script resets `PATH` before its first command (`dirname`), not only inside
`validate.sh`.

## What every script enforces (`lib/validate.sh`)

* argument count, then an allowlist per value (bash `[[ =~ ]]`, which matches the whole value
  including newlines: `echo | grep` checked one line at a time and let `ok\nevil` through);
* hosted-user accounts only: `<name>_ln`, uid >= 1000, home `/home/<name>_ln`; never root, a system
  account or `laranode_ln`;
* no value reaches a shell, `sed`, `eval`, a glob or an option position (`--` before operands,
  templates rendered by parameter expansion);
* paths are resolved and prefix-checked; file work inside a tenant's home runs as that tenant
  (`runuser`) or on an already-opened inode (`/proc/self/fd`), so a symlink swapped in after the
  check changes nothing;
* templates must be exactly the files in `/usr/local/lib/laranode/templates` (www-data cannot
  hand root a template it wrote);
* `/tmp` hand-over files (backups, restores, cron tables) must match a fixed name shape.

`laranode-ufw.sh` is the firewall front door: only `status`, `status-numbered`, `show-added`,
`enable`, `disable`, `allow`, `deny`, `delete`; rule tokens are limited to the ufw rule grammar
(ports, ranges, `port/proto`, IPs/CIDRs, `from to any port proto in out tcp udp`, or a single
application-profile name). Options (`-…`) never pass through.

## Tests

* `local-dev/install-test/sudo-hardening/run-fast.sh`: lays the panel out like the installer in a
  throwaway `debian:13` container, then
  * `assert-perms.sh`: every sudo-granted path is root-owned and not group/other-writable; `.env`
    is <= 640; nothing under the panel home is group/other-writable outside storage and logs, `www-data` cannot
    create or write in `bootstrap/cache`, `fs.protected_hardlinks` is 1, and no installed script runs
    a command from a hostile caller PATH (trap binaries first on PATH must never fire);
  * `assert-sync.sh`: `laranode-sync-scripts.sh` publishes a clean tree and refuses each hostile
    drop-in / symlinked source / bad script / hostile template line (one case per allowlist rule),
    and keeps root-only files out of the published tree while a symlink swap races the sync;
  * `assert-installer-env.sh`: the installer's `_seed_env` / `env_set` never copy or edit through a symlink
    `laranode_ln` planted (`.env.example` -> root-only file, `.env` -> a root-owned file);
  * `assert-hostile.sh`: for every sudo'd script, hostile arguments (root, `../`, newline, spaces,
    sed metacharacters, globs, option injection, symlinks) run as `www-data`; each must exit
    non-zero AND leave a host-state snapshot unchanged; valid PHP-shaped calls must still work.
* `local-dev/install-test/mutation-smoke-sudo.sh`: reverts each guard in a copy and requires the
  harness above to go red.
* The same two assertions run at the end of every container install scenario (`lib.sh` hook).

## Known limits / follow-ups

* Time-of-check/time-of-use against a tenant is mitigated (fd/`runuser`), not eliminated, for the
  root scripts that must touch tenant-controlled paths.
* The installer trusts the tree it has just cloned. Residuals of the root-owned-copy model: the
  installer file itself, when started from the checkout, is the admin's choice (run it from a fresh
  download); the other templates (site vhost, php-fpm pool) still pass through the sync without a
  line allowlist (follow-up); a changed sync script takes effect one run later (a run uses the
  installed copy). Pin the clone ref (follow-up).
* On Proxmox hosts `www-data` is still the web user; a dedicated panel web user is a follow-up.
* The queue worker runs as `laranode_ln`, but sudoers grants `www-data` only: a queued job that
  shells out through sudo would fail. No such job exists today.
* `create-directory.sh` runs `chown -R -h` as root over a tenant tree; hard-link tricks are blocked
  by `fs.protected_hardlinks=1` (asserted by `assert-perms.sh`, and the installer dies where it is
  not 1), not by the script.
* `laranode-php-uninstall.sh` refuses `8.4` (the version that runs the panel); other versions can
  be removed.
* Opening a path that a tenant controls is refused unless it is a regular file or directory (a FIFO
  would park the root script for ever); a swap after that check can only delay, not redirect it.
