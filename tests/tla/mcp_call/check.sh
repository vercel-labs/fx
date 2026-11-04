#!/usr/bin/env bash
# Checks the `fx mcp call` bridge design: TLC on McpCall.tla, the core's
# tests, both driver directions against the real core, every planted bug,
# and DESIGN.md traceability. `bun run verify` in this folder is the gate;
# this script is the tests/tla/<area>/check.sh entry point that runs it.
set -euo pipefail
cd "$(dirname "$0")"
exec bun run verify
