#!/usr/bin/env bash
# Hostile-argument test for EVERY script www-data may sudo. Runs inside a container,
# as root; each script is invoked the way PHP does it (www-data -> sudo -n <script> ...).
#
# For every argument position of every script, one hostile value at a time replaces the
# valid one (root, ../, newline, spaces, sed metacharacters, globs, symlinks, option
# smuggling ...). Pass = the script exits non-zero AND nothing on the host changed
# (shadow/passwd hashes, /etc/hostname owner, canary file, vhost/pool/unit/cron/sudoers
# listings, no planted marker). Exit codes alone prove nothing; the snapshot is the oracle.
#
# With STUBS=1 (fast harness: systemctl/apache2ctl/apt-get/mysql... are stubs) the
# POSITIVE case of each script also runs with the exact arguments PHP sends: an
# over-strict validator would silently break a panel feature.
#
#   assert-hostile.sh [script-basename ...]     (default: every script)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

BIN=$(ln_bin_dir) || { echo "FAIL: no sudo-granted laranode script found" >&2; exit 1; }
TPL=$(ln_tpl_dir)
ONLY=("$@")
fail=0; n_host=0; n_pos=0
bad() { echo "FAIL: $*" >&2; fail=1; }

# ── fixtures ────────────────────────────────────────────────────────────────────────
fx_reset() {
    local u
    for u in alice_ln bob_ln; do
        getent passwd "$u" >/dev/null || useradd -m -s /usr/sbin/nologin "$u"
        mkdir -p "/home/$u/domains" "/home/$u/logs"
        usermod -aG "$u" www-data
    done
    getent passwd svc_ln >/dev/null || useradd -u 501 -M -s /usr/sbin/nologin svc_ln   # uid < 1000
    mkdir -p /home/alice_ln/domains/example.com/public /home/bob_ln/domains/example.org/public
    echo '<?php' > /home/alice_ln/domains/example.com/public/index.php
    chown -R alice_ln:alice_ln /home/alice_ln; chown -R bob_ln:bob_ln /home/bob_ln
    chmod -R u+rwX,g+rwX /home/alice_ln/domains /home/bob_ln/domains
    chmod 770 /home/alice_ln /home/bob_ln
    mkdir -p /etc/php/8.4/fpm/pool.d /etc/php/8.3/fpm/pool.d /etc/apache2/sites-available /etc/apache2/sites-enabled
    rm -f /etc/php/8.4/fpm/pool.d/alice_ln.conf /etc/php/8.3/fpm/pool.d/alice_ln.conf \
          /etc/apache2/sites-available/example.com.conf /etc/apache2/sites-available/example.com-ssl.conf \
          /etc/systemd/system/laranode-frankenphp-example.com.service
    printf '<VirtualHost *:80>\n    ServerName example.com\n    SetHandler "proxy:unix:/run/php/php-fpm-8.3.alice_ln.sock|fcgi://localhost"\n</VirtualHost>\n' \
        > /etc/apache2/sites-available/example.com.conf
    printf 'canary\n' > /etc/laranode-canary
    # attacker-planted material (www-data owns all of it: that is the threat model)
    rm -rf /tmp/evildir /tmp/evil.template /tmp/laranode-* /tmp/pwned*
    mkdir -p /tmp/evildir
    local evil='ErrorLog "|/bin/sh -c '\''touch /tmp/pwned-template'\''"'
    for t in apache-vhost.template apache-vhost-frankenphp.template laranode-frankenphp.service.template php-fpm-pool.template; do
        printf '%s\n[Service]\nExecStartPre=/bin/touch /tmp/pwned-template\n' "$evil" > "/tmp/evildir/$t"
    done
    printf '%s\n' "$evil" > /tmp/evil.template
    chown -R www-data:www-data /tmp/evildir /tmp/evil.template
    runuser -u www-data -- ln -sfn /etc /home/alice_ln/domains/linketc
    runuser -u www-data -- ln -sfn /etc/hostname /tmp/laranode-link-out
    runuser -u www-data -- ln -sfn /etc/shadow /tmp/laranode-restore-link
    # valid temp inputs, created by www-data like PHP's tempnam()
    runuser -u www-data -- sh -c ': > /tmp/laranode-backup-pos.tgz; : > /tmp/laranode-backup-pos2.tgz'
    runuser -u www-data -- sh -c 'printf "[client]\npassword=x\n" > /tmp/laranode-restore-x.cnf; chmod 600 /tmp/laranode-restore-x.cnf'
    ( cd /home/alice_ln/domains/example.com && mkdir -p /tmp/tarsrc && echo hi > /tmp/tarsrc/restored.txt \
        && tar -czf /tmp/laranode-restore-pos.tgz -C /tmp/tarsrc . && rm -rf /tmp/tarsrc )
    printf 'select 1;\n' | gzip > /tmp/laranode-restore-pos.sql.gz
    rm -f /tmp/laranode_cron_pos   # created by www-data, like PHP's tempnam (root may not reopen it: fs.protected_regular)
    runuser -u www-data -- sh -c 'printf "* * * * *\\tphp /home/alice_ln/domains/example.com/public/index.php\\n" > /tmp/laranode_cron_pos'
    chown www-data:www-data /tmp/laranode-restore-pos.tgz /tmp/laranode-restore-pos.sql.gz /tmp/laranode_cron_pos
    : > /var/log/laranode-stub.log 2>/dev/null || true
}

