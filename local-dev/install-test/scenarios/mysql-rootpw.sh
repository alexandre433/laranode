#!/usr/bin/env bash
# Scenario: MySQL already installed with an existing root password.
# Installer must NOT rotate that password; must create the laranode DB user instead.
# EXPECTED: FAIL until Task 4 (phase_database root-password guard) is implemented.
set -uo pipefail
SCENARIO=mysql-rootpw
# Pre-install MySQL and set a root password so auth_socket is NOT the only path.
PRESETUP="
export DEBIAN_FRONTEND=noninteractive
apt-get install -y mysql-server
systemctl start mysql
mysql -u root -e \"ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'S3cr3tR00t'; FLUSH PRIVILEGES;\"
"
# Pass the known root password so the installer can authenticate without rotating it.
INSTALLER_ENV="LARANODE_UNATTENDED=1 LARANODE_MYSQL_ROOT_PASSWORD=S3cr3tR00t"
EXPECT_PORT=80
EXPECT_ENGINE=mysql
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
run_scenario
