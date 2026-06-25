# Laranode feature roadmap

- **Date:** 2026-06-25
- **Status:** Agreed (umbrella roadmap; each sub-project gets its own spec → plan → build cycle)
- **Source:** research workflow (4 codebase mappers + 3 competitor researchers + synthesis), then user prioritization.

## Objective

Grow Laranode into a free, self-hosted **"cPanel + a bit of Laravel Cloud"** for solo / small-team self-hosters: a panel that manages its **own** Ubuntu host with multi-engine managed databases, intrusion prevention, and git-push deploys. **Single-host** by design (not multi-server fleets). Engines are provisioned **on the panel host** alongside MySQL (not remote clusters).

## Current state (baseline)

- **Databases:** MySQL-only, administered via Laravel's DB facade issuing raw SQL (no sudo scripts). 1 db = 1 localhost MySQL user with GRANT ALL. Charset/collation dropdowns, per-user `database_limit`, encrypted password, user-scoped ownership + policy. **No `engine` column. Zero tests.**
- **Websites:** full vhost lifecycle via sudo-script chain (`create-directory` → `add-php-fpm-pool` → `add-vhost`), per-user FPM pools (open_basedir), certbot SSL toggle, user-settable document_root (supports `/public`). **No git/deploy/webhook capability** — docroots start empty, filled via file manager.
- **Firewall:** UFW-only, via **inline** `sudo ufw` in PHP Actions (bypasses the `*.sh` sudoers glob — relies on out-of-band sudoers). Enable/disable, allow/deny/delete, numbered-status parser. Admin-only. **No fail2ban.** `AccessLogEvent` + `LogMonitorCommand` are orphaned dead stubs.
- **Platform:** Controller → FormRequest → Service/Action. Privileged ops via whitelisted `laranode-scripts/bin/*.sh` + one NOPASSWD sudoers glob. Queue (database driver) + Reverb both run as systemd services **but are idle — zero Jobs dispatched, no scheduler, no job-progress channel, no audit log; all mutations are synchronous HTTP.** Two roles (admin/user); mandatory 1:1 `{username}_ln` Linux account; quotas = `domain_limit` + `database_limit`.
- **Local dev env:** systemd-enabled Ubuntu 24.04 Docker container (branch `local-dev-env`, pushed) so system-touching features can be exercised off a live VPS.

## The structural blocker (why the foundation comes first)

Every requested feature — git clone+build, fail2ban log scans, multi-engine installs, DB dumps — is **long-running and will time out in a synchronous HTTP request.** There is no queued-job convention, no job-progress websocket pattern, no scheduler, and no audit log. The queue worker and Reverb server are already deployed and idle, so the foundation is **wiring a convention, not new infrastructure.** Build it once; every feature reuses it.

## "Add database engines" is three different feature shapes

- **Relational** (PostgreSQL, SQLite) — fits today's create-db + user model. Postgres = best fit; SQLite = a managed homedir file (no users/ports/remote).
- **Cache** (Redis, Memcached) — *not* databases; no db/user/grants. Separate "Cache Services" UI (server-level enable/status/connection/flush).
- **Document** (MongoDB) — role-based no-SQL users; does not map onto the unified relational privilege UI. **Kept** (per decision): the driver interface is designed from the start to allow an engine-specific user/role flow, but the Mongo driver itself ships after the relational engines prove the seam.

## Decisions (2026-06-25)

1. **Foundation first** — build async/progress/audit before any feature.
2. **All three named tracks, staged** — full sequence below.
3. **Keep MongoDB** — design the DB driver interface to accommodate its role-based user model from the start; ship the driver later in the sequence.
4. **Extras folded in:** Backups (S3), per-user Cron, Monitoring/alerts, bundled DB GUI (Adminer).

## Roadmap (phased; each sub-project = its own spec → plan → SDD build)

