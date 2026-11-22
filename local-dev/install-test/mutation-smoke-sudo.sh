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
# Not listed (equivalent mutants: a second, independent guard makes the revert unobservable):
#   ln_sysuser first regex, ln_newuser dash/panel-user (useradd refuses), ln_install_file symlink
#   (needs a symlink in a root-only dir), ln_siteroot symlink, restore-files user (BASE path check),
#   file-permissions "..", symlink (fd prefix check), sync script owner (settle chown -R root)
#   r3 sync: the directory LISTING made as root instead of the panel user (every read is still
#   made as the panel user, so a listing of a swapped-in /etc only yields names that then fail
#   to read; the harness cannot tell it apart, and nothing root-only can leak through it)
#   r3 sync: the `test -f` before each read (a FIFO/dir fails the read itself, bounded by `timeout`)
#   r2 sync allowlist: a trailing backslash, a CR, a NUL byte (each line is also refused by the
#   per-line grammar, or is inert inside a comment: defense in depth), the staged-copy symlink check
#   (the source-tree symlink scan refuses first; the check only closes a race), _prepare_panel_tree
#   chmod 750 on bootstrap/cache (the settle step re-chmods the whole tree right after)
# --- shared guards ---------------------------------------------------------------------
mut $L 'ln_secret accepts a newline (chpasswd line injection)' \
    '    [[ $v == *$'"'"'\n'"'"'* || $v == *$'"'"'\r'"'"'* ]] && ln_die "invalid password"' ''
mut $L 'ln_secret accepts an empty or huge secret' \
    '[ -n "$v" ] && [ "${#v}" -le 256 ] || ln_die "invalid password"' ':'
mut $L 'ln_sysuser accepts system accounts (uid check dropped)' \
    '[[ $uid =~ ^[0-9]+$ ]] && [ "$uid" -ge 1000 ] || ln_die' 'true || ln_die'
