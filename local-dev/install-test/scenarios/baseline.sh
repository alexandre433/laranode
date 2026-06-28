#!/usr/bin/env bash
# Scenario: bare ubuntu:24.04, all defaults → mysql, panel on :80.
# This is the primary clean-room regression test for the installer.
# Must pass against both the current installer and after every hardening task.
set -uo pipefail
SCENARIO=baseline
PRESETUP=""
INSTALLER_ENV="LARANODE_UNATTENDED=1"
EXPECT_PORT=80
EXPECT_ENGINE=mysql
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"
run_scenario
