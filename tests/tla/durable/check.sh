#!/bin/sh
# Model-check the durable libfx protocol models (sdk/durable/) with TLC.
# Every spec must pass.
#
# Every spec is bounded (MaxEvents, MaxCrashes, finite sets), so terminal
# states are expected at the bound; -deadlock keeps TLC from reporting them.
#
# Usage:
#   ./check.sh                    # every spec
#   ./check.sh Journal Fencing    # selected specs
#   ./mutants.py                  # every planted bug must be caught
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
Journal Journal - -deadlock
ToolReplay ToolReplay - -deadlock
ParallelBatch ParallelBatch - -deadlock
Fencing Fencing - -deadlock
Inbox Inbox - -deadlock
Resumption Resumption - -deadlock
SnapshotTail SnapshotTail - -deadlock
EOF
