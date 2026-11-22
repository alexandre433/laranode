#!/usr/bin/env bash
# Fast sudo-hardening harness. Runs INSIDE a throwaway debian:13 container as root
# (see run-fast.sh). Real: useradd/chpasswd/sudo/tar/chown. Stubbed (log to
# /var/log/laranode-stub.log): systemctl, apache, apt, mysql, certbot, crontab ...
#
# Lays the panel out exactly like the installer does, then runs the perms and the
# hostile-argument checks. Layout comes from the installer under test:
#   * installer has _install_privileged_scripts -> use the installer's functions (fixed layout)
#   * otherwise                                 -> replicate the legacy phase_services lines
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SRC:-/src}"
PANEL=/home/laranode_ln/panel
STUB=/usr/local/sbin
LOG=/var/log/laranode-stub.log

echo "== provisioning (fast harness) =="
export DEBIAN_FRONTEND=noninteractive
command -v sudo >/dev/null || { apt-get update -qq && apt-get install -y -qq sudo >/dev/null; }

mkdir -p /var/spool/stubcron && chmod 1777 /var/spool/stubcron
: > "$LOG"; chmod 666 "$LOG"   # www-data runs some stubs (mysql restore/backup, cron)
mkstub() {  # name [body]
    printf '#!/bin/sh\necho "%s $*" >> %s\n%s\nexit 0\n' "$1" "$LOG" "${2:-}" > "$STUB/$1"; chmod 755 "$STUB/$1"
}
for s in systemctl apache2ctl apachectl a2ensite a2dissite a2enmod a2dismod apt-get apt add-apt-repository \
         certbot ufw update-alternatives php-fpm8.3 php-fpm8.4 service sar; do mkstub "$s"; done
mkstub mysql 'cat > /tmp/mysql-stdin-last 2>/dev/null || true'
mkstub mysqldump 'echo "-- dump"'
mkstub pg_dump 'echo "-- dump"'
mkstub psql
mkstub curl
# crontab: keeps per-user tables so cron.sh round-trips
cat > "$STUB/crontab" <<'CT'
#!/bin/sh
echo "crontab $*" >> /var/log/laranode-stub.log
mkdir -p /var/spool/stubcron
u=$(id -un); [ "$1" = -u ] && { u=$2; shift 2; }
[ "$1" = -- ] && shift
case "$1" in
  -l) [ -f "/var/spool/stubcron/$u" ] && cat "/var/spool/stubcron/$u" || { echo "no crontab for $u" >&2; exit 1; } ;;
  -r) rm -f "/var/spool/stubcron/$u" ;;
  *)  if [ -n "$1" ] && [ "$1" != - ]; then cp "$1" "/var/spool/stubcron/$u"; else cat > "/var/spool/stubcron/$u"; fi ;;
esac
CT
chmod 755 "$STUB/crontab"
mkdir -p /run/php /var/www /etc/mysql /etc/laranode

# accounts the panel owns / the host already has
getent passwd postgres >/dev/null || useradd -r -m -s /bin/sh postgres   # `sudo -u postgres psql` reaches the psql stub
useradd -m -s /bin/bash laranode_ln 2>/dev/null || true
usermod -aG laranode_ln www-data
chmod 750 /home/laranode_ln

# the panel tree, as `git clone` leaves it
mkdir -p "$PANEL"
( cd "$SRC" && tar --exclude=.git --exclude=node_modules --exclude=vendor --exclude=public/build -cf - . ) | tar -xf - -C "$PANEL"
printf 'APP_KEY=base64:x\nDB_PASSWORD=secret\n' > "$PANEL/.env"
mkdir -p "$PANEL/storage" "$PANEL/bootstrap/cache"
: > "$PANEL/bootstrap/cache/packages.php"   # a generated cache file, as composer leaves it

INSTALLER="$PANEL/laranode-scripts/bin/laranode-installer.sh"
if grep -q '^_install_privileged_scripts()' "$INSTALLER"; then
    echo "layout: FIXED (installer functions)"
    export LARANODE_INSTALLER_TEST=1
    # shellcheck disable=SC1090
    ( . "$INSTALLER" && PANEL_PATH="$PANEL" && _install_privileged_scripts && _install_sudoers && _settle_permissions ) \
        || { echo "FAIL: installer layout functions failed" >&2; exit 1; }
else
    echo "layout: LEGACY (replicating installer phase_app/phase_services)"
    for drop in laranode-panel laranode-cron laranode-runtimes laranode-sleep; do
        install -m 440 "$PANEL/laranode-scripts/etc/sudoers.d/$drop" "/etc/sudoers.d/$drop"
    done
    mkdir -p /home/laranode_ln/logs
    chown -R laranode_ln:laranode_ln /home/laranode_ln
    find /home/laranode_ln -type d -exec chmod 770 {} \;
    find /home/laranode_ln -type f -exec chmod 660 {} \;
    find /home/laranode_ln/panel/laranode-scripts/bin -type f -exec chmod 100 {} \;
fi
visudo -c >/dev/null || { echo "FAIL: sudoers invalid" >&2; exit 1; }
sudo -n -l -U www-data | sed -n 1,12p

rc=0
bash "$HERE/assert-perms.sh"   || rc=1
PANEL="$PANEL" bash "$HERE/assert-sync.sh" || rc=1
INSTALLER="$INSTALLER" bash "$HERE/assert-installer-env.sh" || rc=1
STUBS=1 bash "$HERE/assert-hostile.sh" "$@" || rc=1
echo "fast harness exit: $rc"
exit $rc
