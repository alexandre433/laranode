#!/usr/bin/env bash
# Mutation smoke: re-introduce each reviewed bug into a COPY of the installer and
# require the host-detection unit tests to go red. A guard whose test cannot fail is
# not a guard. Runs on Linux/CI in about a minute; never touches the real installer.
#
#   bash local-dev/install-test/mutation-smoke.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../../laranode-scripts/bin/laranode-installer.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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
)

fail=0
i=0
for m in "${MUTATIONS[@]}"; do
  i=$((i + 1))
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
[ "$fail" -eq 0 ] && echo "ALL MUTATIONS CAUGHT" || echo "MUTATION SMOKE FAILED"
exit "$fail"
