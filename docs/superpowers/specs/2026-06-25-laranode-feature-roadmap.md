# Laranode feature roadmap

- **Date:** 2026-06-25
- **Status:** Agreed + in progress (umbrella roadmap; each sub-project gets its own spec → plan → build cycle)
- **Source:** research workflow (4 codebase mappers + 3 competitor researchers + synthesis), then user prioritization.
- **Progress (2026-06-26):** #1 `platform-async-progress` **shipped** (merged to `main`). #2 expanded to `db-relational-engines` (the seam **plus** MySQL/MariaDB/Postgres in one sub-project; SQLite + Mongo split out to later sub-projects) — design in progress (seam approved). Phase 4 split per dev-branch reconciliation: `monitoring-alerts` (#11) kept, `notifications` (#12) + `user-analytics` (#13) added as separate items (cache→14, mongo→15). **Phase 6 (#16–21) added:** the six formerly-deferred cPanel-parity pillars, promoted at user request. Full per-feature stubs: `2026-06-26-deferred-features-stubs.md`.

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
12. **`notifications`** — a real notification system: in-app **notification center** via Laravel database notifications (bell + unread count in the layout) plus opt-in delivery channels (email, webhook/Slack). Event sources: operation finished/failed (from #1), deploy success/failure, SSL issued/expiring, fail2ban bans, resource thresholds, backup results. Per-user, with notification preferences. Builds on the #1 operations + events + scheduler foundation. *(Plumbing can land early; alert sources wire in as their features ship. Overlaps `monitoring-alerts` (#11) — keep the alert-trigger logic in #11, the delivery + in-app center in #12.)*
13. **`user-analytics`** — user-facing analytics about *their* machine/resources. Today's live CPU/mem/network + sar history are **admin-only**; this surfaces historical, digestible analytics to the user: CPU/memory/disk/bandwidth over time, per-site traffic + disk usage, DB/account consumption vs their quotas (`domain_limit`/`database_limit`), SSL/cert status overview. Extends the existing `SarHistory`/`*HistoryService` + Reverb stats stack with user-scoped views + scheduled rollups (uses the #1 scheduler). *(Charts already in the stack: chart.js/react-chartjs-2.)*

### Phase 5 — Lower-fit engines (last; must not distort the abstraction)
14. **`cache-redis-memcached`** — separate Cache Services UI (enable/disable, status, host:port, Redis AUTH+flush, Memcached port+memory). Not modeled as relational databases.
15. **`db-mongodb`** — `MongoDriver` with role-based user flow, `db.stats()` sizing, mongo connection string, install + mongosh sudo script.

### Phase 6 — cPanel-parity pillars (promoted 2026-06-26 from deferred)

Six heavyweight pillars, all **XL**, all building on the shipped async foundation. Stubs only — each needs its own spec → plan → build. Ordered by dependency + risk. Full detail (scope, scripts, packages, risks, open questions) in `2026-06-26-deferred-features-stubs.md`.

16. **`dns-zones`** — BIND9 authoritative DNS: zones + records (A/AAAA/CNAME/MX/TXT/SRV/CAA), `rndc` reload, optional auto-zone on website add, optional DNSSEC. *(XL. Dep: foundation only — independent of DB work; feeds mail later. Footgun: zone is authoritative only with registrar NS delegation; must open port 53 without silently mutating the firewall.)*
17. **`teams-rbac`** — teams + per-team roles (owner/developer/viewer) + per-resource collaborator grants on websites/databases; `scopeMine()`/policy overhaul. *(XL. Dep: after DB-driver abstraction freezes the `Database` morph key. Footgun: `{username}_ln` stays 1:1 — a developer-role member still runs PHP-FPM as the owner; audit all scopeMine callsites for impersonation. No new sudo scripts.)*
18. **`app-installers`** — one-click WordPress (then Laravel/phpMyAdmin) into a docroot: download + auto DB + config + chown, live via OperationJob. *(XL. Dep: Websites + Databases. Footgun: wp-config plaintext creds; phpMyAdmin attack surface; idempotent rollback of half-installs.)*
19. **`waf-modsecurity`** — ModSecurity v3 + OWASP CRS, per-vhost enable + paranoia level + exclusions + audit-log viewer. *(XL. Dep: stable vhost template + SSL toggle. Footgun: CRS blocking can lock out admin → default DetectionOnly; SSL+WAF both regenerate the vhost file → mutex-guard the render.)*
20. **`staging-environments`** — per-site staging clone (files+DB) + promote/sync, `staging.{url}` vhost. *(XL. Dep: Websites + Databases + ideally `backups` first. Footgun: promote is destructive/irreversible → confirmation token + pre-promote snapshot; serialized-PHP search-replace is fragile.)*
21. **`email-server`** — Postfix + Dovecot, mailboxes/aliases, DKIM, TLS via certbot, Rspamd, optional Roundcube. *(XL, heaviest/riskiest → last. Dep: SSL + ideally DNS (#16). Footgun: open-relay surface, IP reputation/PTR, many VPS block outbound :25 — consider inbound-only v1 with an external relay for outbound.)*

## Cross-cutting principles

- **Extend existing patterns, not new architecture:** sudo-script + Service + (new) queued Job + Reverb progress + audit row. Add new privileged binaries via a `sudoers.d` drop-in, not edits to the monolithic line.
- **Security:** allowlist before enabling bans; HMAC-verify webhooks; run builds as the unprivileged site user; store secrets via the encrypted-cast pattern (revisit if a real secrets store is needed).
- **Tests:** the DB and firewall paths have zero tests today; add tests as part of the abstraction and each new driver/feature — exercised in the `local-dev` container.
- **Prod scripts stay prod-correct;** the `local-dev` patched copies remain local-only.

## Deferred / out of scope (revisit later)

**Promoted 2026-06-26 → now Phase 6 (#14–19):** DNS zones, email (Postfix/Dovecot), one-click app installers, staging environments, teams/granular roles, WAF/ModSecurity.

**Still out of scope:** multi-server / fleet management (single-host is a design invariant), container orchestration, reseller/billing tiers. Revisit only if the single-host premise changes.

## Open items to resolve per sub-project (not blocking the roadmap)

- Git-deploy: confirm in-place v1 is acceptable (failed build can break the live site) vs atomic from day 1.
- Non-admin users configuring deploy / seeing progress on their own sites → needs user-scoped Reverb channels (today admin-only).
- Secrets storage for deploy keys + S3 creds: extend the encrypted-cast or a dedicated store.
- Redis/Memcached granularity: server-level toggle (assumed) vs per-user instances.

## Next step

#1 shipped. Active sub-project: **`db-relational-engines`** (#2 expanded) — seam approved (driver interface + `EngineManager` + capabilities descriptor + per-engine idiomatic execution: MySQL/MariaDB via privileged Laravel connection, Postgres via `sudo laranode-postgres.sh`). Remaining: finish its design spec → `writing-plans` → build. Then the rest of Phase 1 and onward.

**Branching strategy:** each feature sub-project branches off `main` (e.g. `feature/db-relational-engines`); integrate completed branches into a long-lived `development` branch for combined testing in the local-dev container, then merge `development` → `main` once green. (`development` to be created when the first post-foundation feature branch is ready.)

**Discipline gate (unchanged):** stubs ≠ specs ≠ plans. No feature is built before its own spec + implementation plan exist and are reviewed. Phase 6 entries are stubs.
