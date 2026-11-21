#!/usr/bin/env bash
# Run the fast sudo-hardening harness in a throwaway debian:13 container.
#   bash local-dev/install-test/sudo-hardening/run-fast.sh [script-or-spec-name ...]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
case "$(uname -s)" in MINGW*|MSYS*) REPO_MNT="$(cd "$REPO" && pwd -W)"; export MSYS_NO_PATHCONV=1 ;; *) REPO_MNT="$REPO" ;; esac
IMG=laranode-sudo-fast
docker build -q -t "$IMG" - >/dev/null <<'DF'
FROM debian:13
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends sudo util-linux passwd tar gzip coreutils findutils procps ca-certificates >/dev/null && rm -rf /var/lib/apt/lists/*
DF
docker run --rm -v "$REPO_MNT":/src:ro "$IMG" bash /src/local-dev/install-test/sudo-hardening/fast.sh "$@"
