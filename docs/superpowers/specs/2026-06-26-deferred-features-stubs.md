# Deferred features — promoted to roadmap Phase 6 (stubs)

- **Date:** 2026-06-26
- **Status:** Stubs only (NOT designs). Each item still needs its own brainstorm → design spec → implementation plan → build.
- **Source:** `roadmap-deferred-stubs` workflow — 6 parallel agents (one per feature), each mapping the feature onto Laranode's established architecture (sudo-script + Service + OperationJob + Reverb progress + audit row; single Ubuntu host; computed `{username}_ln` identity).
- **Why this doc:** the roadmap (`2026-06-25-laranode-feature-roadmap.md`) carries condensed Phase 6 entries; this file holds the full per-feature detail so nothing is lost before per-feature specs are written.

All six are **XL** and all build on the shipped `platform-async-progress` foundation (#1).

---

## #16 · `dns-zones` — DNS Zone Management

**Summary:** Authoritative DNS for domains hosted on the single host, using BIND9 (`named`) with zone files under `/etc/bind/zones/`. Full CRUD for zones + records (A/AAAA/CNAME/MX/TXT/SRV/CAA), safe reload via `rndc`, optional auto-zone creation on website add, optional DNSSEC signing — wired through the sudo-script + Service + OperationJob + Reverb audit pattern.

**Sizing:** XL · **Suggested phase:** Phase 6, first (no dependency on the DB-driver work; feeds mail's MX/SPF later).

**Scope**
- Migrations: `dns_zones` (user_id FK, domain, ttl, status; owner-scoped, scopeMine()), `dns_records` (zone_id FK, type, name, value, ttl, priority nullable)
- Models: `DnsZone` (belongsTo User, hasMany DnsRecord, computed `zoneFilePath`), `DnsRecord`
- FormRequests: Store/Update DnsZone, Store/Update DnsRecord
- Services: `Dns/CreateDnsZoneService` (write zone file + named include + rndc reload; sibling exception), `Dns/DeleteDnsZoneService`, `Dns/SyncDnsRecordsService` (regenerate zone file from records + increment serial + reload)
- Jobs: `CreateDnsZoneOperationJob`, `DeleteDnsZoneOperationJob`, `SyncDnsRecordsOperationJob` (all extend OperationJob)
- Template: `dns-zone.template` (SOA + NS stub; PHP fills records)
- Controllers: `Dns/DnsZoneController` (index/store/destroy), `Dns/DnsRecordController` (index/store/update/destroy, scoped to owned zone)
- Routes: admin `/admin/dns` (all-zones audit), user `/dns`
- Pages: `Pages/Dns/Index.jsx`, `Show.jsx` (zone detail + records table + live OperationProgress)
- Hook into `CreateWebsiteService`: optionally dispatch `CreateDnsZoneOperationJob` for new domain
- Sudoers drop-in `/etc/sudoers.d/laranode-dns`; Pest tests `DnsZoneTest`, `DnsRecordTest` (mock Process)

**Privileged scripts**
- `laranode-dns-zone-create.sh` — scaffold `/etc/bind/zones/<domain>.db` from template, append include to named config, rndc reload
- `laranode-dns-zone-delete.sh` — remove zone file, strip include, rndc reload
- `laranode-dns-zone-reload.sh` — `named-checkzone` validation then `rndc reload <domain>` (after every record sync)
- `laranode-dns-dnssec-sign.sh` — optional; `dnssec-keygen` + `dnssec-signzone` + `rndc loadkeys` (gated by per-zone dnssec boolean)

**Packages:** bind9, bind9utils (named-checkzone, rndc), dnsutils (dig, for test smoke), bind9-doc (dev)

**Integrations:** Websites (auto-zone on add), foundation (OperationJob + audit + OperationProgress), Auth (scopeMine mirrors Website), Dashboard (named status via systemctl, read-only)

**Dependencies:** `platform-async-progress` (#1, shipped)

**Risks / footguns**
- `rndc reload` failure → inconsistent zone; reload script must `named-checkzone` first and exit non-zero so the job fails before traffic is hit
- Mutating `named.conf.local` via sed/grep is fragile → use a dedicated `named.conf.laranode.local` include, never clobber distro config
- BIND runs as `bind` user; zone files must be `bind`-owned, www-data must not own them
- Auto-zone appears authoritative but needs **registrar NS delegation** — UI must warn that glue records are out of panel control
- DNSSEC private keys in `/etc/bind/keys/` sensitive → 600 bind:bind, never store key content in DB
- Serial collision on rapid edits → `YYYYMMDDnn`, read current serial before write
- Deleting a zone with an active website → gate or require `--force`
- Port 53 (UDP+TCP) must be opened — warn if UFW active, but **do not** silently mutate firewall (that's the Firewall subsystem)

**Open questions:** BIND9 vs PowerDNS (API would remove templating but adds a daemon) · include-file vs sed mutation strategy · auto-zone opt-in vs default · SOA/NS defaults (settings page or env) · DNSSEC v1 scope · reverse/PTR zones (out of v1, don't preclude) · record validation in FormRequest vs rely on named-checkzone

---

## #17 · `teams-rbac` — Teams & Granular RBAC

**Summary:** Extends the binary admin|user model with teams (orgs), per-team member roles (owner/developer/viewer), and per-resource collaborator grants on websites + databases, with least-privilege enforcement.

**Sizing:** XL · **Suggested phase:** Phase 6, after the DB-driver abstraction stabilizes the `Database` morph key (avoids a 2nd migration). Touches every resource model + policy. ~3–4 sprints.

**Scope**
- Migrations: `teams` (name, owner_user_id), `team_user` pivot (role enum owner|developer|viewer), `resource_collaborators` (team_id nullable, user_id nullable, resource_type, resource_id, permission enum view|deploy|manage)
- Models: `Team`, `TeamMember` pivot (role cast), `ResourceCollaborator` (morphTo)
- Trait `HasCollaborators` on Website + Database; extend `scopeMine()` to include collaborator/team grants
- Update `WebsitePolicy` + `DatabasePolicy` to check grants beyond ownership; `TeamRoleMiddleware` for owner-only routes; `TeamPolicy`
- Services: `TeamService` (create/invite/remove/change-role/delete), `CollaboratorService` (grant/revoke/list)
- Pages: `Pages/Teams/` (index/create/show + invite), `Websites/Collaborators.jsx`, `Databases/Collaborators.jsx`
- `HandleInertiaRequests::share()` adds `auth.teams` + `auth.teamRoles`
- Admin `/admin/teams` audit page; ensure `laranode:create-admin` still bypasses team scoping
- Pest: team CRUD, grant/revoke, scopeMine with collaborator rows, policy deny paths

**Privileged scripts:** none — pure DB/application layer. The mandatory `{username}_ln` Linux account stays strictly 1:1 per User and is **not** shared across teams.

**Packages:** `spatie/laravel-permission` (optional — evaluate vs hand-rolled; see open questions)

**Integrations:** User (HasTeams trait), Website/Database (HasCollaborators + scopeMine), policies, AdminMiddleware (unchanged, admin bypasses), HandleInertiaRequests (share teams), lab404 impersonate (impersonatee's teams must resolve), Operations (`user_id` stays the acting user — no team_id needed)

**Dependencies:** `platform-async-progress` (#1, no blocker) · DB-driver abstraction (morph key `App\Models\Database` must stay stable)

**Risks / footguns**
- `scopeMine()` fan-out → N+1 / missing index; add composite index `(resource_type, resource_id, user_id)` and benchmark
- System-account coupling: a developer-role member who can deploy still runs PHP-FPM as the **owner's** `_ln` account — document this boundary; don't change the Linux identity model
- Impersonation: `scopeMine()` must resolve as the impersonatee; audit all callsites using `auth()->id()` directly (break under impersonation) vs `auth()->user()`
- spatie (4 extra tables) vs hand-rolled — decide before schema; rollback is painful
- Role escalation: a developer must not grant themselves `manage`; `CollaboratorService` verifies actor is owner/admin
- Blast radius: scopeMine change breaks existing tests that seed resources as non-admin without ownership — audit before merge

**Open questions:** spatie vs hand-rolled · `operations.team_id` for team-filtered audit? · email invite (needs mail) vs admin-assigns · Linux identity: future shared `_ln` group vs permanent 1:1 · ownership transfer on member/account removal · viewer + file-manager read-only ACLs (new script?)

---

## #18 · `app-installers` — One-Click App Installers

**Summary:** Install common web apps (WordPress first; then Laravel skeleton / phpMyAdmin) into an existing website docroot: download release, provision a DB via `CreateDatabaseService`, generate config (wp-config.php etc.), chown to the site's `{username}_ln` user, optionally update document_root — streamed live via OperationJob so every install hits the audit log.

**Sizing:** XL · **Suggested phase:** Phase 6, after Websites + Databases stable. Ship WordPress first; gate later recipes behind a flag to avoid premature recipe-abstraction.

**Scope**
- Migration `app_installations` (website_id FK, app slug, app version, db_id FK nullable, status enum installed|failed|uninstalled, timestamps)
- Model `AppInstallation` (belongsTo Website + Database; scopeMine via website.user)
- Interface `AppRecipe` (slug/latestVersion/downloadUrl/configFiles(context)/requiredDocRoot); recipes `WordPressRecipe`, `PhpMyAdminRecipe`, `LaravelRecipe` in `app/Actions/AppInstaller/Recipes/`
- Services: `AppInstaller/InstallAppService` (validate not-already-installed, delegate to CreateDatabaseService, dispatch job; sibling exception), `AppInstaller/UninstallAppService` (DeleteDatabaseService + remove files + mark row)
- Job `InstallAppOperationJob` (download to /tmp, checksum, extract to docroot, write config, call chown script, emit throughout)
- Script `laranode-app-install-chown.sh <docroot> <system_user>`; sudoers drop-in `laranode-app-installer`
- Controller `AppInstallerController` (index/store/destroy); FormRequest `InstallAppRequest` (website owned, slug in allowlist, db creds)
- Pages: `Pages/AppInstaller/Index.jsx` (per-website installs + app picker + OperationProgress), `Show.jsx` (detail + uninstall)
- Test `InstallWordPressTest` (fake Process + HTTP + queue; assert DB row + operation row + sudo call)

**Privileged scripts:** `laranode-app-install-chown.sh` — recursive chown to `{username}_ln:www-data` + 755/644 (only privileged step)

**Packages:** curl/wget (present), unzip (WordPress zip), tar (present)

**Integrations:** Websites (`fullDocumentRoot`, optional document_root update), Databases (Create/Delete services, encrypted db_password), foundation (OperationJob + OperationProgress + audit), scopeMine via website

**Dependencies:** `platform-async-progress` · Websites · Databases (Create/Delete services + encrypted cast)

**Risks / footguns**
- Download is network I/O in a queued job → enforce timeout, stream to temp + checksum before extract
- wp-config.php DB password on disk (unavoidable) → chown 640, rely on FPM open_basedir
- Idempotency: failed install leaves half-extracted docroot + created DB → uninstall cleans both; refuse re-install unless prior row is `failed`
- Version pinning: store installed version at install time (needed for upgrades)
- phpMyAdmin in public docroot = high-value target → admin-only + UI warning, consider localhost-restricted vhost
- Recipe allowlist enforced server-side (static map; never trust client slug)
- Block concurrent installs to same docroot (check pending op on website_id)

**Open questions:** recipe interface up front vs WordPress-only first · upgrade flow (in-place vs reinstall) · driver-agnostic vs MySQL-locked for v1 · auto document_root mutation vs manual · checksum: archive hash vs full file-list verify · phpMyAdmin Apache Location gating

---

## #19 · `waf-modsecurity` — WAF / ModSecurity v3 + OWASP CRS

**Summary:** Install libmodsecurity3 + Apache mod-security2 connector + OWASP CRS globally, then per-vhost enable/disable, paranoia-level selection, rule exclusions, and an audit-log viewer — via the existing sudo-script + Service + OperationJob + Reverb + audit pattern.

**Sizing:** XL · **Suggested phase:** Phase 6, after a stable vhost-template pipeline (WAF forks the template) and after OperationJob is battle-tested on SSL/PHP jobs.

**Scope**
- Migration: add `waf_enabled` (bool), `waf_paranoia_level` (tinyint 1–4), `waf_rule_exclusions` (json) to websites; Website cast + `isModsecActive()`
- Template `apache-vhost-modsec.template` (fork of vhost template: SecRuleEngine block + per-site exclusion Include + SecAuditLog path)
- Service `Websites/WafService` (enable/disable/tuning via sudo scripts; sibling WafException)
- Jobs `WafToggleOperationJob`, `WafInstallOperationJob` (admin-only global install)
- Controller `Websites/WafController` (toggle/setParanoia/add+removeExclusion/auditLog) + FormRequest per action
- Action `Websites/ReadWafAuditLogAction` — tail/parse `/home/{user}_ln/logs/modsec-audit-{domain}.log` → paginated blocked-request structs (no sudo)
- Sudoers drop-in `laranode-waf`; Pages `Pages/Websites/Waf/` (WafPanel, WafAuditLog); admin `/admin/waf` (global install + DetectionOnly/On mode); routes `websites.waf.*` + `admin.waf.*`
- Pest: WafToggle, WafExclusion, WafAuditLog (mock Process; assert DB + op row + broadcast)

**Privileged scripts**
- `laranode-waf-install.sh` — one-time: apt install libmodsecurity3 + libapache2-mod-security2, clone OWASP CRS, write global modsecurity.conf (DetectionOnly default), a2enmod security2
- `laranode-waf-enable.sh` — write per-site exclusion conf, regenerate vhost from modsec template, reload apache
- `laranode-waf-disable.sh` — regenerate vhost from plain template, reload
- `laranode-waf-set-paranoia.sh` — update paranoia + SecRuleRemoveById in per-site conf, reload

**Packages:** libmodsecurity3, libapache2-mod-security2, git (present), owasp-crs (cloned to `/etc/apache2/modsecurity-crs/`)

**Integrations:** Websites (vhost template fork; WafService alongside Create/UpdatePHP), foundation (jobs + audit + OperationProgress), **SSL** (both regen the vhost — ordering/race matters), vhost template system (new modsec variant; add-vhost `--modsec` flag or post-create step)

**Dependencies:** `platform-async-progress` · stable Websites vhost template · SSL toggle (direct template conflict — WAF must know SSL state when regenerating)

**Risks / footguns**
- **False-positive lockout:** CRS blocking can block the admin panel → default **DetectionOnly**, explicit admin opt-in to enforce
- **Vhost template race:** SSL + WAF both regenerate `{domain}.conf` from different branches → concurrent toggle can corrupt the file / down the site (needs a per-site mutex)
- Apache reload failures must surface: run `apachectl configtest` and emit errors via the job
- Audit log unbounded → logrotate stanza in install script
- Per-site exclusion conf is root-owned → validate domain arg against sites-available (path traversal)
- CRS pinned at install, never auto-updated → stale rules without awareness
- Paranoia 3–4 adds latency → document, default level 1
- Installer idempotency (check mod enabled before apt/a2enmod)

**Open questions:** add-vhost `--modsec` flag vs always-second-step · single conditional template vs two parallel templates (fragility under SSL changes) · audit logs under homedir (no sudo) vs `/var/log` (sudo) · DetectionOnly-forever as a distinct UI mode? · CRS update strategy · exclusion UX (free-form vs curated checklist) · paranoia global vs per-vhost

---

## #20 · `staging-environments` — Staging Environments

**Summary:** Per-site staging copy: clone files + DB into a `staging.{url}` vhost owned by the same `{username}_ln` account, with promote-to-prod and sync-from-prod. Each op (clone/promote/sync) is a queued OperationJob with live progress + audit row.

**Sizing:** XL · **Suggested phase:** Phase 6, after Databases driver abstraction and ideally **after backups** (so promote can snapshot prod before overwrite). Lower near-term ROI; staging without a backup net is risky.

**Scope**
- Migration: self-referential `staging_website_id` FK on websites (null = prod, set = staging copy)
- Model: `Website::staging()` / `productionSite()` relations; `isStaging()` / `hasStaging()`; `stagingUrl()` (`staging.{url}`)
- Services: `CreateStagingService` (clone dir + clone DB + FPM pool + vhost + save record), `PromoteStagingService` (rsync staging→prod + DB overwrite + optional search-replace), `SyncFromProdService` (prod→staging files + DB + search-replace), `DeleteStagingService`
- Jobs: `CloneSiteOperationJob`, `PromoteStagingOperationJob` (confirmation guard), `SyncFromProdOperationJob`
- FormRequests: `CreateStagingRequest` (no existing staging), `PromoteStagingRequest` (explicit confirmation token)
- Controller `StagingController` (store/destroy/promote/sync, thin → dispatch job + return op id)
- Page `Pages/Websites/Staging.jsx` (status + clone/promote/sync → OperationProgress modal); `StagingBadge.jsx`; routes `/websites/{website}/staging[...]`
- Pest: CreateStaging, PromoteStaging, SyncFromProd (mock Process; assert records + op row)

**Privileged scripts**
- `laranode-clone-site-files.sh` — `rsync -a --delete` between two paths under `/home/{username}_ln`, run as `{username}_ln`
- `laranode-promote-staging-files.sh` — rsync staging→prod with homedir path allowlist guard
- `laranode-staging-db-clone.sh` — `mysqldump src | mysql dst` (prod→staging)
- `laranode-staging-db-promote.sh` — mysqldump staging | mysql prod (destructive)
- `laranode-search-replace-db.sh` — serialized-safe domain swap (PHP/python helper for WordPress data)

**Packages:** rsync, mysql-client (present), php-cli (present; serialized-string helper)

**Integrations:** Websites (staging IS a Website row — reuses FPM pool + vhost + delete pipeline), Databases (mysqldump/mysql directly to dodge PHP memory ceiling), foundation (3 jobs + audit + OperationProgress), SSL (staging vhost no-SSL by default), Filemanager (same homedir sandbox)

**Dependencies:** `platform-async-progress` · stable Websites (vhost+FPM scripts) · stable MySQL (Database model + Create pattern) · sudoers.d drop-in pattern

**Risks / footguns**
- **Promote is destructive + irreversible** (prod DB+files overwritten) → explicit confirmation token + job pre-flight; no undo
- Serialized-PHP search-replace is fragile (byte-length mismatch breaks unserialize) → serialized-aware replacer, not SQL REPLACE()
- Large sites: rsync + mysqldump unbounded; only step-level progress; dump holds brief lock
- `staging.{url}` needs a DNS A record — panel can't provision it; user does it manually first
- ACME HTTP-01 on staging fails if staging is behind HTTP-auth / private
- File clone doesn't redact `.env` → staging `.env` carries prod creds until edited; warn in UI
- Promote path guard mandatory: both src+dst must resolve inside `/home/{username}_ln` before `rsync --delete`
- Concurrent promote+sync → per-website cache-lock mutex

**Open questions:** serialized replacer (ship PHP helper vs require WP-CLI) · `staging.{url}` enforced vs user-specified subdomain · staging in main list (badge) vs separate tab · block staging for non-MySQL until driver abstraction vs per-driver clone scripts now · clone whole websiteRoot vs only docroot · promote auto-backup (couples to backups) · optional htpasswd on staging vhost · serialized helper location

---

## #21 · `email-server` — Email (Postfix + Dovecot)

**Summary:** Full mail stack: Postfix SMTP + Dovecot IMAP/POP3, per-domain virtual mailboxes + aliases under each `{username}_ln` homedir, DKIM via OpenDKIM, TLS via existing certbot certs, Rspamd spam filtering, DNS record guidance (SPF/DMARC/PTR), optional Roundcube webmail. Every destructive mutation is an OperationJob with live progress + audit.

**Sizing:** XL · **Suggested phase:** Phase 6, **last** — heaviest and riskiest (IP reputation, open-relay surface, ongoing deliverability). Gate behind a settings feature flag; document the PTR + port-25 prerequisites. Wants DNS (#14) + SSL in place.

**Scope**
- Migrations: `mail_domains` (user_id FK, domain, dkim_enabled), `mailboxes` (mail_domain_id FK, local_part, quota_mb, status), `mail_aliases` (mail_domain_id FK, source_local, destination)
- Models: `MailDomain` (hasMany Mailbox/Alias, scopeMine), `Mailbox` (encrypted password cast), `MailAlias`
- Services: `Mail/ProvisionMailDomainService`, `CreateMailboxService` (+exception), `DeleteMailboxService`, `UpdateMailboxService` (password/quota), `CreateMailAliasService`, `DeleteMailAliasService`, `ToggleDkimService`
- Jobs: `ProvisionMailDomainJob`, `DeprovisionMailDomainJob`, `CreateMailboxJob` (extend OperationJob)
- Controllers: `Mail/MailDomainController`, `MailboxController`, `MailAliasController`; FormRequests for each
- Routes `/mail/domains` + nested mailboxes/aliases; Pages `Pages/Mail/{Domains,Mailboxes,Aliases}/Index.jsx` with OperationProgress
- Templates: postfix-main.cf, postfix-virtual-mailbox.cf, dovecot-passwd, opendkim-keytable
- Sudoers drop-in `laranode-mail`; Pest tests + system test (LARANODE_SYSTEM_TESTS=1 full provision/deprovision in container)

**Privileged scripts**
- `laranode-mail-provision-domain.sh` / `laranode-mail-deprovision-domain.sh` (virtual-mailbox config + Maildir purge under homedir)
- `laranode-mail-add-mailbox.sh` / `laranode-mail-remove-mailbox.sh` / `laranode-mail-set-password.sh` (Dovecot passwd file + Maildir; SHA-512-CRYPT min)
- `laranode-mail-dkim-keygen.sh` / `dkim-enable.sh` / `dkim-disable.sh` (OpenDKIM KeyTable/SigningTable)
- `laranode-mail-tls-link.sh` (symlink certbot cert/key into postfix/dovecot)
- `laranode-mail-roundcube-install.sh` (optional webmail)

**Packages:** postfix (+postfix-mysql if MySQL backend), dovecot-core/imapd/pop3d/lmtpd, opendkim + opendkim-tools, rspamd, roundcube-core/plugins (optional), mailutils (testing)

**Integrations:** SSL/certbot (tls-link reuses certs; renewal hook must reload postfix+dovecot), Websites (domain must exist first), Accounts (`{username}_ln` pre-exists; Maildir at `/home/{username}_ln/mail/`), foundation (provision/deprovision jobs + audit + OperationProgress)

**Dependencies:** `platform-async-progress` · SSL (certs) · Websites (domain ownership) · Accounts (`{username}_ln`)

**Risks / footguns**
- **Open relay:** postfix `smtpd_relay_restrictions` must be locked in the template; misconfig = spam relay
- **IP reputation / PTR:** provider must allow outbound :25 + set PTR — many VPS block :25 by default → outbound impossible regardless of config
- Deliverability: SPF/DKIM/DMARC live in DNS — panel surfaces values, user (or #14) sets them
- Cert renewal must reload postfix+dovecot or mail TLS silently uses expired certs
- Maildir quota: Dovecot quota plugin vs OS quota mismatch → silent bypass
- Dovecot passwd file: single writer script, strong hashing
- Rspamd ships an unauth'd HTTP dashboard on :11334 → bind to 127.0.0.1 or disable
- Roundcube adds a PHP app + DB + session surface → isolate under its own vhost, update separately
- Domain removal deletes Maildir → confirmation + ideally backup snapshot first
- Multi-tenant relay: misconfigured `virtual_mailbox_maps` lets one tenant relay as another → domain-scoped allowlist validated against MailDomain

**Open questions:** flat-file vs MySQL virtual-mailbox backend · Dovecot quota strategy · submission ports (587 only vs +465; :25 inbound-only?) · Rspamd vs SpamAssassin · Roundcube scope (per-panel vs per-domain) · DKIM rotation · **inbound-only v1 with outbound via external relay (SES/Mailgun) as the safe default?** · backup MX · per-user mail admin vs admin-only

---

## Cross-feature observations

- **All six are XL and all consume the foundation** — none are quick wins. Sequencing matters more than parallelism.
- **Recurring footgun: destructive ops** (promote, domain/zone/Maildir removal, WAF enforce) → every one needs explicit confirmation tokens + (ideally) a backup snapshot step. This argues for shipping **`backups` (#9)** before staging/mail.
- **Template-regeneration races** (WAF + SSL on the same vhost file) → a shared, mutex-guarded vhost-render path is worth extracting before WAF.
- **DNS is a soft prerequisite for mail** (MX/SPF/DKIM/DMARC) — #16 before #21 improves the mail UX even though mail can surface values without it.
- **`teams-rbac` wants the DB morph key frozen** → after the DB-driver abstraction.