# ── world save / restore: a hostile call that DID damage the host must not poison later cases ──
WORLD_DIRS=(/etc /home /var/spool /tmp /var/log)
WORLD_FILES=(etc)
world_save() {
    tar -cpf /root/base-files.tar -C / "${WORLD_FILES[@]}" 2>/dev/null
    tar -cpf /root/base-home.tar -C / home 2>/dev/null
    find "${WORLD_DIRS[@]}" -mindepth 1 2>/dev/null | grep -v "^/var/log/laranode-stub.log$" | sort > /root/base.list
}
world_restore() {
    find "${WORLD_DIRS[@]}" -mindepth 1 2>/dev/null | grep -v "^/var/log/laranode-stub.log$" | sort | comm -13 /root/base.list - | sort -r | while read -r f; do rm -rf -- "$f"; done
    tar -xpf /root/base-files.tar --same-owner --overwrite -C / 2>/dev/null; : > /var/log/laranode-stub.log
    tar -xpf /root/base-home.tar --same-owner --overwrite -C / 2>/dev/null
    chown root:root /tmp /var/tmp /home /var/spool 2>/dev/null; chmod 1777 /tmp /var/tmp 2>/dev/null; chmod 755 /home 2>/dev/null
    rm -f /tmp/pwned*
    fx_reset
}

