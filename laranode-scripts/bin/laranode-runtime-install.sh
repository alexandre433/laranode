#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/validate.sh"
ln_need_root
LN_ARGC=$#

# laranode-runtime-install.sh <runtime>
# Installs the given alternative PHP runtime binary.
# Called via sudo by InstallRuntimeService.
ln_argc 1 1 "$0 <runtime>"
ln_enum "$1" RUNTIME frankenphp swoole

# ---- FrankenPHP ----
if [ "$RUNTIME" = "frankenphp" ]; then
    FRANKENPHP_VERSION="v1.12.4"
    FRANKENPHP_SHA256="becd9efc79783a4946fb4802433dc00be32de7e025b60fcab53db4d283a136e9"
    FRANKENPHP_URL="https://github.com/dunglas/frankenphp/releases/download/${FRANKENPHP_VERSION}/frankenphp-linux-x86_64"
    FRANKENPHP_BIN="/usr/local/bin/frankenphp"

    # Idempotent: if binary exists and --version works, skip re-download
    if [ -f "$FRANKENPHP_BIN" ]; then
        if "$FRANKENPHP_BIN" --version >/dev/null 2>&1; then
            echo "FrankenPHP ${FRANKENPHP_VERSION} already installed and functional. Skipping."
            exit 0
        else
            echo "FrankenPHP binary exists but '--version' failed (corrupt?). Re-downloading..."
        fi
    fi

    # A private root-owned scratch dir: a fixed /tmp name is a symlink trap for www-data.
    WORK=$(mktemp -d /var/tmp/laranode-runtime.XXXXXX)
    trap 'rm -rf -- "$WORK"' EXIT
    FRANKENPHP_TMP="$WORK/frankenphp"

    echo "Downloading FrankenPHP ${FRANKENPHP_VERSION}..."
    curl -sfL -o "$FRANKENPHP_TMP" "$FRANKENPHP_URL"

    echo "Verifying SHA-256 checksum..."
    if ! echo "${FRANKENPHP_SHA256}  ${FRANKENPHP_TMP}" | sha256sum -c -; then
        echo "SHA-256 mismatch — aborting install." >&2
        exit 1
    fi

    chmod 0755 "$FRANKENPHP_TMP"
    mv -f -- "$FRANKENPHP_TMP" "$FRANKENPHP_BIN"

    echo "Verifying FrankenPHP binary..."
    "$FRANKENPHP_BIN" --version
    echo "FrankenPHP installed successfully."
    exit 0
fi

# ---- Swoole (v2 placeholder) ----
echo "Swoole runtime install not implemented in v1." >&2
exit 1
