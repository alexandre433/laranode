#!/usr/bin/env bash
# Mutation smoke for the sudo hardening: re-introduce each guard's bug into a COPY of
# laranode-scripts/ and require the fast harness (perms + hostile arguments) to go RED.
# A guard whose test cannot fail is not a guard. Never touches the real tree.
#
#   bash local-dev/install-test/mutation-smoke-sudo.sh            # all mutations, 4 in parallel
#   JOBS=2 bash local-dev/install-test/mutation-smoke-sudo.sh     # fewer parallel containers
#   bash local-dev/install-test/mutation-smoke-sudo.sh "ln_secret"  # only names containing the text
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
JOBS="${JOBS:-4}"
FILTER="${1:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
case "$(uname -s)" in MINGW*|MSYS*) win() { (cd "$1" && pwd -W); }; export MSYS_NO_PATHCONV=1 ;; *) win() { echo "$1"; } ;; esac

# Each mutation reverts ONE guard by replacing an exact (literal) text in a copy.
#   mut <file under laranode-scripts/> <name> <exact text> <replacement>
# An empty exact text appends the replacement as a new last line (sudoers grants).
MUT_FILE=(); MUT_NAME=(); MUT_OLD=(); MUT_NEW=()
mut() { MUT_FILE+=("$1"); MUT_NAME+=("$2"); MUT_OLD+=("$3"); MUT_NEW+=("$4"); }
L=lib/validate.sh
# --- shared guards ---------------------------------------------------------------------
mut $L 'ln_secret accepts a newline (chpasswd line injection)' \
    '    [[ $v == *$'"'"'\n'"'"'* || $v == *$'"'"'\r'"'"'* ]] && ln_die "invalid password"' ''
mut $L 'ln_secret accepts an empty or huge secret' \
    '[ -n "$v" ] && [ "${#v}" -le 256 ] || ln_die "invalid password"' ':'
mut $L 'ln_sysuser accepts system accounts (uid check dropped)' \
    '[[ $uid =~ ^[0-9]+$ ]] && [ "$uid" -ge 1000 ] || ln_die' 'true || ln_die'
mut $L 'ln_sysuser accepts the panel user' \
    '[ "$v" != laranode_ln ] || ln_die "refusing to act on the panel user"' ':'
mut $L 'ln_sysuser accepts a shape-bad name (first regex dropped)' \
    '[[ $v =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || ln_die "invalid user name"' ':'
mut $L "ln_sysuser trusts the account's home directory" \
    '[ "$home" = "/home/$v" ] || ln_die' 'true || ln_die'
mut $L 'ln_domain accepts anything' \
    '[ "${#v}" -le 253 ] && [[ $v =~ $re ]] || ln_die "invalid domain"' ':'
mut $L 'ln_docroot accepts ..' \
    '[[ $v =~ (^|/)\.\.(/|$) ]] && ln_die "invalid document root"' ':'
mut $L 'ln_port accepts any port' \
    '[[ $v =~ ^[0-9]{4}$ ]] && [ "$v" -ge 9100 ] && [ "$v" -le 9499 ] || ln_die' 'true || ln_die'