# ── values ──────────────────────────────────────────────────────────────────────────
# V_<kind> = the valid value PHP sends; H_<kind> = hostile values for that position.
NL=$'\n'
HUSER=( root root_ln '../../etc/x' 'alice_ln x' "alice_ln${NL}root:Pwned" 'a;id' '-n' '*' nobody postgres '' 'alice_ln/..' '$(id)' svc svc_ln laranode_ln_x ../alice_ln )
V_user=alice;   H_user=( "${HUSER[@]}" )
V_userln=alice_ln; H_userln=( "${HUSER[@]}" )
# pool removal runs AFTER the account is gone (DeleteAccountService), so it accepts any well-formed
# name; only malformed names and the panel's own user are hostile there.
V_userrm=alice; H_userrm=( '../../etc/x' 'alice_ln x' "alice_ln${NL}root:Pwned" 'a;id' '-n' '*' '' 'alice_ln/..' '$(id)' laranode ../alice_ln )
V_newuser=carol; H_newuser=( '../x' 'a b' "a${NL}b" 'a;id' '-n' '*' '' "$(printf 'x%.0s' {1..60})" 'a:b' laranode )
V_domain=example.com
H_domain=( '../x' 'a/b' 'a b' "a${NL}b" '-x.com' '*' 'x.com;id' 'x..com' '' 'a.com/../../etc/cron.d/x' '.hidden' 'a.com.' 'a$(id).com' 'a|b.com' '-' 'a#b.com' )
V_phpver=8.4;   H_phpver=( '8.4;id' '../8.4' '-o Dpkg::Pre-Invoke=id' '8.4 8.3' '*' 8 "8.4${NL}" '' 8.4.1 x '8.4-*' )
V_phpold=8.3;   H_phpold=( "${H_phpver[@]}" )
V_docroot=/public
H_docroot=( '/../../..' '/a b' "/a${NL}b" '/a;id' '/a&b' '/a|b' '/a"b' '/$(id)' '~' '/a#b' '/a\\b' '/../etc' )
V_port=9100;    H_port=( 0 99 9099 9500 99999 '9100;id' -1 '9100 ' '' 0x2000 "9100${NL}9101" )
V_email=ops@example.com; H_email=( '-x@a.com' 'a b@x.com' "a@b.com${NL}x" 'a@b.com;id' '' no-at-sign 'a@b.com --agree' )
V_pw='S3cret pass!#&*$x'; H_pw=( "p${NL}root:Pwned" $'p\rx' '' "$(head -c 300 /dev/zero | tr '\0' a)" )
V_yesno=yes;    H_yesno=( bogus -x "yes${NL}x" 'yes x' 'yes;id' '' )
V_dbname=alice_db; H_dbname=( 'a;b' 'a b' '-x' "a${NL}b" '../x' '' "a'b" 'a.b' )
V_dbuser=alice_dbu; H_dbuser=( root debian-sys-maint mysql 'a;b' 'a b' '-x' "a${NL}b" '' 'root ' )
V_engine=mysql; H_engine=( postgres '-x' bogus "mysql${NL}x" '' 'mysql;id' )
V_sitepath=/home/alice_ln/domains/example.com
H_sitepath=( /etc / '/home/alice_ln/domains/example.com/../../../../etc' /home/alice_ln/domains/../.. /home/bob_ln/domains/example.org relative "/home/alice_ln/domains/example.com${NL}x" /home/alice_ln/domains/linketc '/home/alice_ln/domains/example.com/../../bob_ln' -x /home/alice_ln )
V_tmpout=/tmp/laranode-backup-pos.tgz
H_tmpout=( /etc/passwd /etc/cron.d/laranode-x '/tmp/../etc/cron.d/x' /tmp/notlaranode-x /tmp/laranode-link-out '/tmp/laranode-x/../../etc/passwd' "/tmp/laranode-x${NL}y" relative -x /etc/hostname /var/tmp/../../etc/x '' )
V_dbout=/tmp/laranode-db-backup-pos.sql.gz; H_dbout=( "${H_tmpout[@]}" )
V_tmpin_tar=/tmp/laranode-restore-pos.tgz
H_tmpin_tar=( /etc/shadow /root/.bashrc /tmp/laranode-restore-link '/tmp/../etc/shadow' "/tmp/laranode-restore-x${NL}y" relative -x /etc/passwd '' /tmp/laranode-nonexistent.tgz )
V_tmpin_sql=/tmp/laranode-restore-pos.sql.gz; H_tmpin_sql=( "${H_tmpin_tar[@]}" )
V_cnf=/tmp/laranode-restore-x.cnf
H_cnf=( /etc/mysql/debian.cnf /root/.my.cnf /etc/shadow '/tmp/../etc/shadow' -x relative "/tmp/laranode-x${NL}y" '' /tmp/laranode-restore-link )
V_destdir=/home/alice_ln/domains/example.com
H_destdir=( /etc /etc/cron.d '/home/alice_ln/domains/../../../etc' /home/bob_ln/domains/example.org /home/alice_ln /home/alice_ln/domains/linketc "/home/alice_ln/domains/x${NL}y" relative -x '' '/home/alice_ln/domains/linketc/x' '/home/alice_ln/domains/example.com/../../../etc' )
V_dirpath=/home/alice_ln/domains/new.com/public
H_dirpath=( /etc/cron.d/x '/home/alice_ln/domains/../../../etc/x' /home/bob_ln/domains/x /tmp/x "/home/alice_ln/domains/x${NL}y" relative -x '' /home/alice_ln/domains/linketc/x /etc )
V_relpath=domains/example.com/public/index.php
H_relpath=( domains/linketc/hostname domains/linketc/passwd '../../etc/passwd' '../../../etc/hostname' 'domains/../../../etc/hostname' domains/linketc "a${NL}b" '' '-x' '../bob_ln/domains/example.org/public' '../../../../etc/hostname' )
V_tpl_pool="$TPL/php-fpm-pool.template"
H_tpl_pool=( /tmp/evil.template /etc/passwd "$TPL/../../../../tmp/evil.template" "$TPL/php-fpm-pool.template${NL}" '' relative.template -x /tmp/evildir/php-fpm-pool.template "$TPL/apache-vhost.template" )
V_tpl_vhost="$TPL/apache-vhost.template"
H_tpl_vhost=( /tmp/evil.template /etc/passwd "$TPL/../../../../tmp/evil.template" "$TPL/apache-vhost.template${NL}" '' relative.template -x /tmp/evildir/apache-vhost.template "$TPL/php-fpm-pool.template" )
V_tpldir="$TPL"
H_tpldir=( /tmp/evildir /etc '' relative -x "$TPL${NL}x" "$TPL/.." /tmp )
V_dbaction=restart;  H_dbaction=( bogus -x "restart${NL}x" 'restart;id' '' )
V_dbengine=mysql;    H_dbengine=( postgres2 -x bogus "mysql${NL}x" '' 'mysql;id' )
V_phpaction=restart; H_phpaction=( bogus -x "restart${NL}x" 'restart;id' '' )
V_rtaction=enable;   H_rtaction=( bogus -x "enable${NL}x" 'enable;id' '' 'enable --now' )
V_unit=laranode-frankenphp-example.com.service
H_unit=( 'laranode-frankenphp-../x.service' ssh.service -x "laranode-frankenphp-a.service${NL}x" 'laranode-frankenphp-a b.service' 'laranode-swoole-x.service;id' '' laranode-frankenphp-a..b.service 'laranode-frankenphp-/x.service' 'cron.service' )
V_runtime=frankenphp; H_runtime=( bash -x "frankenphp${NL}x" 'frankenphp;id' '' swoole2 )
V_swruntime=frankenphp; H_swruntime=( bash -x "frankenphp${NL}x" 'frankenphp;id' '' )
V_wu=write-unit; H_wu=( bogus -x "write-unit${NL}x" '' 'write-unit;id' )
V_status=status; H_status=( bogus -x "status${NL}x" '' )
V_remove=remove; H_remove=( bogus -x "remove${NL}x" '' )
V_generate=generate; H_generate=( bogus -x "generate${NL}x" '' )
V_cronset=list; H_cronset=( bogus -x "list${NL}x" '' 'list;id' )
V_cronsetc=set; H_cronsetc=( bogus -x "set${NL}x" '' 'set;id' )
V_create=create; H_create=( bogus -x "create${NL}x" '' )
V_delete=delete; H_delete=( bogus -x "delete${NL}x" '' )
V_sslroot=/home/alice_ln/domains/example.com/public
H_sslroot=( /etc '/home/alice_ln/domains/example.com/../../../../etc' /home/bob_ln/domains/example.org/public /home/alice_ln/domains/other.com/public relative "/home/alice_ln/domains/example.com/a${NL}b" '/home/alice_ln/domains/example.com/a b' -x '/home/alice_ln/domains/linketc' )
V_crontmp=/tmp/laranode_cron_pos; H_crontmp=( /etc/passwd /nonexistent '' -x )
V_ufwrule=22/tcp
H_ufwrule=( '22;id' -x --force '$(id)' "22/tcp${NL}x" 'a b' 99999999 22/tcp/x '' 'x y z' '*' '22/tcp;id' '/etc/passwd' )
V_ufwallow=allow; H_ufwallow=( bogus -x '' 'allow;id' "allow${NL}x" --force )
V_ufwdeny=deny;   H_ufwdeny=( bogus -x '' 'deny;id' )
V_ufwdel=delete;  H_ufwdel=( bogus -x '' 'delete;id' )
V_ufwst=status;           H_ufwst=( bogus -x '' 'status;id' )
V_ufwstn=status-numbered; H_ufwstn=( bogus -x '' 'status-numbered;id' )
V_ufwsa=show-added;       H_ufwsa=( bogus -x '' 'show-added;id' )
V_ufwen=enable;           H_ufwen=( bogus -x '' 'enable;id' )
V_ufwdis=disable;         H_ufwdis=( bogus -x '' 'disable;id' )

