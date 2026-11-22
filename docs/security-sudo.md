# Privileged scripts: trust model and layout

The panel runs as the web user: `www-data`, or the dedicated system account `laranode_web` on a
Proxmox host (there `www-data` is pveproxy's user and group `www-data` reads `/etc/pve/priv`).
Every privileged operation is a root script that the web user may start through `sudo`. A
compromised web process controls every argument it passes, so the scripts, the directories they
live in and every value they accept are part of the security boundary.

## The web user (`/etc/laranode/host.conf`)

The installer records `web_user=` and `ufw=` in the root-owned `/etc/laranode/host.conf` (0644,
written on every host; on a plain host it says `web_user=www-data`, `ufw=1`, i.e. what was always
true). On Proxmox: the panel's own Apache runs `User/Group laranode_web` (conf `laranode-web-user`),
the panel vhost hands PHP to its own pool `laranode-panel` (`/run/php/laranode-panel.sock`, user
`laranode_web`), `laranode_web` (uid 1-999, never in group `www-data`) joins `laranode_ln`, and
`www-data` is taken out of it. Upgrade from an install that ran as `www-data`: that install put
`www-data` in every tenant's `{user}_ln` group (homes 770); on the switch `laranode_web` joins each
tenant group and `www-data` leaves it (`_migrate_tenant_groups`; only groups named `{user}_ln` with a
same-name user of uid >= 1000 and home `/home/{user}_ln`; scenario `pve-upgrade`). A Proxmox host with a pre-existing Apache or php8.4-fpm is refused
(their `User` / pools are their owner's). `ufw=0` on Proxmox unless `LARANODE_PVE_UFW=1`: the
`laranode-ufw` drop-in is not installed (removed if present) and the Firewall page is hidden
(`LARANODE_FIREWALL_ENABLED=false`; UX only, the drop-in is the gate).

Readers trust the file only as a regular, root-owned, not group/world-writable file with
allowlisted values (`web_user=www-data|laranode_web`, `ufw=0|1`); anything else refuses:
* `laranode-sync-scripts.sh` renders the allowlisted, staged drop-ins for the web user (a fixed
  substitution of the two fixed grant prefixes, re-checked with `visudo`; no line may still name
  `www-data`). On a Proxmox host it refuses to publish grants for `www-data`, with or without the file.
  Its paths (`/usr/local/lib/laranode`, `/etc/sudoers.d`, `host.conf`, `/etc/pve`) are fixed: the
  `LARANODE_LIB_DEST` / `LARANODE_SUDOERS_DIR` / `LARANODE_HOST_CONF` / `LARANODE_PVE_DIR` seams are
  honoured only with `LARANODE_INSTALLER_TEST=1`, so root's environment cannot move a trusted path.
* `lib/validate.sh` (every sudo-able script) sets `LN_WEB_USER` from it (fixed path, no
  environment override) and dies on a Proxmox host whose web user would be `www-data`.

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
  line allowlist (follow-up); a run uses the installed (root-owned) sync copy, never the checkout's;
  when that run replaced the installed sync (an upgrade), the installer runs the NEW installed copy
  once more in the same run (an old sync renders the grants for `www-data`, not host.conf's web
  user), and with a dedicated web user any laranode drop-in still granting `www-data` is removed and
  the install stops. The clone ref is pinned: `LARANODE_REF` is required for a
  fresh clone and must be a release tag or a full 40-character commit id (a branch, `HEAD`,
  `FETCH_HEAD`, `origin/*`, `refs/*` or a short id is refused: it moves or is ambiguous); the clone
  runs as `laranode_ln`, HEAD must equal the commit the ref names, and `git status --porcelain` (as
  `laranode_ln`) must be empty. A re-run with `LARANODE_REF` set checks the same on the existing
  checkout. The clean-tree check holds within the trust model only: `laranode_ln` owns the tree and
  could change it after the check; it catches a stray edit or a planted file before the install, not a
  hostile panel account. `git status --porcelain` does not list git-IGNORED files (`vendor/`,
  `bootstrap/cache/*.php`, `storage/`, `.env`): a planted ignored file survives the check. No root path
  reads or runs them (git, composer, artisan and npm all run as `laranode_ln`), so this stays inside the
  same trust model. The check compares content, staged and untracked files, not file MODE bits
  (`core.fileMode=false`): the installer itself re-modes the whole tree (640/750) on every install, so
  comparing modes would make every re-run with `LARANODE_REF` die (PR #12 r1; scenario `rerun`).
  `package-lock.json`/`composer.lock` are gitignored and do not count. A re-run with `LARANODE_REF`
  refuses a tree whose tracked files were edited: unset `LARANODE_REF` to keep such a checkout.
  A release process that sets a default pinned ref is a follow-up.
* The upgrade moves a tenant's `{user}_ln` group only when that user still exists (same-name account,
  uid >= 1000, home `/home/{user}_ln`): an orphan group whose user was removed is skipped and
  `www-data` stays in it. It has no home, so nothing is exposed. The move runs in `phase_webserver`
  after `apachectl configtest`, right before the reload that switches Apache to the web user, so a
  failed re-run (bad ref, sudoers, packages, config test) leaves the old setup serving. Only a failing
  reload itself can follow the move (an Apache this installer owns has no rollback journal).
* A Proxmox host with a pre-existing Apache/php8.4-fpm cannot get the dedicated web user: refused.
* The queue worker runs as `laranode_ln`, but sudoers grants `www-data` only: a queued job that
  shells out through sudo would fail. No such job exists today.
* `create-directory.sh` runs `chown -R -h` as root over a tenant tree; hard-link tricks are blocked
  by `fs.protected_hardlinks=1` (asserted by `assert-perms.sh`, and the installer dies where it is
  not 1), not by the script.
* `laranode-php-uninstall.sh` refuses `8.4` (the version that runs the panel); other versions can
  be removed.
* Opening a path that a tenant controls is refused unless it is a regular file or directory (a FIFO
  would park the root script for ever); a swap after that check can only delay, not redirect it.
