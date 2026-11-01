#!/usr/bin/env bash
# Checks the transcript window design: TLC on TranscriptWindow.tla, both
# driver directions against the real core, every planted bug, and DESIGN.md
# traceability. `bun run verify` in this folder is the gate; this script is
# the tests/tla/<area>/check.sh entry point that runs it. With --ci it leaves
# out the planted bugs and the run of the built fx, as CI does.
set -euo pipefail
cd "$(dirname "$0")"
exec bun run verify "$@"
