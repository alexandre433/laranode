#!/bin/bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # before ANY command runs: dirname below must not come from the caller's PATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# Usage: laranode-user-manager.sh {create|delete} username {allow shell/ssh login: yes|no} {password}
ln_argc 2 4 "$0 {create|delete} username {allow shell/ssh login (optional): yes|no} {password (required if allow shell/ssh login is yes)}"
ln_enum "$1" ACTION create delete
ALLOW_LOGIN=no
[ $# -ge 3 ] && ln_enum "$3" ALLOW_LOGIN yes no
PASSWORD=
# an empty fourth operand means "no password" (the panel used to send null, which Symfony Process
# turns into ""); a non-empty one is always validated
if [ $# -ge 4 ] && [ -n "$4" ]; then ln_secret "$4" PASSWORD; fi

# Ensure password is provided if allow shell/ssh login is "yes"
if [ "$ALLOW_LOGIN" = "yes" ] && [ -z "$PASSWORD" ]; then
  echo "Error: Password is required when allow shell/ssh login is 'yes'." >&2
  exit 1
fi

# Function to create a user
create_user() {
  ln_newuser "$1" USERNAME
  # Check if the user already exists
  if id "$USERNAME" &>/dev/null; then
    echo "User $USERNAME already exists."
    exit 1
  fi

  # Create the user (a login shell only when asked for)
  if [ "$ALLOW_LOGIN" = "yes" ]; then
    # -s explicit: useradd would fall back to /bin/sh (upstream crivion/laranode fe77fd0)
    useradd -m -s /bin/bash -- "$USERNAME"
    # password goes to chpasswd on stdin, one validated line
    printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chpasswd
    echo "User $USERNAME created successfully with SSH login allowed."
  else
    useradd -m -s /usr/sbin/nologin -- "$USERNAME"
    echo "User $USERNAME created successfully with no SSH login."
  fi

  chmod 770 "/home/$USERNAME"

  # the panel web user (www-data, or laranode_web on Proxmox: lib/validate.sh) joins this user's group
  usermod -aG "$USERNAME" "$LN_WEB_USER"

  # create /home/{user}/logs directory
  mkdir -p "/home/$USERNAME/logs"
  chown "$USERNAME:$USERNAME" "/home/$USERNAME/logs"
  chmod 770 "/home/$USERNAME/logs"

  # create /home/{user}/domains directory
  mkdir -p "/home/$USERNAME/domains"
  chown "$USERNAME:$USERNAME" "/home/$USERNAME/domains"
  chmod 770 "/home/$USERNAME/domains"
}

# Function to delete a user
delete_user() {
  ln_sysuser "$1" USERNAME   # existing, uid >= 1000, home /home/<user>, never the panel user

  # remove the panel web user from this user's group
  gpasswd -d "$LN_WEB_USER" "$USERNAME" >/dev/null 2>&1 || true   # gpasswd ships with passwd; deluser needs the adduser package

  # Delete the user and their home directory
  userdel -r -- "$USERNAME"

  echo "User $USERNAME deleted successfully."
}

case $ACTION in
  create) create_user "$2" ;;
  delete) delete_user "$2" ;;
esac