mut $L 'ln_dbuser accepts root' 'root|mysql|mariadb' 'zzzz|mysql|mariadb'
mut $L 'ln_template accepts any real file' '[ "$real" = "$LN_TPL_DIR/$n" ] &&' 'true &&'
mut $L 'ln_template_dir accepts any directory' '[ "$real" = "$LN_TPL_DIR" ] || ln_die' 'true || ln_die'
mut $L 'ln_tmpfile name shape not enforced' '[[ $v =~ $re ]] || ln_die "temporary file name not allowed"' ':'
mut $L 'path-under-prefix checks dropped' '*) ln_die "path outside $2" ;;' '*) : ;;'
mut $L 'ln_install_file writes through a symlink' '[ ! -L "$dest" ] || ln_die' 'true || ln_die'
mut $L 'ln_siteroot accepts a symlinked site root' '[ "$real" = "/home/$1/domains/$2" ] || ln_die' 'true || ln_die'
mut $L 'ln_need_root dropped' '[ "$(id -u)" -eq 0 ] || ln_die "must run as root"' ':'
mut $L 'ln_newuser accepts a leading dash' '[[ $v != -* ]] || ln_die "invalid user name"' ':'
mut $L 'ln_newuser accepts the panel user name' '[ "$s" != laranode_ln ] || ln_die "reserved user name"' ':'
mut $L 'ln_ident accepts any text' '[[ $1 =~ ^[A-Za-z0-9_]{1,64}$ ]] || ln_die "invalid identifier"' ':'
# --- per-script --------------------------------------------------------------------------
mut bin/laranode-update-sh-password.sh 'update-sh-password: user not validated' 'ln_sysuser "$1" SYSTEM_USER' 'SYSTEM_USER="$1"'
mut bin/laranode-update-sh-password.sh 'update-sh-password: password not validated' 'ln_secret "$2" NEW_PASSWORD' 'NEW_PASSWORD="$2"'
mut bin/laranode-user-manager.sh 'user-manager: password not validated' 'ln_secret "$4" PASSWORD' 'PASSWORD="$4"'
mut bin/laranode-user-manager.sh 'user-manager: delete accepts any existing user' 'ln_sysuser "$1" USERNAME ' 'USERNAME="$1" #'
mut bin/laranode-restore-files.sh 'restore-files: user not validated' 'ln_sysuser "$3" SYS_USER' 'SYS_USER="$3"'
mut bin/laranode-create-directory.sh 'create-directory: user not validated' 'ln_sysuser "$2" SYSTEM_USER' 'SYSTEM_USER="$2"'
mut bin/laranode-postgres.sh 'postgres: administrative roles allowed' 'postgres|pg_*|replicator|rdsadmin|root) die "Refusing reserved role."' '__never__) die "Refusing reserved role."'
mut bin/laranode-postgres.sh 'postgres: system databases allowed' 'postgres|template0|template1) die "Refusing system database."' '__never__) die "Refusing system database."'
mut bin/laranode-ufw.sh 'ufw: rule tokens not validated' 'ln_die "invalid rule token"' ':'
mut bin/laranode-ufw.sh 'ufw: unknown sub-command accepted' '*) ln_die "unknown command" ;;' '*) exec ufw "$CMD" "$@" ;;'
mut bin/laranode-ufw.sh 'ufw: delete accepts any first word' 'case "$1" in allow|deny) : ;; *) ln_die "invalid rule" ;; esac' ':'
mut bin/laranode-ufw.sh 'ufw: extra arguments accepted on status' 'status)          ln_argc 1 1 "$0 status";           exec ufw status ;;' 'status)          exec ufw status "$@" ;;'
mut etc/sudoers.d/laranode-ufw 'sudoers: ufw binary grant back' '' 'www-data ALL=(ALL) NOPASSWD: /usr/sbin/ufw'
mut bin/laranode-file-permissions.sh 'file-permissions: symlink target allowed' '[ ! -L "$TARGET_PATH" ] || ln_die "refusing a symlink"' ':'
mut bin/laranode-file-permissions.sh 'file-permissions: ".." allowed' '[[ $REL =~ (^|/)\.\.(/|$) ]] && ln_die "invalid path"' ':'
# --- layout / permissions / sudoers -----------------------------------------------------
mut bin/laranode-installer.sh 'installer: panel dirs left group-writable' 'find "$h" -type d -exec chmod 750 {} +' 'find "$h" -type d -exec chmod 770 {} +'
mut bin/laranode-installer.sh 'installer: panel files group-writable' 'find "$h" -type f -exec chmod 640 {} +' 'find "$h" -type f -exec chmod 660 {} +'
mut bin/laranode-installer.sh 'installer: .env group-writable' '[ -f "$p/.env" ] && chmod 640 "$p/.env"' '[ -f "$p/.env" ] && chmod 660 "$p/.env"'
mut bin/laranode-sync-scripts.sh 'sync: script copy owned by www-data' '-o root -g root -m 755 -- "$f" "$STAGE/bin/$b"' '-o www-data -g root -m 755 -- "$f" "$STAGE/bin/$b"'
mut bin/laranode-sync-scripts.sh 'sync: script copy group-writable' '-o root -g root -m 755 -- "$f" "$STAGE/bin/$b"' '-o root -g root -m 775 -- "$f" "$STAGE/bin/$b"'
mut bin/laranode-sync-scripts.sh 'sync: lib copy world-writable' '-o root -g root -m 644 -- "$f" "$STAGE/lib/' '-o root -g root -m 666 -- "$f" "$STAGE/lib/'
mut etc/sudoers.d/laranode-panel 'sudoers: rm glob grant back' '' 'www-data ALL=(ALL) NOPASSWD: /usr/bin/rm /etc/apache2/sites-available/*.conf'
mut etc/sudoers.d/laranode-panel 'sudoers: script from the writable panel tree' '' 'www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-cron.sh'
mut etc/sudoers.d/laranode-panel 'sudoers: any-args a2dissite back' '' 'www-data ALL=(ALL) NOPASSWD: /usr/sbin/a2dissite'
mut etc/sudoers.d/laranode-panel 'sudoers: wildcard over the script directory' '' 'www-data ALL=(ALL) NOPASSWD: /usr/local/lib/laranode/bin/*'

