#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# laranode-vhost-switch.sh <domain> <runtime> <port> <system_user> <php_version> <document_root> <template_dir>
# Writes Apache vhost for the given runtime. Does NOT touch systemd units.
# Called via sudo by SwitchRuntimeService.
ln_argc 7 7 "$0 <domain> <runtime> <port> <system_user> <php_version> <document_root> <template_dir>"
ln_domain "$1" DOMAIN
ln_enum "$2" RUNTIME php-fpm frankenphp swoole
# the FPM revert passes port 0 (no backend port); only that runtime may
if [ "$RUNTIME" = php-fpm ]; then ln_port "$3" PORT allow_zero; else ln_port "$3" PORT; fi
ln_sysuser "$4" SYSTEM_USER
ln_phpver "$5" PHP_VERSION
ln_docroot "$6" DOCUMENT_ROOT
ln_template_dir "$7" TEMPLATE_DIR

if [ "$RUNTIME" = "php-fpm" ]; then
    TEMPLATE_FILE="$TEMPLATE_DIR/apache-vhost.template"
else
    TEMPLATE_FILE="$TEMPLATE_DIR/apache-vhost-frankenphp.template"
fi
[ -f "$TEMPLATE_FILE" ] || ln_die "template not found"

VHOST="/etc/apache2/sites-available/${DOMAIN}.conf"
ln_render "$TEMPLATE_FILE" domain "$DOMAIN" user "$SYSTEM_USER" document_root "$DOCUMENT_ROOT" \
    port "$PORT" phpVersion "$PHP_VERSION" | ln_install_file "$VHOST" 644
echo "Written vhost: $VHOST"

# Enable + reload Apache
a2ensite "$DOMAIN"
apache2ctl graceful
echo "Apache reloaded for $DOMAIN."
