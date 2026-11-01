#!/bin/sh
# Model-check ShellSession, the session the interactive app has open and what
# `/status` and the exit line say about it (D90), and require each config's
# expected verdict.
#
# holds.cfg must pass. Each witness-*.cfg must be violated, which shows the
# state it names is reachable, so the properties are not vacuous there. Each
# mutant-*.cfg plants one bug that its property must catch. simulate.cfg runs
# random behaviors with more ids and turns; SIM_RUNS sets how many (default
# 20000).
#
# TurnStream models how an agent turn streams into the session log and
# commits, and how each tool result keeps the time it was made.
# stream-holds.cfg must pass with every edge case on: results that lost their
# stamp, compaction, recovery from a checkpoint, and faults. stream-before-
# safe.cfg must pass for fx before results kept their stamps, and
# stream-before-reparses.cfg shows that design reparsed streamed pieces. Each
# stream-mutant-*.cfg plants one bug that its property must catch, and each
# stream-witness-*.cfg must be violated. stream-simulate*.cfg run random
# behaviors with more calls and rebuilds.
#
# Run the real binary along the models and have TLC check every run:
#   bun test ../drivers/session/
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 40 -seed 1"
tlc_verdicts "$@" <<EOF
ShellSession holds -
ShellSession witness-saved-empty-status NoSavedEmptyStatus
ShellSession witness-unsaved-status NoUnsavedStatus
ShellSession witness-storeless-status NoStorelessStatus
ShellSession witness-empty-exit-line NoEmptyExitLine
ShellSession witness-resume-after-crash NoResumeAfterCrash
ShellSession mutant-saved-by-turns StatusUnsavedIsAbsent
ShellSession mutant-saved-on-open StatusSavedIsOnDisk
ShellSession mutant-exit-by-turns ExitAgreesWithStatus
ShellSession mutant-status-launch-id StatusNamesOpenSession
ShellSession mutant-keep-pristine DiscardedNeverSaved
ShellSession mutant-reuse-id NewIdsAreFresh
ShellSession mutant-fork-held ForkOnDisk
ShellSession mutant-drop-on-switch SavedStaysSaved
ShellSession simulate simulate $sim
TurnStream stream-holds -
TurnStream stream-before-safe -
TurnStream stream-before-reparses NoReparseOfStamped
TurnStream stream-mutant-lose-on-recover StampIsBirth
TurnStream stream-mutant-share-stamp StampIsOwn
TurnStream stream-mutant-bytes-only SupersedeExplained
TurnStream stream-mutant-loose-compare CommitIsFinal
TurnStream stream-mutant-mix CommitIsFinal
TurnStream stream-mutant-prefix-only CommitIsFinal
TurnStream stream-witness-supersede NeverSuperseded
TurnStream stream-witness-commit NeverCommittedWhole
TurnStream stream-witness-compaction NeverCommittedAfterCut
TurnStream stream-witness-recovery NeverCommittedAfterRecovery
TurnStream stream-witness-missed-path MissedPathsNeverParse
TurnStream stream-simulate simulate $sim
TurnStream stream-simulate-before simulate $sim
EOF
