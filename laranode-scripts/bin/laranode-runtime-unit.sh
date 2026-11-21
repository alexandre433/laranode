#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# laranode-runtime-unit.sh <sub-command> <domain> <port> <system_user> <document_root> <template_dir>
# Writes a systemd unit file for a Laranode runtime and reloads the daemon.
# Called via sudo by SwitchRuntimeService.
ln_argc 6 6 "$0 <sub-command> <domain> <port> <system_user> <document_root> <template_dir>"
ln_enum "$1" SUBCMD write-unit
ln_domain "$2" DOMAIN
ln_port "$3" PORT
ln_sysuser "$4" SYSTEM_USER
ln_docroot "$5" DOCUMENT_ROOT
ln_template_dir "$6" TEMPLATE_DIR

TEMPLATE_FILE="$TEMPLATE_DIR/laranode-frankenphp.service.template"
[ -f "$TEMPLATE_FILE" ] || ln_die "template not found"
UNIT_NAME="laranode-frankenphp-${DOMAIN}.service"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"

ln_render "$TEMPLATE_FILE" user "$SYSTEM_USER" domain "$DOMAIN" port "$PORT" \
    document_root "$DOCUMENT_ROOT" | ln_install_file "$UNIT_PATH" 644
echo "Written unit file: $UNIT_PATH"

# daemon-reload MUST happen before enable/start
systemctl daemon-reload
echo "daemon-reload complete."
