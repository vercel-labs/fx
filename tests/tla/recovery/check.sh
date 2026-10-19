#!/bin/sh
# Model-check the recovery models with TLC. Every config must reach its
# expected verdict, and every planted defect must break only its own rule.
#
# Recovery.tla is one model request and fx carrying out its plans.
# RecoveryTimed.tla adds a discrete clock. Resume.tla covers closing and
# resuming a request across process exits.
#
# recovery, recovery-deep, recovery-timed, resume, resume-ask, and
# resume-deep are the correct design and must pass. Every other config must
# be caught by the rule its row names. isolate.sh then checks a copy of each
# such config without that rule, and the copy must pass.
#
# Defects planted in the recovery module, most of them bugs fx has shipped
# or nearly shipped:
#
#   stall-stop            stops a request after repeated failures         NeverGivesUp
#   no-wake               a wait whose deadline never fires               Heals
#   stale-socket          a dead pooled connection shown as a failure     NoFalseAlarm
#   frozen-status         a retry warning left over a streaming answer    StatusHonest
#   no-closing            a closed window treated as a crash              ResumesAfterClose
#   never-ask             a request that crashes fx resumes forever       CrashLoopAsks
#   hot-retry             resending at once after a failure               NoHotRetry
#   send-without-save     a retry sent without saving the record first    SaveBeforeSend
#   send-before-sync      a send out before its save is durable           DeathCounted
#   torn-resets           a torn record starts the request fresh          CrashLoopAsks
#   stop-keeps-record     fx's own stop leaves the record behind          NoResumeAfterEnd
#   stop-before-fast      a stop before the request tries without Fast    FastBeforeStop
#   stop-on-class-change  the repeat count runs on when the send changes  StopOnlyWhenRepeating
#   late-outcome-counts   an aborted send's outcome reaches the screen    NothingAfterFinish
#   compact-waits         the compacted request waits a backoff           NoHotRetry
#   unbounded-wait        a Retry-After past the 30-second cap            WaitBounded
#   frozen-countdown      the countdown stops changing every second       StatusFresh
#
# today-* configs model fx as it ships. Each fails the rule its bug breaks:
#
#   close-asks            "quit unexpectedly" after closing the window    NoQuestionAfterCleanClose
#   sticky                the question repeats after clean exits          NotSticky
#   one-death-asks        one death already asks                          NoQuestionAfterOneDeath
#   paused-resends        a paused turn is resent on its own              NoResumeAfterEnd
#   eof-cancels           terminal EOF cancels the request                CloseKeepsRequest
#   close-no-resume       after a close, nothing ever resends             ResumesAfterClose
#
# resume-mutation-* configs plant defects in the proposed resume design,
# and resume-witness-* configs show why the crash-loop rules count the
# deaths a launch can see.
#
# recovery-deeper.cfg checks the module with five faults and takes about
# 7 seconds, so it runs only when named.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh recovery resume-mutation-no-lock
#   ./check.sh recovery-deeper
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

checks='Recovery recovery -
Recovery recovery-deep -
RecoveryTimed recovery-timed -
Recovery recovery-mutation-stall-stop NeverGivesUp
Recovery recovery-mutation-no-wake temporal
Recovery recovery-mutation-stale-socket NoFalseAlarm
Recovery recovery-mutation-frozen-status StatusHonest
Recovery recovery-mutation-no-closing ResumesAfterClose
Recovery recovery-mutation-never-ask CrashLoopAsks
Recovery recovery-mutation-hot-retry NoHotRetry
Recovery recovery-mutation-send-without-save SaveBeforeSend
Recovery recovery-mutation-send-before-sync DeathCounted
Recovery recovery-mutation-torn-resets CrashLoopAsks
Recovery recovery-mutation-stop-keeps-record NoResumeAfterEnd
Recovery recovery-mutation-stop-before-fast FastBeforeStop
Recovery recovery-mutation-stop-on-class-change StopOnlyWhenRepeating
Recovery recovery-mutation-late-outcome-counts NothingAfterFinish
Recovery recovery-mutation-compact-waits NoHotRetry
RecoveryTimed recovery-mutation-unbounded-wait WaitBounded
RecoveryTimed recovery-mutation-frozen-countdown StatusFresh
Resume resume -
Resume resume-ask -
Resume resume-deep -
Resume today-close-asks NoQuestionAfterCleanClose
Resume today-sticky NotSticky
Resume today-one-death-asks NoQuestionAfterOneDeath
Resume today-paused-resends NoResumeAfterEnd
Resume today-eof-cancels CloseKeepsRequest
Resume today-close-no-resume temporal
Resume resume-mutation-no-seq-binding NoResumeAfterCommit
Resume resume-mutation-delete-before-commit NoLostRequest
Resume resume-mutation-torn-resets CrashLoopAsks
Resume resume-mutation-closing-joins-worker BoundedClosing
Resume resume-mutation-send-before-durable SaveDurableBeforeSend
Resume resume-mutation-fork-copies-record RecordBound
Resume resume-mutation-no-lock OneResumer
Resume resume-mutation-owner-fallback NoResumeAfterEnd
Resume resume-witness-wire-deaths NoQuestionAfterOneDeath
Resume resume-witness-every-death CrashLoopAsks'
# recovery-deeper takes about 7 seconds, so it runs only when named.
case " $* " in *" recovery-deeper "*)
    checks="$checks
Recovery recovery-deeper -"
    ;;
esac

status=0
printf '%s\n' "$checks" | tlc_verdicts "$@" || status=1
printf '%s\n' "$checks" | ./isolate.sh "$@" || status=1
exit "$status"
