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
# behaviors with more calls and rebuilds. stream-continue.cfg must pass with
# Ctrl+G yields and their continuations on; each stream-continue-mutant-*.cfg
# plants one read-back bug, and each stream-continue-witness-*.cfg must be
# violated.
#
# SessionWrite models how a session's writes list the compactor's records
# (D50) when they run on more than one thread. session-write.cfg must pass
# with one write at a time and failed appends on. session-write-today*.cfg
# show fx before the write lock: the second clear panics, a clear can drop a
# record no batch listed, and two batches list the same record. Each
# session-write-mutant-*.cfg plants one bug that its property must catch,
# and each session-write-witness-*.cfg must be violated.
#
# LiveSessions models `fx sessions --live`: a scan that tries each session's
# writer lock without waiting while other fx processes open, hold, crash,
# and close sessions, and that lists each live session's subagents from its
# log. live-holds.cfg checks one session exhaustively and must pass;
# live-simulate.cfg runs random behaviors with two sessions, three processes,
# and two subagents. Each live-witness-*.cfg must be violated, and each
# live-mutant-*.cfg plants one bug that its property must catch.
#
# AcceptedInput models accepted user prompts across crashes, restarts,
# withdrawals, and session switches for fx before the fix ("current"), the
# landed Design A2 (log records + atomic batch of normal item and delivered
# marker, restoring to composer before writing withdrawn), and rejected
# designs A (single-line carrier item) and B (atomic pending file + carrier
# item). accepted-current-survives shows fx before the fix loses accepted
# prompts on a crash; accepted-design-a, accepted-design-a2, and
# accepted-design-b must pass; the six accepted-mutant-* configs must fail on
# their planted bugs; accepted-simulate-ideal and accepted-simulate-nonideal
# run random behaviors. Pass `accepted` to run only the AcceptedInput checks.
#
# Run the real binary along the models and have TLC check every run:
#   bun test ../drivers/session/
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

if [ "$#" -gt 0 ]; then
    expanded=""
    for arg in "$@"; do
        if [ "$arg" = "accepted" ]; then
            expanded="$expanded accepted-current-survives accepted-design-a accepted-design-a2 accepted-design-b accepted-mutant-a-two-lines accepted-mutant-a-show-before-write accepted-mutant-b-no-dedupe accepted-mutant-a-withdraw-after-drop accepted-mutant-a2-marker-later accepted-mutant-a2-withdraw-before-composer accepted-simulate-ideal accepted-simulate-nonideal"
        else
            expanded="$expanded $arg"
        fi
    done
    # shellcheck disable=SC2086
    set -- $expanded
fi

sim="-simulate num=${SIM_RUNS:-20000} -depth 40 -seed 1"
sim_accepted="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
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
TurnStream stream-mutant-cut-view LogKeepsCutResults
TurnStream stream-mutant-continue-stale StaleTurnNeverContinues
TurnStream stream-witness-supersede NeverSuperseded
TurnStream stream-witness-commit NeverCommittedWhole
TurnStream stream-witness-compaction NeverCommittedAfterCut
TurnStream stream-witness-recovery NeverCommittedAfterRecovery
TurnStream stream-witness-missed-path MissedPathsNeverParse
TurnStream stream-witness-failed-commit NeverCommittedAfterFailure
TurnStream stream-simulate simulate $sim
TurnStream stream-simulate-before simulate $sim
TurnStream stream-continue -
TurnStream stream-continue-mutant-copies ReadsEachPieceOnce
TurnStream stream-continue-mutant-reader-drops ReadsNoneLost
TurnStream stream-continue-witness-extends NeverExtends
TurnStream stream-continue-witness-copy NeverCopiedAfterYield
TurnStream stream-continue-simulate simulate $sim
SessionWrite session-write -
SessionWrite session-write-today NoStaleRemoval
SessionWrite session-write-today-loss ClearedWereListed
SessionWrite session-write-today-twice ListedOnce
SessionWrite session-write-mutant-unlock-after-take NoStaleRemoval
SessionWrite session-write-mutant-clear-all ClearedWereListed
SessionWrite session-write-mutant-clear-on-failure ClearedWereListed
SessionWrite session-write-witness-added-during-write NeverAddedDuringWrite
SessionWrite session-write-witness-waits NeverWaitsBehindDue
SessionWrite session-write-witness-relisted NeverRelistedAfterFailure
LiveSessions live-holds -
LiveSessions live-witness-stale NoStaleListing
LiveSessions live-witness-idle-parent NoWorkingChildOfIdle
LiveSessions live-witness-open-fails-on-scan NoOpenFailsOnScan
LiveSessions live-mutant-inverted-probe ProbeSound
LiveSessions live-mutant-probe-keeps-lock ScanHoldsOneTry
LiveSessions live-mutant-closed-child AgentsAsLogged
LiveSessions live-mutant-parent-state AgentsAsLogged
LiveSessions live-mutant-recent-is-live ProbeSound
LiveSessions live-simulate simulate -simulate num=${SIM_RUNS:-20000} -depth 60 -seed 1
AcceptedInput accepted-current-survives AcceptedSurvives
AcceptedInput accepted-design-a -
AcceptedInput accepted-design-a2 -
AcceptedInput accepted-design-b -
AcceptedInput accepted-mutant-a-two-lines NeverDeliveredTwice
AcceptedInput accepted-mutant-a-show-before-write AcceptedSurvives
AcceptedInput accepted-mutant-b-no-dedupe NeverDeliveredTwice
AcceptedInput accepted-mutant-a-withdraw-after-drop WithdrawnStaysGone
AcceptedInput accepted-mutant-a2-marker-later DeliveredNeverRestored
AcceptedInput accepted-mutant-a2-withdraw-before-composer AcceptedSurvives
AcceptedInput accepted-simulate-ideal simulate $sim_accepted
AcceptedInput accepted-simulate-nonideal simulate $sim_accepted
EOF
