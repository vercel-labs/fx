#!/bin/sh
# Model-check AskRefusal: what `fx ask` prints on stderr, and records in
# --json, for a tool call that fx refuses or runs.
#
# current-*.cfg run today's design (origin/main), and each must break the
# rule it names. design-a and design-b must pass every invariant. Each
# mutant-*.cfg plants one bug in one design, and its invariant must catch it.
# The simulate-*.cfg configs run random behaviors, with and without cancel;
# SIM_RUNS sets how many (default 20000).
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
tlc_verdicts "$@" <<EOF
AskRefusal current-running NoRunningForRefused
AskRefusal current-told RefusalTold
AskRefusal current-json JsonReason
AskRefusal current-review ReviewTold
AskRefusal design-a -
AskRefusal design-b -
AskRefusal mutant-a-early-print NoRunningForRefused
AskRefusal mutant-a-cancel-print NoRunningForRefused
AskRefusal mutant-a-no-reason JsonReason
AskRefusal mutant-a-twice RefusalTold
AskRefusal mutant-a-run-reason NothingChangesForRun
AskRefusal mutant-a-no-reviewing ReviewTold
AskRefusal mutant-a-settle-reviewing ReviewTold
AskRefusal mutant-b-early-start NoRunningForRefused
AskRefusal mutant-b-no-review-row ReviewShowsRow
AskRefusal simulate-ideal simulate $sim
AskRefusal simulate-nonideal simulate $sim
AskRefusal simulate-ideal-b simulate $sim
AskRefusal simulate-nonideal-b simulate $sim
EOF