# ── spec table: NAME|script|runas|kinds…|positive-oracle (bash, run as root) ────────
SPECS=(
 'add-pool|laranode-add-php-fpm-pool.sh|root|user phpver tpl_pool|grep -q "^\[alice_ln\]" /etc/php/8.4/fpm/pool.d/alice_ln.conf'
 'add-vhost|laranode-add-vhost.sh|root|userln domain docroot phpver tpl_vhost|grep -q "ServerName example.com" /etc/apache2/sites-available/example.com.conf && ! grep -q "{" /etc/apache2/sites-available/example.com.conf'
 'backup-files|laranode-backup-files.sh|root|sitepath tmpout userln|tar -tzf /tmp/laranode-backup-pos.tgz | grep -q public && [ "$(stat -c %U /tmp/laranode-backup-pos.tgz)" = www-data ]'
 'create-directory|laranode-create-directory.sh|root|dirpath user|[ -d /home/alice_ln/domains/new.com/public ] && [ "$(stat -c %U /home/alice_ln/domains/new.com/public)" = alice_ln ]'
 'db-backup|laranode-db-backup.sh|root|engine dbname dbuser cnf dbout|[ -s /tmp/laranode-db-backup-pos.sql.gz ]'
 'file-permissions|laranode-file-permissions.sh|root|relpath user|[ "$(stat -c "%U %a" /home/alice_ln/domains/example.com/public/index.php)" = "alice_ln 660" ]'
 'php-install|laranode-php-install.sh|root|phpver|grep -q "php8.4-fpm" /var/log/laranode-stub.log'
 'php-list|laranode-php-list.sh|root||true'
 'php-service|laranode-php-service.sh|root|phpaction phpver|grep -q "systemctl restart php8.4-fpm" /var/log/laranode-stub.log'
 'php-uninstall|laranode-php-uninstall.sh|root|phpver|grep -q "apt-get remove" /var/log/laranode-stub.log'
 'remove-all-pools|laranode-remove-all-user-php-fpm-pools.sh|root|userrm|[ ! -e /etc/php/8.4/fpm/pool.d/alice_ln.conf ]'
 'remove-pool-user|laranode-remove-php-fpm-pool-for-user.sh|root|userrm phpver|[ ! -e /etc/php/8.4/fpm/pool.d/alice_ln.conf ]'
 'restart-php-fpm|laranode-restart-php-fpm.sh|root|phpver|true'
 'restore-db|laranode-restore-db.sh|root|cnf tmpin_sql dbname dbuser|grep -q "select 1" /tmp/mysql-stdin-last'
 'restore-files|laranode-restore-files.sh|root|tmpin_tar destdir userln|[ "$(stat -c %U /home/alice_ln/domains/example.com/restored.txt)" = alice_ln ]'
 'runtime-manage|laranode-runtime-manage.sh|root|rtaction unit|grep -q "systemctl enable laranode-frankenphp-example.com.service" /var/log/laranode-stub.log'
 'runtime-unit|laranode-runtime-unit.sh|root|wu domain port userln docroot tpldir|grep -q -- "--listen 127.0.0.1:9100" /etc/systemd/system/laranode-frankenphp-example.com.service'
 'vhost-switch|laranode-vhost-switch.sh|root|domain swruntime port userln phpver docroot tpldir|grep -q "9100" /etc/apache2/sites-available/example.com.conf'
 'update-php-version|laranode-update-php-version.sh|root|domain phpold phpver|grep -q "php-fpm-8.4" /etc/apache2/sites-available/example.com.conf'
 'update-sh-access|laranode-update-sh-access.sh|root|user yesno|[ "$(getent passwd alice_ln | cut -d: -f7)" = /bin/bash ]'
 'update-sh-password|laranode-update-sh-password.sh|root|userln pw|[ "$(getent shadow alice_ln | cut -d: -f2)" != "$ALICE_HASH" ]'
 'user-create|laranode-user-manager.sh|root|create newuser yesno pw|getent passwd carol_ln >/dev/null && [ -d /home/carol_ln/domains ]'
 'user-delete|laranode-user-manager.sh|root|delete user|! getent passwd alice_ln >/dev/null'
 'db-service|laranode-db-service.sh|root|dbaction dbengine|grep -q "systemctl restart mysql" /var/log/laranode-stub.log'
 'cron-list|laranode-cron.sh|www-data|cronset userln|true'
 'cron-set|laranode-cron.sh|www-data|cronsetc userln crontmp|true'
 'ssl-status|laranode-ssl-manager.sh|root|status domain|true'
 'ssl-remove|laranode-ssl-manager.sh|root|remove domain|true'
 'ssl-generate|laranode-ssl-manager.sh|root|generate domain email sslroot|grep -q "certbot certonly" /var/log/laranode-stub.log'
 'remove-vhost|laranode-remove-vhost.sh|root|domain|[ ! -e /etc/apache2/sites-available/example.com.conf ]'
 'ufw-status|laranode-ufw.sh|root|ufwst|grep -q "^ufw status" /var/log/laranode-stub.log'
 'ufw-status-numbered|laranode-ufw.sh|root|ufwstn|grep -q "^ufw status numbered" /var/log/laranode-stub.log'
 'ufw-show-added|laranode-ufw.sh|root|ufwsa|grep -q "^ufw show added" /var/log/laranode-stub.log'
 'ufw-enable|laranode-ufw.sh|root|ufwen|grep -q "^ufw --force enable" /var/log/laranode-stub.log'
 'ufw-disable|laranode-ufw.sh|root|ufwdis|grep -q "^ufw --force disable" /var/log/laranode-stub.log'
 'ufw-allow|laranode-ufw.sh|root|ufwallow ufwrule|grep -q "^ufw allow 22/tcp" /var/log/laranode-stub.log'
 'ufw-deny|laranode-ufw.sh|root|ufwdeny ufwrule|grep -q "^ufw deny 22/tcp" /var/log/laranode-stub.log'
 'ufw-delete-rule|laranode-ufw.sh|root|ufwdel ufwallow ufwrule|grep -q "^ufw --force delete allow 22/tcp" /var/log/laranode-stub.log'
)
# Positive case skipped where it cannot run against stubs (set to the reason).
declare -A NOPOS=( [runtime-install]=downloads [sleep]=systemd )
declare -A POSRC=( [ssl-status]="0 1" )   # inactive cert makes the script exit 1 (set -e quirk)
# Positive-case arguments that differ from the kind defaults.
declare -A POSARGS=()