mut $L 'ln_sysuser accepts the panel user' \
    '[ "$v" != laranode_ln ] || ln_die "refusing to act on the panel user"' ':'
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
mut $L 'ln_need_root dropped' '[ "$(id -u)" -eq 0 ] || ln_die "must run as root"' ':'
mut $L 'ln_ident accepts any text' '[[ $1 =~ ^[A-Za-z0-9_]{1,64}$ ]] || ln_die "invalid identifier"' ':'
# --- per-script --------------------------------------------------------------------------
mut bin/laranode-update-sh-password.sh 'update-sh-password: user not validated' 'ln_sysuser "$1" SYSTEM_USER' 'SYSTEM_USER="$1"'
mut bin/laranode-update-sh-password.sh 'update-sh-password: password not validated' 'ln_secret "$2" NEW_PASSWORD' 'NEW_PASSWORD="$2"'
mut bin/laranode-user-manager.sh 'user-manager: password not validated' 'ln_secret "$4" PASSWORD' 'PASSWORD="$4"'
mut bin/laranode-user-manager.sh 'user-manager: delete accepts any existing user' 'ln_sysuser "$1" USERNAME ' 'USERNAME="$1" #'
mut bin/laranode-create-directory.sh 'create-directory: user not validated' 'ln_sysuser "$2" SYSTEM_USER' 'SYSTEM_USER="$2"'
mut bin/laranode-postgres.sh 'postgres: administrative roles allowed' 'postgres|pg_*|replicator|rdsadmin|root) die "Refusing reserved role."' '__never__) die "Refusing reserved role."'
mut bin/laranode-postgres.sh 'postgres: system databases allowed' 'postgres|template0|template1) die "Refusing system database."' '__never__) die "Refusing system database."'
mut bin/laranode-ufw.sh 'ufw: rule tokens not validated' 'ln_die "invalid rule token"' ':'
mut bin/laranode-ufw.sh 'ufw: unknown sub-command accepted' '*) ln_die "unknown command" ;;' '*) exec ufw "$CMD" "$@" ;;'
mut bin/laranode-ufw.sh 'ufw: delete accepts any first word' 'case "$1" in allow|deny) : ;; *) ln_die "invalid rule" ;; esac' ':'
mut bin/laranode-ufw.sh 'ufw: extra arguments accepted on status' 'status)          ln_argc 1 1 "$0 status";           exec ufw status ;;' 'status)          exec ufw status "$@" ;;'
mut etc/sudoers.d/laranode-ufw 'sudoers: ufw binary grant back' '' 'www-data ALL=(ALL) NOPASSWD: /usr/sbin/ufw'
# --- layout / permissions / sudoers -----------------------------------------------------
mut bin/laranode-installer.sh 'installer: panel dirs left group-writable' 'find "$h" -type d -exec chmod 750 {} +' 'find "$h" -type d -exec chmod 770 {} +'
mut bin/laranode-installer.sh 'installer: panel files group-writable' 'find "$h" -type f -exec chmod 640 {} +' 'find "$h" -type f -exec chmod 660 {} +'
mut bin/laranode-installer.sh 'installer: .env group-writable' '[ -f "$p/.env" ] && _as_panel_user chmod 640 "$p/.env"' '[ -f "$p/.env" ] && _as_panel_user chmod 660 "$p/.env"'
mut bin/laranode-sync-scripts.sh 'sync: script copy group-writable' 'read_src "$SRC/bin/$b" "$STAGE/bin/$b" 755' 'read_src "$SRC/bin/$b" "$STAGE/bin/$b" 775'
mut bin/laranode-sync-scripts.sh 'sync: lib copy world-writable' 'read_src "$SRC/lib/$b" "$STAGE/lib/$b" 644' 'read_src "$SRC/lib/$b" "$STAGE/lib/$b" 666'
# --- r3 F1: the checkout is read AS the panel account, never as root -------------------------
mut bin/laranode-sync-scripts.sh 'sync: every read/list runs as root (parent-dir swap leaks root-only files)'     'run_as_panel() { timeout 30 runuser -u "$PANEL_USER" -- "$@"; }' 'run_as_panel() { timeout 30 "$@"; }'
mut bin/laranode-sync-scripts.sh 'sync: file bytes read as root'     'run_as_panel cat -- "$1" |' 'cat -- "$1" |'
mut bin/laranode-sync-scripts.sh 'sync: file size cap dropped'     '| head -c 2097152 > "$2"' '> "$2"'
mut bin/laranode-sync-scripts.sh 'sync: hostile lib/template names accepted'     'safe_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }' 'safe_name() { true; }'
mut etc/sudoers.d/laranode-panel 'sudoers: rm glob grant back' '' 'www-data ALL=(ALL) NOPASSWD: /usr/bin/rm /etc/apache2/sites-available/*.conf'
mut etc/sudoers.d/laranode-panel 'sudoers: script from the writable panel tree' '' 'www-data ALL=(ALL) NOPASSWD: /home/laranode_ln/panel/laranode-scripts/bin/laranode-cron.sh'
mut etc/sudoers.d/laranode-panel 'sudoers: any-args a2dissite back' '' 'www-data ALL=(ALL) NOPASSWD: /usr/sbin/a2dissite'
mut etc/sudoers.d/laranode-panel 'sudoers: wildcard over the script directory' '' 'www-data ALL=(ALL) NOPASSWD: /usr/local/lib/laranode/bin/*'
# --- r3 F2: the four templates the installer installs as root are judged line by line --------
mut bin/laranode-sync-scripts.sh 'sync: unit template may run as any User=' \
    "'^User=laranode_ln\$'" "'^User=.*\$'"
mut bin/laranode-sync-scripts.sh 'sync: queue unit may run any ExecStart / ExecStartPre' \
    "'^ExecStart=/usr/bin/php8\\.4 /home/laranode_ln/panel/artisan queue:work\$'" "'^Exec.*\$'"
mut bin/laranode-sync-scripts.sh 'sync: cron template may run any command for any user' \
    "'^\\* \\* \\* \\* \\* __PANEL_USER__ __PHP__ __PANEL_PATH__/artisan schedule:run >> /dev/null 2>&1\$'" "'^\\* \\* \\* \\* \\* .*\$'"
mut bin/laranode-sync-scripts.sh 'sync: panel vhost may carry any indented directive (LoadModule, Include)' \
    "'^    ErrorLog \\\$\\{APACHE_LOG_DIR\\}/laranode-error\\.log\$'" "'^ +.*\$'"
mut bin/laranode-sync-scripts.sh 'sync: a template line matching no pattern is accepted' \
    '[ "$hit" = 1 ] || { echo "laranode-sync-scripts: ${f##*/}: line not allowed: $line" >&2; return 1; }' ':'
mut bin/laranode-sync-scripts.sh 'sync: a refused unit template does not stop the sync' \
    '|| die "templates/laranode-reverb.service grants more than the shipped unit"' '|| :'
