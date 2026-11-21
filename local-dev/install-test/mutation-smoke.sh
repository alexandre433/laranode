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
  'stale-guard cleanup ignores a still-running installer|s#kill -0 "\$pid" 2>/dev/null#false#'
  'guard removes a policy-rc.d that is not ours|s#if _policy_guard_is_ours; then rm -f#if true; then rm -f#'
  'Listen/vhost rollback never runs|s#\[ "\$_WB_ARMED" = 1 \] || return 0#return 0#'
  'modules enabled by a failed run not disabled again|s#a2dismod "\$m" >/dev/null 2>\&1 || warn#true || warn#'
  'live pre-existing php8.4-fpm restarted by the extension postinst (no guard)|s#if \[ "\${PHPFPM_OWNED:-1}" = 0 \]; then _policy_guard_on; fi#:#'
  'ss-less host proceeds without any listener probe|s#_probe_available || die "Cannot#true || die "Cannot#'
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