# Scripts with action-specific shapes: explicit hostile vectors (script|args…; \x1f separated).
SEP=$'\x1f'
VECTORS=(
 "laranode-runtime-install.sh${SEP}bash"
 "laranode-runtime-install.sh${SEP}-x"
 "laranode-runtime-install.sh${SEP}frankenphp${NL}x"
 "laranode-runtime-install.sh${SEP}frankenphp${SEP}extra"
 "laranode-runtime-install.sh${SEP}"
 "laranode-sleep.sh${SEP}bogus${SEP}enable"
 "laranode-sleep.sh${SEP}reverb${SEP}bogus"
 "laranode-sleep.sh${SEP}../reverb${SEP}enable"
 "laranode-sleep.sh${SEP}reverb${NL}x${SEP}enable"
 "laranode-sleep.sh${SEP}reverb${SEP}enable${SEP}0"
 "laranode-sleep.sh${SEP}reverb${SEP}enable${SEP}99999"
 "laranode-sleep.sh${SEP}reverb${SEP}enable${SEP}5;id"
 "laranode-sleep.sh${SEP}-x${SEP}enable"
 "laranode-sleep.sh${SEP}"
 "laranode-postgres.sh${SEP}bogus"
 "laranode-postgres.sh${SEP}create-db${SEP}a;b${SEP}UTF8${SEP}en_US.UTF-8"
 "laranode-postgres.sh${SEP}create-db${SEP}a${NL}b${SEP}UTF8${SEP}en_US.UTF-8"
 "laranode-postgres.sh${SEP}create-db${SEP}ok_db${SEP}UTF8';--${SEP}en_US.UTF-8"
 "laranode-postgres.sh${SEP}create-db${SEP}ok_db${SEP}UTF8${SEP}en US"
 "laranode-postgres.sh${SEP}create-db${SEP}template1${SEP}UTF8${SEP}en_US.UTF-8"
 "laranode-postgres.sh${SEP}drop-db${SEP}postgres"
 "laranode-postgres.sh${SEP}drop-db${SEP}template1"
 "laranode-postgres.sh${SEP}drop-db${SEP}a${NL}b"
 "laranode-postgres.sh${SEP}drop-user${SEP}postgres"
 "laranode-postgres.sh${SEP}drop-user${SEP}pg_monitor"
 "laranode-postgres.sh${SEP}drop-user${SEP}a${NL}b"
 "laranode-postgres.sh${SEP}update-user-password${SEP}postgres"
 "laranode-postgres.sh${SEP}create-user${SEP}postgres"
 "laranode-postgres.sh${SEP}create-user${SEP}pg_signal_backend"
 "laranode-postgres.sh${SEP}grant${SEP}postgres${SEP}ok_db"
 "laranode-postgres.sh${SEP}grant${SEP}ok_user${SEP}a;b"
 "laranode-postgres.sh${SEP}revoke${SEP}a b${SEP}ok_db"
 "laranode-ufw.sh${SEP}"
 "laranode-ufw.sh${SEP}status${SEP}extra"
 "laranode-ufw.sh${SEP}status-numbered${SEP}extra"
 "laranode-ufw.sh${SEP}show-added${SEP}extra"
 "laranode-ufw.sh${SEP}enable${SEP}extra"
 "laranode-ufw.sh${SEP}disable${SEP}extra"
 "laranode-ufw.sh${SEP}--force${SEP}reset"
 "laranode-ufw.sh${SEP}reset"
 "laranode-ufw.sh${SEP}allow"
 "laranode-ufw.sh${SEP}allow${SEP}--force${SEP}22"
 "laranode-ufw.sh${SEP}allow${SEP}22/tcp${SEP}--dry-run"
 "laranode-ufw.sh${SEP}allow${SEP}in${SEP}on${SEP}eth0${SEP}to${SEP}any"
 "laranode-ufw.sh${SEP}allow${SEP}from${SEP}1.2.3.4${SEP}to${SEP}any${SEP}port${SEP}22${SEP}comment${SEP}x"
 "laranode-ufw.sh${SEP}allow${SEP}OpenSSH${SEP}extra"
 "laranode-ufw.sh${SEP}allow${SEP}1${SEP}2${SEP}3${SEP}4${SEP}5${SEP}6${SEP}7${SEP}8${SEP}9${SEP}10${SEP}11${SEP}12${SEP}13${SEP}14${SEP}15${SEP}16${SEP}17"
 "laranode-ufw.sh${SEP}delete"
 "laranode-ufw.sh${SEP}delete${SEP}1${SEP}2"
 "laranode-ufw.sh${SEP}delete${SEP}99999"
 "laranode-ufw.sh${SEP}delete${SEP}bogus${SEP}22/tcp"
 "laranode-ufw.sh${SEP}delete${SEP}--force${SEP}allow${SEP}22"
 "laranode-ufw.sh${SEP}delete${SEP}allow${SEP}--force"
 "laranode-ufw.sh${SEP}delete${SEP}allow${SEP}22;id"
)

