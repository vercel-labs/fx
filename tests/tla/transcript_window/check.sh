#!/usr/bin/env bash
# Checks the transcript window design: TLC on TranscriptWindow.tla (including
# current-today, design configs, and ideal/nonideal simulations), both driver
# directions against the real core, every planted bug, and DESIGN.md
# traceability. `bun run verify` in this folder runs the driver/mutation gate;
# with --ci it leaves out the planted bugs and the run of the built fx, as CI does.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
(
  cd spec
  tlc_verdicts <<EOF
TranscriptWindow current-today HeldSinceLastCompaction
TranscriptWindow MCTranscriptWindow - -deadlock
TranscriptWindow MCTranscriptWindowUnsaved - -deadlock
TranscriptWindow MCCtrlOReachesStart - -deadlock
TranscriptWindow simulate-ideal simulate -deadlock $sim
TranscriptWindow simulate-nonideal simulate -deadlock $sim
EOF
)

exec bun run verify "$@"