### Phase 0 — Foundation
1. **`platform-async-progress`** ⭐ — queued-Job convention (`ShouldQueue` wrapping a Service), user-scoped `ProgressEvent` + private channel auth, `operations`/audit table (actor, operation, args summary, buffered output, status, timestamps), React job-progress component, configure the Laravel scheduler hook. Proof: convert one existing slow op (SSL generate) to async with live progress. *(M, low risk; no dependencies.)*
2. **`db-engine-abstraction`** — behavior-preserving refactor: add nullable `engine` column (default `mysql`), `DatabaseEngine` driver interface (designed to allow relational **and** Mongo role-based user flows), move inline MySQL SQL into `MysqlDriver`, make charset/collation engine-specific/nullable, generalize `/mysql` → `/databases` with engine dispatch (keep `mysql.*` route aliases), add first DB-path tests. Ships no new engine. *(L, med; parallel with #1.)*

### Phase 1 — Databases (relational)
3. **`db-postgres`** — `PostgresDriver` + `laranode-postgres.sh` (createdb/createuser/psql as postgres) + installer + sudoers; encoding/locale; pg_stat stats; connection string; tests.
4. **`db-sqlite`** — `SQLiteDriver` as managed homedir files; size-on-disk; connection path; no user/port/remote UI; tests.
5. **`dbgui-adminer`** — panel-authenticated Adminer (or phpMyAdmin) for browsing databases; slots here so there's something to browse. *(Mind the added security surface.)*

### Phase 2 — Security
6. **`security-fail2ban`** — `laranode-fail2ban.sh` (fail2ban-client status/ban/unban/jail config) + `jail.local` templates + installer (fail2ban, `banaction=ufw`, **seed `ignoreip` with panel/loopback/admin IP**) + admin UI (jails+thresholds, banned-IPs table+unban, manual ban, allowlist editor, recidive jail). Also **convert inline `sudo ufw` to a script + `sudoers.d` drop-in** and expose `ufw limit`. *(Footgun: allowlist the panel/admin IP and set banaction BEFORE enabling jails or you lock yourself out.)*

### Phase 3 — Deploy (flagship)
7. **`deploy-git-push`** — `git_*` columns on websites (repo_url, branch, encrypted deploy_key, webhook token, build commands, last_deployed_at, deploy_log); `laranode-deploy-git.sh` (clone/pull as `{user}_ln` with SSH deploy-key injection, then configurable build steps) ; `DeployWebsiteJob` (queued) with Reverb progress; manual Redeploy + HMAC-verified public webhook `/deploy/webhook/{token}`; per-site deploy-key generation; **new site-detail page**. In-place deploy for v1, but lay out paths to allow a later atomic flip. *(XL, high: secrets, build isolation as the unprivileged user, webhook HMAC, new UI.)*
8. **`deploy-atomic-rollback`** — Capistrano-style `releases/` + `shared/` + `current` symlink; retain N releases; atomic flip; rollback; vhost root → `current/public`. Converts the MVP to zero-downtime.

### Phase 4 — Ops payoff (exploit the mature foundation)
9. **`backups`** — scheduled + on-demand DB dump (per-engine) + file tar to local + S3-compatible storage; retention; restore-to-new-target. Uses scheduler + queue + drivers.
10. **`cron-tasks`** — per-user crontab CRUD via sudo script + UI.
11. **`monitoring-alerts`** — surface `failed_jobs`; email/webhook alerts on deploy failure, SSL expiry, fail2ban bans, disk/CPU thresholds (Reverb stats already gathered). *(Can interleave earlier — SSL-expiry/disk alerts don't need deploy.)*

### Phase 5 — Lower-fit engines (last; must not distort the abstraction)
12. **`cache-redis-memcached`** — separate Cache Services UI (enable/disable, status, host:port, Redis AUTH+flush, Memcached port+memory). Not modeled as relational databases.
13. **`db-mongodb`** — `MongoDriver` with role-based user flow, `db.stats()` sizing, mongo connection string, install + mongosh sudo script.

## Cross-cutting principles

- **Extend existing patterns, not new architecture:** sudo-script + Service + (new) queued Job + Reverb progress + audit row. Add new privileged binaries via a `sudoers.d` drop-in, not edits to the monolithic line.
- **Security:** allowlist before enabling bans; HMAC-verify webhooks; run builds as the unprivileged site user; store secrets via the encrypted-cast pattern (revisit if a real secrets store is needed).
- **Tests:** the DB and firewall paths have zero tests today; add tests as part of the abstraction and each new driver/feature — exercised in the `local-dev` container.
- **Prod scripts stay prod-correct;** the `local-dev` patched copies remain local-only.

## Deferred / out of scope (revisit later)

DNS zone management, email (Postfix/Dovecot), one-click app installers, staging environments, teams/granular roles, WAF/ModSecurity. Acknowledged as real cPanel pillars but lower ROI / heavier; not in this roadmap's near-term.

## Open items to resolve per sub-project (not blocking the roadmap)

- Git-deploy: confirm in-place v1 is acceptable (failed build can break the live site) vs atomic from day 1.
- Non-admin users configuring deploy / seeing progress on their own sites → needs user-scoped Reverb channels (today admin-only).
- Secrets storage for deploy keys + S3 creds: extend the encrypted-cast or a dedicated store.
- Redis/Memcached granularity: server-level toggle (assumed) vs per-user instances.

## Next step

Brainstorm **Sub-project #1 (`platform-async-progress`)** into its own design spec, then `writing-plans`, then subagent-driven build. Branching: `local-dev-env` (test env) should merge to `main` first so features can be tested against it; feature sub-projects branch off `main`.
