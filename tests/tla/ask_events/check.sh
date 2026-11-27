#!/bin/sh
# Model-check AskEvents: live progress events for `fx ask --events-file` (FXC-441).
#
# design-b must pass every invariant. current-sigterm shows today's
# `fx ask --json` losing all events on SIGTERM. Each mutant-* plants a single
# defect that its named invariant must catch.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
tlc_verdicts "$@" <<EOF
AskEvents current-sigterm NoEventLostOnSigterm
AskEvents design-b -
AskEvents mutant-buffered NoEventLostOnSigterm
AskEvents mutant-unlocked ValidJsonPerLine
AskEvents mutant-skip-cancel NoEventLostOnSigterm
AskEvents mutant-no-final FinalResultMatchesJson
AskEvents mutant-file-abort FileFullDoesNotAbortTurn
AskEvents mutant-stdout-clobber IgnoreEventsGetsResult
AskEvents simulate-ideal simulate $sim
AskEvents simulate-nonideal simulate $sim
EOF
