#!/usr/bin/env bash
# Scenario: mysql-rootpw
#
# Pre-installs mysql-server and switches root from auth_socket to
# caching_sha2_password with a known password — simulating a dedicated host
# that already runs MySQL with a root password set.
# Runs the installer passing LARANODE_MYSQL_ROOT_PASSWORD.
# Extra assertions (beyond run_scenario's standard checks):
#   - root password is UNCHANGED after the install
#   - the laranode database exists
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib.sh"

SCENARIO="mysql-rootpw"
EXPECT_PORT=80
EXPECT_ENGINE="mysql"

# Run inside the container BEFORE the installer.
# Installs mysql-server and sets a known root password, disabling auth_socket.
PRESETUP=$(cat <<'BASH'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq mysql-server
  systemctl enable --now mysql
  mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY 'KnownRootPwd_t3st'; FLUSH PRIVILEGES;"
BASH
)

# Passed as a prefix to the installer invocation by run_scenario.
INSTALLER_ENV="LARANODE_MYSQL_ROOT_PASSWORD=KnownRootPwd_t3st LARANODE_UNATTENDED=1"

# Scenario-specific post-assertions — invoked by the POST_ASSERT_FN hook in
# lib.sh with the container name as $1.
post_assert() {
  local cname="$1"
  local failed=0

  # The original root password must still authenticate.
  # If the installer rotated it, this will fail.
  local auth_out
  auth_out=$(docker exec "${cname}" \
    mysql -u root -p'KnownRootPwd_t3st' --connect-timeout=5 \
    -e 'SELECT "root-auth-ok"' 2>/dev/null || true)
  if echo "${auth_out}" | grep -q 'root-auth-ok'; then
    printf "   %-30s %s\n" "root pw unchanged" "ok"
  else
    printf "   %-30s %s\n" "root pw unchanged" "FAIL — installer rotated the root password"
    failed=1
  fi

  # The laranode database must have been created.
  local db_count
  db_count=$(docker exec "${cname}" \
    mysql -u root -p'KnownRootPwd_t3st' --connect-timeout=5 \
    -e "SHOW DATABASES LIKE 'laranode';" 2>/dev/null \
    | grep -c laranode || true)
  if [ "${db_count:-0}" -ge 1 ]; then
    printf "   %-30s %s\n" "laranode DB exists" "ok"
  else
    printf "   %-30s %s\n" "laranode DB exists" "FAIL — database not found after install"
    failed=1
  fi

  return "${failed}"
}
POST_ASSERT_FN=post_assert

run_scenario