IMG=laranode-sudo-fast
docker build -q -t "$IMG" - >/dev/null <<'DF'
FROM debian:13
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends sudo util-linux passwd tar gzip coreutils findutils procps ca-certificates >/dev/null && rm -rf /var/lib/apt/lists/*
DF

REPO_MNT="$(win "$REPO")"
run_one() {   # idx
    local idx=$1 file name old new dir tgt content
    file=${MUT_FILE[$1]}; name=${MUT_NAME[$1]}; old=${MUT_OLD[$1]}; new=${MUT_NEW[$1]}
    dir="$WORK/m$idx"; mkdir -p "$dir"
    cp -r "$REPO/laranode-scripts" "$dir/laranode-scripts"
    tgt="$dir/laranode-scripts/$file"
    content=$(cat "$tgt"; echo x); content=${content%x}
    if [ -z "$old" ]; then
        content+="$new"$'\n'
    elif [[ $content == *"$old"* ]]; then
        content=${content/"$old"/"$new"}
    else
        echo "NOAPPLY|$name" >"$dir/result"; return
    fi
    printf '%s' "$content" >"$tgt"
    docker run --rm -e SRC=/mut -v "$REPO_MNT":/src:ro -v "$(win "$dir")":/mut:ro "$IMG" \
        bash /src/local-dev/install-test/sudo-hardening/fast.sh >"$dir/out.log" 2>&1
    if [ $? -eq 0 ]; then echo "SURVIVED|$name" >"$dir/result"; else echo "killed|$name" >"$dir/result"; fi
}

# sanity: the unmutated copy must be GREEN, or "killed" means nothing
echo "== control (unmutated) =="
mkdir -p "$WORK/ctl"; cp -r "$REPO/laranode-scripts" "$WORK/ctl/laranode-scripts"
if ! docker run --rm -e SRC=/mut -v "$REPO_MNT":/src:ro -v "$(win "$WORK/ctl")":/mut:ro "$IMG" \
        bash /src/local-dev/install-test/sudo-hardening/fast.sh >"$WORK/ctl.log" 2>&1; then
    tail -30 "$WORK/ctl.log"; echo "control run is RED: fix the harness before mutating" >&2; exit 2
fi
echo "control GREEN"

idxs=()
for i in "${!MUT_NAME[@]}"; do
    n=${MUT_NAME[$i]}
    [ -z "$FILTER" ] || [[ $n == *"$FILTER"* ]] || continue
    idxs+=("$i")
done
running=0
for i in "${idxs[@]}"; do
    run_one "$i" &
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then wait -n; running=$((running - 1)); fi
done
wait

bad=0
for i in "${idxs[@]}"; do
    r=$(cat "$WORK/m$i/result" 2>/dev/null || echo "MISSING|?")
    case "$r" in
        killed*)   echo "  KILLED:   ${r#*|}" ;;
        SURVIVED*) echo "  SURVIVED: ${r#*|}   <-- no test noticed" ; bad=1 ;;
        NOAPPLY*)  echo "  NOAPPLY:  ${r#*|}   <-- exact text not found (stale mutation)"; bad=1 ;;
        *)         echo "  ERROR:    $r"; bad=1 ;;
    esac
done
echo "mutations run: ${#idxs[@]}"
[ "$bad" = 0 ] && echo "ALL KILLED" || echo "SOME MUTATIONS SURVIVED"
exit "$bad"
