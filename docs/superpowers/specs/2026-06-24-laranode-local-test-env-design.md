# Laranode local test/dev environment — design spec

- **Date:** 2026-06-24
- **Status:** Draft for review
- **Author:** brainstorming session (research-backed; key claims live-verified on this machine)

## 1. Goal & success criteria

Make Laranode fully workable on the local Windows 11 machine (Docker Desktop, WSL2 backend). Four goals, all required:

1. **Dev the app + UI** — edit on Windows, see changes live (Inertia/React + PHP) without rebuilds.
2. **Exercise real provisioning** — actually create Apache vhosts, per-site PHP-FPM pools, MySQL DBs, SSL, ufw rules, and read live stats against real systemd-managed services.
3. **Green the Pest suite** — existing `tests/Feature` + `tests/Unit` pass locally.
4. **Fork-and-extend safely** — reproducible, disposable; resets cleanly; does not pollute the Windows host beyond the repo already present.

**Done when:**
- `make up` boots a container where `systemctl status apache2 mysql php8.4-fpm` all report active, and the panel is reachable at `http://localhost`.
- Creating a website through the UI produces a real Apache vhost + PHP-FPM pool and serves the site.
- `make test` runs the Pest suite green (with two known system-dependent tests explicitly skipped on the fast path — see §9).
- SSL toggle drives certbot against a local Pebble ACME server end-to-end.
- `make nuke` (`docker compose down -v`) removes everything; re-`make up` rebuilds from scratch.

## 2. Chosen approach: one container = one VPS

A **single disposable Ubuntu 24.04 container running systemd as PID 1**, with the working tree bind-mounted to the panel's hardcoded path `/home/laranode_ln/panel`.

**Why one container (not docker-compose with separate db/web services):** the panel manages services on its *own* host — `systemctl status mysql`, `a2ensite`, PHP-FPM pools, sudo shell scripts, `/proc`. Splitting MySQL/Apache into networked containers makes `systemctl status mysql` return "unit not found" and breaks every provisioning action. The production model is one host; the test box must be one host.

**Why bind-mount to the exact path:** both systemd unit templates (`laranode-reverb.service`, `laranode-queue-worker.service`) **and** the sudoers line (`laranode-installer.sh:172`) hardcode `/home/laranode_ln/panel`. Relocating breaks them; mounting there keeps every path resolution unchanged.

### Live-verified on this machine (2026-06-24)
- WSL `2.6.1.0` (≥2.5.1 → cgroup v2 default, no `.wslconfig` kernel hack needed).
- `docker run ... stat -fc %T /sys/fs/cgroup` → `cgroup2fs`.
- systemd-as-PID-1 container (`--privileged --cgroupns=host -v /sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock`) reached `systemctl is-system-running` = **running** on first try; `ps -p 1` = `systemd`; installing + `systemctl start cron` → **active**. Real service management confirmed.

## 3. Locked decisions

| Topic | Decision | Consequence |
|---|---|---|
| SSL | **Pebble ACME** (faithful local ACME) | Pebble + challtestsrv sidecars under an opt-in `ssl` compose profile; the ssl-manager's domain-accessibility gate must be bypassed and certbot pointed at Pebble — done via a **patched copy** of the script, not by editing the repo script (see §7). |
| PHP Manager | **Multi-version** (runtime installs allowed) | Container keeps outbound net at runtime; ondrej PPA pre-added at build; PHP Manager can apt-install/remove extra `php*-fpm` versions. Less air-gapped, accepted. |
| Tooling location | **Gitignored `local-dev/`** | All Docker/compose/entrypoint/Makefile files live under `local-dev/` (added to `.gitignore`). Keeps the fork's diff vs upstream clean. |
| Reverb + queue | **Always-on** | `laranode-reverb` (ws :8080) and `laranode-queue-worker` started as systemd units at boot, like production; enables real-time dashboard testing. |

## 4. Architecture

**Service `laranode`** (Ubuntu 24.04, systemd PID 1) — the simulated VPS:
- Run config: `privileged: true`, `cgroupns_mode: host`, `volume /sys/fs/cgroup:/sys/fs/cgroup:rw` (rw required — systemd 255 refuses ro), `tmpfs: /run, /run/lock, /tmp`, `stop_signal: SIGRTMIN+3`, `cap_add: [NET_ADMIN, NET_RAW]` (explicit; redundant under privileged).
- Runs as real systemd units: apache2, mysql, php8.4-fpm, sysstat, laranode-reverb, laranode-queue-worker (+ ufw enabled).

**Mounts & volumes:**
- Bind: `./ → /home/laranode_ln/panel` (live editing from Windows).
- Named volumes overlaying the bind for `vendor/` and `node_modules/` — Linux-native, so Windows file semantics and OS-specific binaries never clash, and I/O is fast.
- Named volume for `/var/lib/mysql` (DB persists across restarts, wiped by `down -v`).
- **Executable scripts on a Linux-native path** (see §6) — not the bind mount.