selected() { [ "${#ONLY[@]}" -eq 0 ] && return 0; local s; for s in "${ONLY[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

check_hostile() {   # label script runas args…
    local label="$1" script="$2" runas="$3"; shift 3
    local before after rc out
    id www-data >/dev/null 2>&1 || { bad "$label: www-data account vanished; restoring"; world_restore; }
    before=$(ln_snap)
    out=$(RUNAS="$runas" ln_run "$script" "$@" 2>&1); rc=$?
    after=$(ln_snap)
    n_host=$((n_host + 1))
    if [ "$rc" -eq 0 ]; then
        bad "$label: hostile call EXITED 0 -> $(printf '%q ' "$@")"; echo "      output: ${out:0:200}" >&2
    elif [ "$rc" -eq 124 ]; then
        bad "$label: hostile call timed out -> $(printf '%q ' "$@")"
    fi
    if [ "$before" != "$after" ]; then
        bad "$label: HOST STATE CHANGED by $(printf '%q ' "$@")"
        diff <(echo "$before") <(echo "$after") | head -6 >&2
        world_restore   # keep later cases meaningful
    fi
    if [ -e /tmp/pwned-template ] || ls /tmp/pwned* >/dev/null 2>&1; then
        bad "$label: attacker command executed as root (marker file)"; rm -f /tmp/pwned*
    fi
}

echo "== hostile arguments (script dir: $BIN) =="
fx_reset
world_save
for spec in "${SPECS[@]}"; do
    IFS='|' read -r name script runas kinds oracle <<<"$spec"
    selected "$script" || selected "$name" || continue
    [ -e "$BIN/$script" ] || { bad "$name: $BIN/$script does not exist"; continue; }
    read -ra K <<<"$kinds"
    valid=()
    for k in "${K[@]}"; do v="V_$k"; valid+=("${!v}"); done
    for i in "${!K[@]}"; do
        h="H_${K[$i]}[@]"
        for hv in "${!h}"; do
            args=("${valid[@]}"); args[$i]="$hv"
            # a delete/create hostile must not be the panel's own user etc.: fixtures are reset on change
            check_hostile "$name#$i(${K[$i]})" "$script" "$runas" "${args[@]}"
        done
    done
done
for vec in "${VECTORS[@]}"; do
    IFS="$SEP" read -ra A <<<"$vec"
    [ "${vec: -1}" = "$SEP" ] && A+=("")
    s="${A[0]}"; selected "$s" || continue
    [ -e "$BIN/$s" ] || { bad "$s does not exist"; continue; }
    check_hostile "$s(vector)" "$s" root "${A[@]:1}"
done

# every script the sudoers grants must be covered above (nothing silently skipped)
echo "== coverage: every sudo-granted laranode script has hostile cases =="
covered=" $(printf '%s\n' "${SPECS[@]}" | cut -d'|' -f2 | tr '\n' ' ') $(printf '%s\n' "${VECTORS[@]}" | cut -d"$SEP" -f1 | tr '\n' ' ') "
while read -r c; do
    s=$(basename "${c%% *}")
    case "$s" in laranode-*.sh) : ;; *) continue ;; esac
    case "$covered" in *" $s "*) : ;; *) bad "sudo-granted script has no hostile cases: $s" ;; esac
