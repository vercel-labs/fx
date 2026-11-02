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
#
# RecoveryTimed.tla adds a discrete clock. recovery-timed.cfg must pass, and
# each of its mutations plants one defect:
#
#   unbounded-wait      a Retry-After past the 30-second cap               WaitBounded
#   frozen-countdown    the countdown stops changing every second          StatusFresh
#
# Resume.tla models the app around the module across process exits.
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
Recovery recovery-mutation-frozen-status StatusHonest
Recovery recovery-mutation-no-closing ResumesAfterClose
Recovery recovery-mutation-never-ask CrashLoopAsks
Recovery recovery-mutation-hot-retry NoHotRetry
Recovery recovery-mutation-send-without-save SaveBeforeSend
RecoveryTimed recovery-timed -
RecoveryTimed recovery-mutation-unbounded-wait WaitBounded
RecoveryTimed recovery-mutation-frozen-countdown StatusFresh
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
EOF
