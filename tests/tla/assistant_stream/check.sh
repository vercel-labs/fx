#!/bin/sh
# Model-check how fx shows a streamed markdown reply while it arrives
# (StreamTail.tla), and require each config's expected verdict.
#
# design-a must pass every invariant and the action property. current-lag,
# design-b, and each mutant must each break the invariant it names. The
# simulate-*.cfg configs run random traces of design-a on an ideal and on a
# lagging terminal; SIM_RUNS sets how many (default 20000).
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
tlc_verdicts "$@" <<EOF
StreamTail current-lag EveryWordVisible
StreamTail design-a -
StreamTail design-b CommittedIsPrefixOfFinal
StreamTail mutant-no-repair NoUnfinalMark
StreamTail mutant-tail-history HistoryOnlyCommitted
StreamTail mutant-commit-early CommittedIsPrefixOfFinal
StreamTail mutant-never-commit EndCommitsAll
StreamTail mutant-drop-waiting VisibleNeverShrinks
StreamTail simulate-ideal simulate $sim
StreamTail simulate-nonideal simulate $sim
EOF