done < <(ln_sudo_rules)

if [ "${STUBS:-0}" = 1 ]; then
    echo "== positive cases (exact PHP arguments, stubbed system tools) =="
    for spec in "${SPECS[@]}"; do
        IFS='|' read -r name script runas kinds oracle <<<"$spec"
        selected "$script" || selected "$name" || continue
        world_restore
        read -ra K <<<"$kinds"
        valid=(); for k in "${K[@]}"; do v="V_$k"; valid+=("${!v}"); done
        ALICE_HASH=$(getent shadow alice_ln | cut -d: -f2); export ALICE_HASH
        out=$(RUNAS="$runas" ln_run "$script" "${valid[@]}" 2>&1); rc=$?
        n_pos=$((n_pos + 1))
        case " ${POSRC[$name]:-0} " in *" $rc "*) : ;; *) bad "$name: valid PHP-shaped call REFUSED (rc=$rc): ${out:0:300}"; continue ;; esac
        if ! eval "$oracle"; then bad "$name: valid call exited 0 but the expected effect is missing"; continue; fi
        echo "  ok: $name"
    done
fi

echo "hostile cases run: $n_host, positive cases run: $n_pos"
if [ "$fail" = 0 ]; then echo "HOSTILE: PASS"; else echo "HOSTILE: FAIL" >&2; fi
exit "$fail"