**Ports** (bound `0.0.0.0` — WSL2 `127.0.0.1` is unreachable from Windows): `80:80`, `443:443`, `8080:8080` (Reverb), `5173:5173` (Vite HMR), `3306:3306` (optional DB inspection).

**SSL sidecars** (compose `profiles: [ssl]`, opt-in): `pebble` + `pebble-challtestsrv` on the default network; `PEBBLE_VA_ALWAYS_VALID=1` toggle for smoke tests.

## 5. System-fidelity matrix (honest limits)

| Capability | Local fidelity |
|---|---|
| Apache vhosts, MySQL DBs, PHP-FPM pools, file manager, live stats (top/free/df/systemctl/`/proc`/sar) | ✅ Real, against actual systemd units |
| Dev loop (edit → live), Pest suite | ✅ Real (Pest on SQLite, see §9) |
| **ufw** | ⚠️ Rules apply in the container's own network namespace only — correct for a VPS sim, but won't filter traffic from Windows. Full cross-host fidelity needs a real VM (out of scope). |
| **SSL** | ⚠️ Real Let's Encrypt impossible without public DNS. Pebble exercises the **real ACME protocol** locally; the Pebble CA is intentionally untrusted by browsers (cert chain valid, browser trust out of scope). |
| **PHP Manager new-version install** | ⚠️ Works but needs runtime net (ondrej PPA); shakier than pre-baked 8.4 (adversarially flagged). |

## 6. The Linux-native script path (critical mechanism)

**Problem:** the app invokes privileged scripts as `sudo <bin_path>/script.sh` (direct exec, needs +x). Files on a Windows-side bind mount have unreliable exec bits over Docker Desktop's 9p layer, and `laranode-installer.sh:271` `chmod 100`s them. So scripts can't run reliably straight off the bind mount.

**Solution:** redirect the script directory to a Linux-native location, populated at boot.
- One in-repo change: `config/laranode.php` →
  `'laranode_bin_path' => env('LARANODE_BIN_PATH', base_path('laranode-scripts/bin')),`
  (prod-safe: default unchanged; env-driven). **Flagged for approval** — see §11.
- `.env.docker` sets `LARANODE_BIN_PATH=/opt/laranode/bin`.
- Dockerfile copies `laranode-scripts/bin/*` → `/opt/laranode/bin-src` at build (a snapshot).
- `entrypoint-setup.sh` copies `/opt/laranode/bin-src/*` → `/opt/laranode/bin`, `chmod +x`, then overwrites `laranode-ssl-manager.sh` with the patched copy from `local-dev/` (see §7).
- Container sudoers line whitelists `/opt/laranode/bin/*.sh` (entrypoint writes it; we control it).
- `make sync-scripts` re-copies after editing a real script (scripts change rarely).

**Alternative if the config change is rejected (zero repo change):** mount a named volume over the `laranode-scripts/bin` subdirectory of the bind mount and populate it the same way — the existing sudoers glob already matches that path. Less transparent (shadows the repo dir); offered as fallback in review.

## 7. SSL via Pebble

- `local-dev/bin/laranode-ssl-manager.sh` = patched copy of the repo script with two deltas:
  1. **Skip** `check_domain_accessibility` (the `curl http://$domain` gate at line 48/231 that `exit 1`s for non-public domains).
  2. Point certbot at Pebble: `--server "$LARANODE_ACME_SERVER" --no-verify-ssl --http-01-port 5002` when `LARANODE_ACME_SERVER` is set (Pebble dir URL on the compose network); otherwise behave exactly like upstream.
- The repo's `laranode-scripts/bin/laranode-ssl-manager.sh` is **untouched** (the patched copy lives in gitignored `local-dev/` and is injected into `/opt/laranode/bin` by the entrypoint).
- A `.test` domain resolvable on the compose network (via challtestsrv) is used for issuance smoke tests.

## 8. The installer fork

`local-dev/install/laranode-installer.docker.sh` — non-interactive, container-faithful fork of `laranode-scripts/bin/laranode-installer.sh`, with `set -e` + `DEBIAN_FRONTEND=noninteractive`. Deltas from upstream (line numbers from the current script):

| Upstream | Change |
|---|---|
| `:205` `git clone …/laranode.git` | **Removed** — repo is already bind-mounted. |
| `:219,227,228` `curl icanhazip.com` → APP_URL/REVERB_HOST/VITE_REVERB_HOST | **Removed** — values baked to `localhost` from `.env.docker`. |
| `:295` manual `php artisan laranode:create-admin` (echo only; never actually run) | **Replaced** — entrypoint seeds the admin non-interactively from `ADMIN_EMAIL`/`ADMIN_PASSWORD`. |
| `:180` composer, `:188` node | Moved to **Dockerfile build layer** (network available at build; runtime needs no internet for base deps). |
| `:64-71` random MySQL passwords | Keep the create-user/db flow but use a **fixed known password** captured into `.env.docker DB_PASSWORD` so app and DB agree. |

