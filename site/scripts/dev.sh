#!/usr/bin/env bash
# Local dev/test stack — no Cloudflare login, no CI. One process serves both
# the static site and the gateway proxy, exactly like the deployed Worker.
#
#   site+proxy : http://127.0.0.1:8788/   (WORKER_BASE defaults to same origin)
#
# GATEWAY_KEY comes from worker/.dev.vars (gitignored) or the environment.
# Override the upstream for offline testing, e.g.:
#   UPSTREAM_BASE=http://127.0.0.1:9999 GATEWAY_KEY=test site/scripts/dev.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-8788}"

PORT="$PORT" node "$ROOT/scripts/worker-local.mjs"

trap 'kill 0' EXIT
