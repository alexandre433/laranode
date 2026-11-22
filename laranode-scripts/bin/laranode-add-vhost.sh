#!/bin/bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # before ANY command runs: dirname below must not come from the caller's PATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Usage: laranode-add-vhost.sh {system user} {domain} {documentRoot} {phpVersion} {template_file_path}
ln_argc 5 5 "$0 {system user} {domain} {documentRoot} {phpVersion} {template_file_path}"
ln_sysuser "$1" SYSTEM_USER
ln_domain "$2" DOMAIN
ln_docroot "$3" DOCUMENT_ROOT
ln_phpver "$4" PHP_VERSION
ln_template "$5" TEMPLATE_FILE_PATH apache-vhost.template

ln_render "$TEMPLATE_FILE_PATH" user "$SYSTEM_USER" domain "$DOMAIN" \
    document_root "$DOCUMENT_ROOT" phpVersion "$PHP_VERSION" \
    | ln_install_file "/etc/apache2/sites-available/$DOMAIN.conf" 644

# enable vhost
echo "Enabling vhost $DOMAIN"
a2ensite "$DOMAIN"

# reload apache
echo "Reload apache"
systemctl reload apache2
