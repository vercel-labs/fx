#!/bin/sh
# Model-check the recovery module's model with TLC and require each config's
# expected verdict.
#
# recovery.cfg and recovery-deep.cfg are the correct module and must pass.
# Each recovery-mutation-*.cfg plants one defect, and the rule it names must
# catch it. Most are bugs fx has shipped:
#
#   stall-stop          stops a request after repeated quick failures      NeverGivesUp
#   no-wake             a wait whose deadline never fires                  Heals
#   stale-socket        a dead pooled connection shown as a failure        NoFalseAlarm
#   frozen-status       a retry warning left over a streaming answer       StatusHonest
#   no-closing          a closed window treated as a crash                 ResumesAfterClose
#   never-ask           a request that crashes fx resumes forever          CrashLoopAsks
#   hot-retry           resending at once after a failure                  NoHotRetry
#   send-without-save   a retry sent without saving the record first       SaveBeforeSend
#   yield-retry-status  a continued turn shown as a retry ("attempt 2")    NoFalseAlarm
#   filter-unbounded    every blocked reply resent, without a bound        FilterBounded
#   filter-asks-early   the first blocked reply asks, with no resend       FilterBounded
#   cannot-ask-resends  fx ask resends a request that needs the user       CannotAskEnds
#   asking-host-resends the TUI resends without the user's answer          AskingHostWaits
#   filter-answer-keeps-count  the user's answer keeps the blocks' count  AnswerGivesResends
#
# RecoveryTimed.tla adds a discrete clock. recovery-timed.cfg must pass, and
# each of its mutations plants one defect:
#
#   unbounded-wait      a Retry-After past the 30-second cap               WaitBounded
#   frozen-countdown    the countdown stops changing every second          StatusFresh
#   no-handoff          a retry status left over a model thinking quietly  HandsOff
#
# Resume.tla models the app around the module across process exits,
# including the restart Ctrl+G makes for an upgrade.
# resume.cfg and resume-deep.cfg are the design and must pass;
# resume-today.cfg is fx before it, which leaves an interrupted request for
# the user (AutoResumes). Each resume-mutation-*.cfg plants one defect:
#
#   no-closing          a closed window counted as a crash                 NoFalseCrashQuestion
#   no-clear            a finished request's record left behind            NoFalseCrashQuestion
#   send-before-save    a send on the wire before its record is saved      CrashLoopAsks
#   reset-on-resume     a resumed request saves a fresh death count        CrashLoopAsks
#   resume-answered     a turn whose final answer was saved sent again     DoneNeverResent
#   resume-cancelled    a turn the user cancelled sent again               CancelNeverResumes
#   ignore-age          a day-old request sent again without asking        OldAsks
#   no-lock             a second fx resuming a session another holds       OneWorker
#   yield-unclean       an upgrade's restart saved as a death              NoFalseCrashQuestion
#   yield-first         a turn stopped for a restart before it is logged   YieldContinues
#   yield-unsaved       a stop whose save failed, left as a clean stop     NoFalseCrashQuestion
#   cancel-strands      a cancelled restart leaves a held turn stopped     HeldOnlyWhileRestartWaits
#   cancel-keeps-relaunch  a quit after a cancel relaunches                CancelledRestartStays
#   cancel-unsaved      a held turn sends with its clean record            CrashLoopAsks
#
# RestartWait.tla models one process's main loop against the workers it
# asks to stop for the restart, and the cancel. restart-wait.cfg is the
# design and must pass, with its WaitEnds liveness; restart-wait-current.cfg
# is fx before the cancel, whose turn stops for good at its boundary
# (NoStopWhileCancellable). Each restart-wait-mutation-*.cfg plants one
# defect:
#
#   hold-ignores-flag   a turn holds after a cancel cleared its request    HeldOnlyWhileRestartWaits
#   cancel-while-releasing  a cancel after the release strands a turn   NoStopWhileCancellable
#   release-early       the release closes the cancel while a turn runs    NoUncancellableWait
#   auto-ignores-draft  the automatic restart fires with a draft open      AutoRestartOnlyWhenIdle
#
# The two restart-wait-simulate-*.cfg run random behaviors with and
# without faults.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh recovery recovery-mutation-no-closing
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
Recovery recovery -
Recovery recovery-deep -
Recovery recovery-mutation-stall-stop NeverGivesUp
Recovery recovery-mutation-no-wake temporal
Recovery recovery-mutation-stale-socket NoFalseAlarm
Recovery recovery-mutation-yield-retry-status NoFalseAlarm
Recovery recovery-mutation-frozen-status StatusHonest
Recovery recovery-mutation-no-closing ResumesAfterClose
Recovery recovery-mutation-never-ask CrashLoopAsks
Recovery recovery-mutation-hot-retry NoHotRetry
Recovery recovery-mutation-send-without-save SaveBeforeSend
Recovery recovery-mutation-poll-reopens StatusHonest
Recovery recovery-mutation-poll-drop-reasks PollKeepsSignIn
Recovery recovery-mutation-filter-unbounded FilterBounded
Recovery recovery-mutation-filter-asks-early FilterBounded
Recovery recovery-mutation-cannot-ask-resends CannotAskEnds
Recovery recovery-mutation-asking-host-resends AskingHostWaits
Recovery recovery-mutation-filter-answer-keeps-count AnswerGivesResends
RecoveryTimed recovery-timed -
RecoveryTimed recovery-mutation-unbounded-wait WaitBounded
RecoveryTimed recovery-mutation-frozen-countdown StatusFresh
RecoveryTimed recovery-mutation-no-handoff HandsOff
RecoveryTimed recovery-mutation-poll-hot PollWaits
RecoveryTimed recovery-mutation-never-poll PollBounded
Resume resume -
Resume resume-deep -
Resume resume-today AutoResumes
Resume resume-mutation-no-closing NoFalseCrashQuestion
Resume resume-mutation-no-clear NoFalseCrashQuestion
Resume resume-mutation-send-before-save CrashLoopAsks
Resume resume-mutation-reset-on-resume CrashLoopAsks
Resume resume-mutation-resume-answered DoneNeverResent
Resume resume-mutation-resume-cancelled CancelNeverResumes
Resume resume-mutation-ignore-age OldAsks
Resume resume-mutation-no-lock OneWorker
Resume resume-mutation-yield-unclean NoFalseCrashQuestion
Resume resume-mutation-yield-first YieldContinues
Resume resume-mutation-yield-unsaved NoFalseCrashQuestion
Resume resume-mutation-cancel-strands HeldOnlyWhileRestartWaits
Resume resume-mutation-cancel-keeps-relaunch CancelledRestartStays
Resume resume-mutation-cancel-unsaved CrashLoopAsks
RestartWait restart-wait -
RestartWait restart-wait-current NoStopWhileCancellable
RestartWait restart-wait-mutation-hold-ignores-flag HeldOnlyWhileRestartWaits
RestartWait restart-wait-mutation-cancel-while-releasing NoStopWhileCancellable
RestartWait restart-wait-mutation-release-early NoUncancellableWait
RestartWait restart-wait-mutation-auto-ignores-draft AutoRestartOnlyWhenIdle
RestartWait restart-wait-simulate-ideal simulate -simulate num=20000 -depth 20 -seed 1
RestartWait restart-wait-simulate-nonideal simulate -simulate num=20000 -depth 20 -seed 1
EOF
