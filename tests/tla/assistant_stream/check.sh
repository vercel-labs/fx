#!/bin/sh
# Model-check how fx shows a streamed markdown reply while it arrives
# (StreamTail.tla), and require each config's expected verdict.
#
# design-a and design-paced must pass every invariant and property. current-lag,
# current-paced, current-gate, design-b, and each mutant must each break the
# invariant it names. The simulate-*.cfg configs run random traces; SIM_RUNS
# sets how many (default 20000).
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
tlc_verdicts "$@" <<EOF
StreamTail current-lag EveryWordVisible
StreamTail current-paced SmoothReveal
StreamTail current-gate SmoothReveal
StreamTail design-a -
StreamTail design-paced -
StreamTail design-b CommittedIsPrefixOfFinal
StreamTail mutant-no-repair NoUnfinalMark
StreamTail mutant-tail-history HistoryOnlyCommitted
StreamTail mutant-commit-early CommittedIsPrefixOfFinal
StreamTail mutant-never-commit EndCommitsAll
StreamTail mutant-drop-waiting VisibleNeverShrinks
StreamTail mutant-finish-ignores-tail NoLossAtFinish
StreamTail mutant-boundary-flush BoundaryAfterQueue
StreamTail mutant-reject-commits NoRejectedCommit
StreamTail mutant-no-age-cap BoundedStall
StreamTail simulate-ideal simulate $sim
StreamTail simulate-nonideal simulate $sim
StreamTail simulate-paced simulate $sim
EOF