Everything else (apache modules, sysstat enable, templates, ufw allow rules, systemd unit install) is preserved as-is.

## 9. Pest path (decoupled from the systemd box)

- **One in-repo change:** uncomment the two lines in `phpunit.xml` → `DB_CONNECTION=sqlite`, `DB_DATABASE=:memory:`. Verified the **only** blocker: all migrations are standard Blueprint DDL SQLite handles (the `users.role` enum degrades to string). Ensure `APP_KEY` is set (`.env` present / `key:generate`).
- `make test` runs `php artisan test` — needs no MySQL/systemd/sudo; runs in a light php-cli exec **or** directly on the Windows host (PHP 8.4.20 already installed).
- **Fail loud — two known-failing tests:** `tests/Feature/Filemanager/CreateFileTest.php` happy paths ("it can create a new file" / "…directory") call real `sudo laranode-file-permissions.sh` and hit `null` `auth()` → 500. On the fast SQLite path they are **skipped with a documented reason**; for full fidelity they run inside the systemd container with `actingAs(User::factory()->create())`. `TopCommandServiceTest` mocks `Process` and passes everywhere. The suite report must show these as skipped, never silently green.

## 10. Dev loop & disposability

- Bind mount = edit PHP/React on Windows, instantly live in the container. PHP/Inertia changes need no restart; run `npm run dev` (host `0.0.0.0`, port 5173) inside the container for Vite HMR. `npm run build` only for a production-like check.
- `vendor/` + `node_modules/` in named volumes → fast, no Windows/Linux binary clashes.
- Disposability: container + named volumes removed by `docker compose down -v`; only host artifact is the repo. Rebuild image only when apt packages / Dockerfile change.
- **Perf note:** Windows-path bind mounts are slower over 9p. Acceptable for dev; if it bites, relocating the repo into the WSL2 filesystem (edited via VS Code WSL remote) is a future optimization — not in scope now.

## 11. In-repo changes (everything else is gitignored `local-dev/`)

Minimizing the fork's diff vs upstream. Only two files outside `local-dev/`:
1. `phpunit.xml` — uncomment the two SQLite env lines. (Genuine test fix.)
2. `config/laranode.php` — wrap `laranode_bin_path` in `env(..., base_path(...))`. (Prod-safe; **needs your sign-off**. If rejected, use the §6 volume-overlay fallback for zero repo change.)

`.gitignore` gains `/local-dev` (the tooling dir itself is not a code change to the app).

## 12. File inventory (under `local-dev/`)

```
local-dev/
  Dockerfile                       # systemd base; pre-bake apt set + composer + node; ondrej PPA; mask noisy units; STOPSIGNAL SIGRTMIN+3
  docker-compose.yml               # laranode service (+ pebble, challtestsrv under profile: ssl)
  entrypoint-setup.sh              # idempotent first-boot provisioning (guarded by a sentinel file)
  install/laranode-installer.docker.sh   # the installer fork (§8)
  bin/laranode-ssl-manager.sh      # patched SSL script for Pebble (§7)
  .env.docker                      # localhost APP_URL/REVERB/DB, fixed DB pw, ADMIN_* creds, LARANODE_BIN_PATH, LARANODE_ACME_SERVER
  Makefile                         # up / sh / test / ssl-test / verify / sync-scripts / nuke
```

`entrypoint-setup.sh` responsibilities: enable+start apache2/mysql/php8.4-fpm/sysstat; create MySQL `laranode` user+db with the fixed pw; install apache2-default + service templates; `a2enmod`/`a2enconf`; write the container sudoers line (`/opt/laranode/bin/*.sh`); populate `/opt/laranode/bin`; `composer install`; `cp .env.docker .env`; `key:generate`/`migrate`/`db:seed`/`storage:link`/`reverb:install`; seed admin; seed one `sadc` sample so dashboard history isn't empty; `ufw --force enable` + allow 22/80/443/8080; `daemon-reload` + enable/start reverb + queue-worker.

## 13. Verification plan

- `make verify`: asserts `ps -p 1` = systemd, `systemctl is-system-running` ∈ {running, degraded}, `systemctl is-active apache2 mysql php8.4-fpm`.
- Manual smoke: log in at `http://localhost`; create a website → confirm vhost file + PHP-FPM pool exist and the site serves; toggle SSL with the `ssl` profile up → confirm a cert issues against Pebble; watch the admin dashboard update over Reverb.
- `make test` green (minus the two documented skips).

## 14. Out of scope

- Real public-DNS Let's Encrypt certs / browser-trusted SSL.
- ufw filtering traffic originating from Windows (container-netns only).
- Production deployment changes (this is local dev/test tooling).
- Refactoring the upstream installer or app code beyond the two flagged in-repo changes.
