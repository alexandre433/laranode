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

Never run git as root in the checkout. The sync script is root-only. It copies every file with
`cp -P` (no symlink is followed) into a root-only staging directory and judges the COPY, so the
panel account cannot swap a file between the check and the install. It `bash -n`s every script,
validates each sudoers drop-in with `visudo -c`, and then applies a strict allowlist: a drop-in
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
Run admin commands the same way: `sudo -u laranode_ln php8.4 artisan …`. Remaining root step: the
installer's `npm install`/`npm run build` still run as root over the `laranode_ln`-owned tree (see
Known limits).

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
    create or write in `bootstrap/cache`, `fs.protected_hardlinks` is 1;
  * `assert-sync.sh`: `laranode-sync-scripts.sh` publishes a clean tree and refuses each hostile
    drop-in / symlinked source / bad script (one case per allowlist rule);
  * `assert-hostile.sh`: for every sudo'd script, hostile arguments (root, `../`, newline, spaces,
    sed metacharacters, globs, option injection, symlinks) run as `www-data`; each must exit
    non-zero AND leave a host-state snapshot unchanged; valid PHP-shaped calls must still work.
* `local-dev/install-test/mutation-smoke-sudo.sh`: reverts each guard in a copy and requires the
  harness above to go red.
* The same two assertions run at the end of every container install scenario (`lib.sh` hook).

## Known limits / follow-ups

* Time-of-check/time-of-use against a tenant is mitigated (fd/`runuser`), not eliminated, for the
  root scripts that must touch tenant-controlled paths.
* The installer trusts the tree it has just cloned; a re-run trusts the checkout as `laranode_ln`
  left it. Pin the clone ref (follow-up).
* On Proxmox hosts `www-data` is still the web user; a dedicated panel web user is a follow-up.
* The queue worker runs as `laranode_ln`, but sudoers grants `www-data` only: a queued job that
  shells out through sudo would fail. No such job exists today.
* The installer's `npm install` / `npm run build` still run as root over the `laranode_ln`-owned
  tree (node build scripts execute project code): a compromised `laranode_ln` (queue worker, cron)
  can therefore reach root on the next install/upgrade. Moving the build to `laranode_ln` is a
  follow-up.
* `create-directory.sh` runs `chown -R -h` as root over a tenant tree; hard-link tricks are blocked
  by `fs.protected_hardlinks=1` (asserted by `assert-perms.sh`), not by the script.
* `laranode-php-uninstall.sh` refuses `8.4` (the version that runs the panel); other versions can
  be removed.
* Opening a path that a tenant controls is refused unless it is a regular file or directory (a FIFO
  would park the root script for ever); a swap after that check can only delay, not redirect it.
