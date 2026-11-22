#!/usr/bin/env bash
# Mutation smoke: re-introduce each reviewed bug into a COPY of the installer and
# require the host-detection unit tests to go red. A guard whose test cannot fail is
# not a guard. One run of the unit tests per mutation (minutes on a laptop, CI shards it in 2);
# never touches the real installer.
#
#   bash local-dev/install-test/mutation-smoke.sh
#   SHARD=2/2 bash local-dev/install-test/mutation-smoke.sh   # every 2nd mutation from #2 (CI runs 2 shards)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../../laranode-scripts/bin/laranode-installer.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SHARD="${SHARD:-}"   # k/n (CI matrix); empty = all
SHARD_K=1; SHARD_N=1
if [ -n "$SHARD" ]; then
  [[ $SHARD =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] && [ "${BASH_REMATCH[1]}" -le "${BASH_REMATCH[2]}" ] \
    || { echo "SHARD must be k/n with 1 <= k <= n, got '$SHARD'" >&2; exit 2; }
  SHARD_K=${BASH_REMATCH[1]}; SHARD_N=${BASH_REMATCH[2]}
fi

# name | sed expression applied to a copy of the installer
MUTATIONS=(
  'busy-port check warns instead of refusing|s|die "Port ${HTTP_PORT} is already in use by|warn "Port ${HTTP_PORT} is already in use by|'
  'stopped pre-existing apache2 treated as ours|s#_unit_is_prior apache2.service; then APACHE_OWNED=0#_unit_is_prior apache2.service \&\& svc_active apache2; then APACHE_OWNED=0#'
  'pre-existing php8.4-fpm is enabled+started|s#if \[ "\${PHPFPM_OWNED:-1}" = 1 \]; then#if true; then#'
  'failed configtest leaves the edits behind (rollback never armed)|s#^    _WB_ARMED=1$#    _WB_ARMED=0#'
  'pre-existing unit restarted instead of reloaded|s|systemctl reload "\$unit"|systemctl restart "$unit"|'
  'apache2 not protected from apt upgrades|s#(apache2|libapache2-|#(#'
  'every Apache module enabled on a pre-existing Apache|s|echo "proxy proxy_fcgi rewrite"|echo "proxy_fcgi rewrite setenvif headers proxy proxy_http"|'
  'stopped apache2 started without the LARANODE_START_STOPPED opt-in|s|\[ "\${LARANODE_START_STOPPED:-0}" = 1 \] \&\& return 0|true \&\& return 0|'
  'Listen-port conflicts of a stopped apache2 ignored|s#if port_in_use "\$p"; then echo "\${p} #if false; then echo "${p} #'
  'already-enabled Apache modules enabled again (a2query skip dropped)|s#a2query -m "\$m" >/dev/null 2>\&1 \&\& continue#true#'
  'manifest forgets modules persisted by a run that died|s#\[ ! -f "\$st" \] || mods_state=\$(cat "\$st")#mods_state=""#'
  'stale policy-rc.d guard never cleaned at start|s#^  _policy_guard_is_ours || return 0#  return 0#'
  'stale-guard cleanup ignores a still-running installer|s#_pid_alive "\$pid" "\$start"; then return 0#false; then return 0#'
  'guard removes a policy-rc.d that is not ours|s#if _policy_guard_is_ours; then rm -f#if true; then rm -f#'
  'Listen/vhost rollback never runs|s#\[ "\$_WB_ARMED" = 1 \] || return 0#return 0#'
  'modules enabled by a failed run not disabled again|s#if a2dismod "\$m" >/dev/null 2>\&1; then :; else#if true; then :; else#'
  'live pre-existing php8.4-fpm restarted by the extension postinst (no guard)|s#if \[ "\${PHPFPM_OWNED:-1}" = 0 \]; then _policy_guard_on; fi#:#'
  'ss-less host proceeds without any listener probe|s#_probe_available || die "Cannot#true || die "Cannot#'
  # round 4: the reviewer's two reproduced bugs
  'rollback stops a pre-existing Apache that was running (reload never reached)|s#^  if \[ -f "\$j/was_active" \]; then#  if false; then#'
  'dual-stack listener reads FREE (grep -q early exit under pipefail)|s#\[ -n "\$(_proc_listen_inodes "\$1")" \]#_proc_listen_inodes "$1" | grep -q .#'
  # round 4: signals and hooks
  'SIGINT no longer turned into an exit (hooks skipped)|s#^  trap .exit 130. INT#  :#'
  'SIGTERM no longer turned into an exit (hooks skipped)|s#^  trap .exit 143. TERM#  :#'
  'SIGHUP no longer turned into an exit (hooks skipped)|s#^  trap .exit 129. HUP#  :#'
  'a second signal can abort the cleanups|s#^  trap .. INT TERM HUP#  :#'
  'the same exit hook registered twice runs twice|s#\[ "\$seen" = 1 \] || _EXIT_HOOKS+=#_EXIT_HOOKS+=#'
  # round 4: policy-rc.d guard
  'guard created with plain redirection (writes through a planted link)|s#( set -C; _policy_guard_script#( _policy_guard_script#'
  'guard never expires with its installer (always answers 101)|s#kill -0 %s 2>/dev/null \&\& exit 101\\nexit 0\\n#\# %s\\nexit 101\\n#'
  'apt_install never guards on a host with pre-existing services|s#\[ -n "\${PRE_UNITS:-}" \]; then#false; then#'
  'cron installed under the guard (could never start)|s#APT_ALLOW_SERVICE_START=1 apt_install cron#apt_install cron#'
  'sysstat installed under the guard (could never start)|s#APT_ALLOW_SERVICE_START=1 apt_install sysstat#apt_install sysstat#'
  'mysql-server installed under the guard (could never start)|s#APT_ALLOW_SERVICE_START=1 apt_install mysql-server#apt_install mysql-server#'
  'fresh postgresql installed under the guard (could never start)|s#APT_ALLOW_SERVICE_START=1 apt_install postgresql postgresql-client#apt_install postgresql postgresql-client#'
  # round 4: the rollback journal (SIGKILL)
  'journal never written before the first change|s#^    _apache_journal_open "\$ad" "\$dest"#    :#'
  'reload marker never written (rollback cannot tell the reload was reached)|s#\[ "\$_WB_ARMED" = 0 \] || : > "\$(_journal_dir)/reloaded"#:#'
  'a killed install is never recovered at the next start|s#^  _apache_journal_recover$#  :#'
  'recovery ignores a journal whose installer is still alive|s#\[ "\$pid" != "\$(_installer_pid)" \] \&\& _pid_alive#[ "$pid" != "$(_installer_pid)" ] \&\& false \&\& _pid_alive#'
  'recovery carries on when it could not undo the changes|s#\[ ! -d "\$j" \] || die "Could not undo#true || die "Could not undo#'
  'an incomplete journal is replayed instead of discarded|s#\[ -f "\$j/complete" \] || { rm -rf "\$j"; return 0; }#:#'
  # round 5: started_by_run, modules snapshot, pid identity, env sanitising
  'rollback/recovery stops any active Apache (started_by_run ignored)|s#elif \[ -f "\$j/started_by_run" \] \&\& svc_active apache2; then#elif svc_active apache2; then#'
  'started_by_run never written (an Apache we started is left running)|s#then : > "\$(_journal_dir)/started_by_run"; fi#then :; fi#'
  'started_by_run written for a running Apache too|s#\] \&\& \[ ! -f "\$(_journal_dir)/was_active" \]; then : >#]; then : >#'
  'an earlier run'"'"'s modules disabled by a later rollback (snapshot ignored)|s#if \[ -f "\$j/mods.before" \] \&\& grep -qxF "\$m" "\$j/mods.before"; then keep#if false; then keep#'
  'modules snapshot never taken at journal open|s#if \[ -f "\$(_apache_mods_state)" \]; then cp "\$(_apache_mods_state)" "\$j/mods.before"; else : > "\$j/mods.before"; fi#:#'
  '_pid_alive ignores the start time (a reused pid looks alive)|s#\[ -z "\${2:-}" \] || \[ "\$(_pid_start "\$1")" = "\$2" \]#true#'
  'guard script ignores the start time (pid only)|s#^  if \[ -n "\$start" \]; then$#  if false; then#'
  'journal does not record the installer start time|s#_installer_start > "\$j/start"#:#'
  'inherited test seams kept (no env sanitising)|s#^if \[ "\${LARANODE_INSTALLER_TEST:-0}" != 1 \]; then#if false; then#'
  'inherited APT_ALLOW_SERVICE_START kept|s#unset APT_ALLOW_SERVICE_START #unset #'
  'inherited LARANODE_ROLLBACK_DIR kept|s#LARANODE_ROLLBACK_DIR LARANODE_INSTALLER_PID#LARANODE_INSTALLER_PID#'
  'inherited LARANODE_INSTALLER_PID kept|s#LARANODE_INSTALLER_PID LARANODE_INSTALLER_START#LARANODE_INSTALLER_START#'
  # sudo review r1: root never runs PHP from the panel tree
  'artisan runs as root again|s#^_artisan() { _as_panel_user /usr/bin/php8.4 artisan "\$@"; }#_artisan() { /usr/bin/php8.4 artisan "$@"; }#'
  'composer runs as root again|s#_as_panel_user /usr/bin/php8.4 /usr/local/bin/composer#/usr/bin/php8.4 /usr/local/bin/composer#'
  'settle makes bootstrap/cache web-writable again|s#^  _as_panel_user chmod 770 "\$h/logs"$#  _as_panel_user chmod 770 "$h/logs" "$p/bootstrap/cache"#'
  'panel tree not chowned before the first PHP run|s#chown -R -h laranode_ln:laranode_ln "\$p"#:#'
  'planted bootstrap caches kept|s# -delete$# -print#'
  'tree never prepared before the first composer/artisan run|s#^  _prepare_panel_tree$#  :#'
  # sudo review r3 F2: root-run steps never read the writable panel tree
  'npm install runs as root again|s#_as_panel_user npm install#npm install#'
  'npm run build runs as root again|s#_as_panel_user npm run build#npm run build#'
  'node_modules chmod walked as root again|s#_as_panel_user find "${PANEL_PATH}/node_modules"#find "${PANEL_PATH}/node_modules"#'
  'scheduler cron rendered from the panel tree again|s#local tpl="${LN_LIB_DEST}/templates/laranode-schedule.cron"#local tpl="${PANEL_PATH}/laranode-scripts/templates/laranode-schedule.cron"#'
  'queue unit copied from the panel tree again|s#cp "${LN_LIB_DEST}/templates/laranode-queue-worker.service"#cp "${PANEL_PATH}/laranode-scripts/templates/laranode-queue-worker.service"#'
  'reverb unit copied from the panel tree again|s#cp "${LN_LIB_DEST}/templates/laranode-reverb.service"#cp "${PANEL_PATH}/laranode-scripts/templates/laranode-reverb.service"#'
  'panel vhost rendered from the panel tree again|s#local tmpl="${LN_LIB_DEST}/templates/apache-panel.template"#local tmpl="${PANEL_PATH}/laranode-scripts/templates/apache-panel.template"#'
  'a re-run syncs with the checkout sync script, not the root-owned one|s#if \[ ! -f "$sync" \]; then#if true; then#'
  'root-owned copy not published in phase_fetch_panel|s#^  _install_privileged_scripts$#  :#'
  'settle chmods the tree as root again|s#_as_panel_user find "$h" -type d -exec chmod 750#find "$h" -type d -exec chmod 750#'
  'storage chmod run as root again|s#_as_panel_user find "$p/storage" -type d#find "$p/storage" -type d#'
  # sudo review r4: .env / .env.example / the sync script are never touched by root through a link
  '_seed_env copies as root again (follows a planted .env.example link)|s#^  _as_panel_user bash -c "\$(declare -f _seed_env_inner).*#  ( umask 027; cp "${PANEL_PATH}/.env.example" "$env" ); chmod 640 "$env"#'
  'env_set edits as root again (follows a planted .env link)|s#| _as_panel_user bash -c "\$(declare -f _env_set_inner)#| bash -c "$(declare -f _env_set_inner)#'
  'env_set value passed in argv again|s#_env_set_inner \\"\\$@\\"" _ "\$k" "\$f"#_env_set_inner \\"\\$@\\"" _ "$k" "$f" "$v"#'
  'settle chmods .env as root again|s#\[ -f "\$p/.env" \] \&\& _as_panel_user chmod 640#[ -f "$p/.env" ] \&\& chmod 640#'
  'settle creates logs/ as root again|s#_as_panel_user mkdir -p "\$h/logs"#mkdir -p "$h/logs"#'
  'first-install sync runs from the checkout again|s#^    sync="\${LN_SYNC_STASH}/sync.sh"#    sync="${PANEL_PATH}/laranode-scripts/bin/laranode-sync-scripts.sh"#'
  'sync script not stashed before the chown|s#^  _stash_sync_script$#  :#'
  'stash follows a link (cp without -P)|s#cp -P --no-preserve=all "\$src"#cp "$src"#'
  'stash accepts a symlink|s#if \[ -L "\${LN_SYNC_STASH}/sync.sh" \] || \[ ! -f "\${LN_SYNC_STASH}/sync.sh" \]; then#if false; then#'
  # sudo review r3 F3
  'protected_hardlinks=0 accepted|s#\[ "$v" = 1 \] || die "fs.protected_hardlinks#true || die "fs.protected_hardlinks#'
  'protected_hardlinks never checked by main|s#^  _require_protected_hardlinks$#  :#'
  # PR B G2/G7: Proxmox web user (laranode_web, never www-data) + ufw gate
  'Proxmox: web user never resolved in preflight|s#^  _resolve_web_user$#  :#'
  'Proxmox: panel runs as www-data again|s#^  WEB_USER=laranode_web$#  WEB_USER=www-data#'
  'Proxmox: pre-existing Apache accepted (cannot switch its User)|s#|| die "Proxmox host with a pre-existing Apache#|| true "#'
  'Proxmox: pre-existing php8.4-fpm accepted|s#|| die "Proxmox host with a pre-existing php8.4-fpm#|| true "#'
  'Proxmox: ufw stays on without LARANODE_PVE_UFW|s#\[ "\${LARANODE_PVE_UFW:-0}" = 1 \] || UFW_ENABLED=0#:#'
  'web user never created/verified|s#^  _ensure_web_user$#  :#'
  'web user uid not checked (root or a login uid accepted)|s#|| die "panel web user \${WEB_USER} must be a system account#|| true "#'
  'web user in group www-data accepted|s#die "panel web user \${WEB_USER} is in group www-data#true "#'
  'www-data kept in the panel group on Proxmox|s#gpasswd -d www-data laranode_ln >/dev/null || die#true || die#'
  'host.conf never written|s#^  _write_host_conf$#  :#'
  'ufw sudoers required even with ufw off|s#if \[ "\${UFW_ENABLED:-1}" = 1 \]; then need+=(laranode-ufw); else rm -f "\${sd}/laranode-ufw"; fi#need+=(laranode-ufw)#'
  'Firewall page flag not written|s#^  _panel_feature_env$#  :#'
  'panel Apache not switched to the web user|s#^  _apache_web_user$#  :#'
  'panel PHP-FPM pool not written for the web user|s#^  _write_panel_pool$#  :#'
  # PR B G1: pinned ref
  'no ref: silent default branch installed|s#\[ -n "\$r" \] || die "No ref to install#true || die "#'
  'ref not validated (option smuggling)|s#=~ ^\[A-Za-z0-9\]\[A-Za-z0-9._/-\]{0,127}\$ \]\]#=~ .* ]]#'
  'clone through a symlinked PANEL_PATH|s#\[ ! -L "\$PANEL_PATH" \] || die#true || die#'
  'clone runs as root again|s#_as_panel_user git clone --quiet#git clone --quiet#'
  'clone HEAD not verified against the ref|s#|| die "checkout is not at#|| true "#'
  'existing checkout not verified against LARANODE_REF|s#|| die "the existing checkout at \${PANEL_PATH} is not at#|| true "#'
  # PR #11 r1: only a tag or a full commit id; the tree must be clean
  'branch accepted as LARANODE_REF (tag-only lookup dropped)|s#rev-parse -q --verify "refs/tags/\${r}^{commit}"#rev-parse -q --verify "${r}^{commit}"#'
  'short commit id accepted|s#die "LARANODE_REF .\${r}. is a short commit id#true "#'
  'HEAD / moving refs accepted|s#die "LARANODE_REF .\${r}. is a moving reference#true "#'
  'clone tree not checked clean|s#|| die "the checkout at \${PANEL_PATH} is not clean#|| true "#'
  're-run tree not checked clean|s#|| die "the existing checkout at \${PANEL_PATH} is not clean#|| true "#'
  # PR #11 r1: upgrade from a www-data install moves the tenant groups to the web user
  'upgrade: updated sync not run again (old sync renders www-data grants)|s#^  if \[ -n "\$before" \] \&\& \[ "$(sha256sum < "$inst")" != "\$before" \]; then#  if false; then#'
  'dedicated web user: www-data drop-in left in place|s#if grep -qE .\^\[\[:space:\]\]\*www-data\[\[:space:\]\]. "\$drop"; then#if false; then#'
  'clean-tree check compares file modes again (a re-run always dirty after the installer chmod)|s#git -c core.fileMode=false -C "$1" status#git -C "$1" status#'
  'tenant groups never migrated|s#^  _migrate_tenant_groups$#  :#'
  'tenant groups migrated with the account setup again (before the ref check)|s#^  usermod -aG laranode_ln "\$WEB_USER"$#&\n  _migrate_tenant_groups#;s#^  _migrate_tenant_groups$#  :#'
  'tenant groups migrated before the Apache config test again|s#^  _migrate_tenant_groups$#  :#;s#^  _apache_web_user$#  _migrate_tenant_groups\n&#'
  'tenant groups migrated after the Apache reload|s#^  _migrate_tenant_groups$#  :#;s#^  svc_active apache2 || die .*$#&\n  _migrate_tenant_groups#'
  'www-data kept in tenant groups|s#gpasswd -d www-data "\$g" >/dev/null || die#true || die#'
  'non-tenant group migrated (uid check dropped)|s#\[ "\$uid" -ge 1000 \] \&\& \[ "\$home" = "/home/\$g" \]#true#'
  # PR B G3: production env
  'APP_ENV not production|s#^  env_set APP_ENV production#  env_set APP_ENV local#'
  'APP_DEBUG left on|s#^  env_set APP_DEBUG false#  env_set APP_DEBUG true#'
  # PR B r4 nits
  'env_set accepts a newline / CR / double quote|s#) die "refusing to write \${k}: the value holds#) true "#'
  'sync stash left behind on die (no exit hook)|s#^  _add_exit_hook _stash_cleanup$#  :#'
  '.env read by root again (follows a planted link)|s#v=\$(_as_panel_user cat -- "\${PANEL_PATH}/.env"#v=$(cat -- "${PANEL_PATH}/.env"#'
)

fail=0
i=0
ran=0
for m in "${MUTATIONS[@]}"; do
  i=$((i + 1))
  [ $(( (i - 1) % SHARD_N )) -eq $(( SHARD_K - 1 )) ] || continue
  ran=$((ran + 1))
  name="${m%%|*}"; expr="${m#*|}"
  cp "$SRC" "$WORK/mut$i.sh"
  sed -i "$expr" "$WORK/mut$i.sh"
  if cmp -s "$SRC" "$WORK/mut$i.sh"; then
    echo "MUTATION $i NOT APPLIED (pattern no longer matches the installer): $name"; fail=1; continue
  fi
  if LARANODE_INSTALLER="$WORK/mut$i.sh" bash "${HERE}/unit/test-host-detection.sh" >"$WORK/out$i.log" 2>&1; then
    echo "MUTATION $i SURVIVED (tests stayed green): $name"; fail=1
  else
    echo "mutation $i caught ($(grep -c 'FAIL:' "$WORK/out$i.log") failing tests): $name"
  fi
done
echo "== mutations run: ${ran} of ${#MUTATIONS[@]} (shard ${SHARD_K}/${SHARD_N}) =="
[ "$ran" -gt 0 ] || { echo "no mutation selected (SHARD='$SHARD')"; exit 2; }
[ "$fail" -eq 0 ] && echo "ALL MUTATIONS CAUGHT" || echo "MUTATION SMOKE FAILED"
exit "$fail"