mut bin/laranode-sync-scripts.sh 'sync: a refused cron template does not stop the sync' \
    '|| die "templates/laranode-schedule.cron runs more than the scheduler"' '|| :'
# --- r3 F3: a root script never runs a command chosen by the caller's PATH -------------------
mut bin/laranode-php-list.sh 'php-list: dirname resolved through the caller PATH' \
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # before ANY command runs" ': # before ANY command runs'
mut bin/laranode-cron.sh 'cron: dirname resolved through the caller PATH' \
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # before ANY command runs" ': # before ANY command runs'
mut bin/laranode-sleep.sh 'sleep: caller PATH trusted' \
    'if [ "${LARANODE_SLEEP_TEST:-}" != 1 ] || [ -n "${SUDO_UID:-}" ]; then' 'if false; then'
# --- r2: sync-scripts sudoers allowlist (each bypass of review r1 + the new parse rules) ---
S=bin/laranode-sync-scripts.sh
mut $S 'sync: any line not matching a grant shape passes (NOPASSWD: ALL)' \
    $'    done\n    return 1\n}\nsudoers_file_ok()' $'    done\n    return 0\n}\nsudoers_file_ok()'
mut $S 'sync: comma list after the script allowed' \
    '[[ $rest =~ ^laranode-[a-z0-9-]+\.sh(\ \"\")?$ ]] && return 0' '[[ $rest =~ ^laranode- ]] && return 0'
mut $S 'sync: Defaults line may carry anything after the script' \
    '[[ $rest =~ ^laranode-[a-z0-9-]+\.sh\ \!requiretty$ ]] && return 0' '[[ $rest =~ ^laranode- ]] && return 0'
mut $S 'sync: #include / #includedir comment allowed' \
    '[[ $l =~ ^#[[:space:]]*(include|includedir)([[:space:]]|$) ]] && return 1' ':'
mut $S 'sync: unterminated last line not refused' \
    '[ ! -s "$f" ] || [ -z "$(tail -c1 "$f")" ] || return 1' ':'
mut $S 'sync: drop-in name not checked' \
    '[[ $d =~ ^laranode-[a-z0-9-]+$ ]] || die "unexpected sudoers drop-in name: $d"' ':'
mut $S 'sync: allowlist never applied to the staged drop-in' \
    'sudoers_file_ok "$STAGE/etc/sudoers.d/$d" || die "sudoers drop-in $d grants more than a laranode script inside $DEST/bin"' ':'
# --- r2: account creation without SSH, php-uninstall, FIFO, bootstrap/cache -------------
mut bin/laranode-user-manager.sh 'user-manager: empty password operand refused (ssh-off regression)' \
    'if [ $# -ge 4 ] && [ -n "$4" ]; then' 'if [ $# -ge 4 ]; then'
mut bin/laranode-php-uninstall.sh 'php-uninstall: removes the php that runs the panel' \
    '[ "$PHP_VERSION" != 8.4 ] || ln_die "php8.4 runs the panel and cannot be uninstalled from it"' ':'
mut $L 'ln_open9_under opens a FIFO (root hangs for ever)' \
    '{ [ -f "$1" ] || [ -d "$1" ]; } && [ ! -p "$1" ] || ln_die "not a regular file or directory"' ':'
mut bin/laranode-installer.sh 'installer: settle step makes bootstrap/cache web-writable' \
    '  _as_panel_user chmod 770 "$h/logs"' '  _as_panel_user chmod 770 "$h/logs" "$p/bootstrap/cache"'

# --- r4: the panel .env is seeded and edited AS the panel user (assert-installer-env.sh) -------
mut bin/laranode-installer.sh 'installer: _seed_env copies .env.example as root (follows a planted link)' \
    '  _as_panel_user bash -c "$(declare -f _seed_env_inner); cd /; _seed_env_inner \"\$@\"" _ "${PANEL_PATH}/.env.example" "$env"' \
    '  ( umask 027; cp "${PANEL_PATH}/.env.example" "$env" ); chmod 640 "$env"'
mut bin/laranode-installer.sh 'installer: env_set edits .env as root (follows a planted link)' \
    '  printf '"'"'%s\n'"'"' "$v" | _as_panel_user bash -c "$(declare -f _env_set_inner)' \
    '  printf '"'"'%s\n'"'"' "$v" | bash -c "$(declare -f _env_set_inner)'

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
        content=${content//"$old"/"$new"}
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
