#!/usr/bin/env bash
# Scenario: nginx already running on :80 → installer must put panel on :8080.
# Also asserts nginx is still answering :80 after the install.
# EXPECTED: FAIL until Task 5 (phase_webserver port-fallback) is implemented.
set -uo pipefail
SCENARIO=nginx80
# Pre-install nginx and start it so :80 is occupied before the installer runs.
PRESETUP="apt-get install -y nginx && systemctl start nginx"
INSTALLER_ENV="LARANODE_UNATTENDED=1"
EXPECT_PORT=8080
EXPECT_ENGINE=mysql
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
run_scenario
