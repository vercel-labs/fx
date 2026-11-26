#!/bin/sh
# Model-check where a shell run goes, the in-chat setup of a remote runner,
# and one run of the built-in remote runner, with TLC, and require each
# config's expected verdict.
#
# These model the code in src/core/runner/. The driver in
# ../drivers/runner/ runs the built fx along them only with --next.
#
# runner-setup-one-call.cfg, runner-setup.cfg, runner-setup-sub.cfg and
# remote-run.cfg are the design and must pass. The one-call config takes every
# runner request. The two-call configs take only "remote", to stay small: the
# decide rules (IsolatedFloor, RuleWins, NoLocalFallback) are per call and do
# not depend on the other call, so the one-call config checks them in full.
# Each mutation config plants one defect, and the rule it names must catch it:
#
#   runner-setup-mutation-request-beats-floor     IsolatedFloor
#   runner-setup-mutation-request-beats-rule      RuleWins
#   runner-setup-mutation-fallback-local          NoLocalFallback
#   runner-setup-mutation-write-without-confirm   ConfigOnlyByUser
#   runner-setup-mutation-headless-prompt         NoWaitWithoutChannel
#   runner-setup-mutation-double-prompt           SinglePrompt
#   runner-setup-mutation-reprompt-after-decline  NoPromptAfterDecline
#   runner-setup-mutation-other-user-ok           RemoteNeedsReady
#   runner-setup-mutation-stale-wake              RemoteNeedsReady
#   runner-setup-mutation-no-pin                  RemoteNeedsReady
#   runner-setup-mutation-lost-wakeup             EventuallyEnds
#   runner-setup-mutation-cancel-discover-ignored NoPromptAfterCancel
#   runner-setup-mutation-cancel-after-accept-writes NoWriteAfterEarlyCancel
#   runner-setup-mutation-team-accept-consent     WriteOnlyAfterProjectAccept
#   runner-setup-mutation-team-decline-no-mark    NoPromptAfterDecline
#   remote-run-mutation-resend-unknown            NoDoubleSend
#   remote-run-mutation-resend-after-close        NoDoubleSend
#   remote-run-mutation-unknown-as-125            ExitTruth
#   remote-run-mutation-ignore-brought           FreshBringBack
#   remote-run-mutation-overwrite-mac             MacEditsWin
#   remote-run-mutation-stop-before-id            NoOrphanAfterStop
#   remote-run-mutation-exit-before-kill          NoOrphanAfterStop
#   remote-run-mutation-early-bring-back          ExitTruth
#   remote-run-mutation-stop-ignored              StopEnds
#   remote-run-mutation-failed-kill-reports-killed KilledReportIsTrue
#   remote-run-mutation-stop-before-send-143u     ExitTruth
#   remote-run-mutation-resend-twice             NoDoublePost
#   remote-run-mutation-skip-first-resume        ResumeFirstWhenMarked
#   remote-run-mutation-no-mark                  MarkedAfterGone
#   remote-run-mutation-unbounded-resume          ResumeOnce
#   remote-run-mutation-keep-gone-record          GoneComesBack
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh runner-setup remote-run-mutation-resend-unknown
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
RunnerSetup runner-setup-one-call -
RunnerSetup runner-setup -
RunnerSetup runner-setup-sub -
RunnerSetup runner-setup-mutation-request-beats-floor IsolatedFloor
RunnerSetup runner-setup-mutation-request-beats-rule RuleWins
RunnerSetup runner-setup-mutation-fallback-local NoLocalFallback
RunnerSetup runner-setup-mutation-write-without-confirm ConfigOnlyByUser
RunnerSetup runner-setup-mutation-headless-prompt NoWaitWithoutChannel
RunnerSetup runner-setup-mutation-double-prompt SinglePrompt
RunnerSetup runner-setup-mutation-reprompt-after-decline NoPromptAfterDecline
RunnerSetup runner-setup-mutation-other-user-ok RemoteNeedsReady
RunnerSetup runner-setup-mutation-stale-wake RemoteNeedsReady
RunnerSetup runner-setup-mutation-no-pin RemoteNeedsReady
RunnerSetup runner-setup-mutation-lost-wakeup temporal
RunnerSetup runner-setup-mutation-cancel-discover-ignored NoPromptAfterCancel
RunnerSetup runner-setup-mutation-cancel-after-accept-writes NoWriteAfterEarlyCancel
RunnerSetup runner-setup-mutation-team-accept-consent WriteOnlyAfterProjectAccept
RunnerSetup runner-setup-mutation-team-decline-no-mark NoPromptAfterDecline
RemoteRun remote-run -
RemoteRun remote-run-mutation-resend-unknown NoDoubleSend
RemoteRun remote-run-mutation-unknown-as-125 ExitTruth
RemoteRun remote-run-mutation-resend-after-close NoDoubleSend
RemoteRun remote-run-mutation-overwrite-mac MacEditsWin
RemoteRun remote-run-mutation-ignore-brought FreshBringBack
RemoteRun remote-run-mutation-exit-before-kill NoOrphanAfterStop
RemoteRun remote-run-mutation-stop-before-id NoOrphanAfterStop
RemoteRun remote-run-mutation-early-bring-back ExitTruth
RemoteRun remote-run-mutation-stop-ignored temporal -deadlock
RemoteRun remote-run-mutation-failed-kill-reports-killed KilledReportIsTrue
RemoteRun remote-run-mutation-stop-before-send-143u ExitTruth
RemoteRun remote-run-mutation-resend-twice NoDoublePost
RemoteRun remote-run-mutation-skip-first-resume ResumeFirstWhenMarked
RemoteRun remote-run-mutation-no-mark MarkedAfterGone
RemoteRun remote-run-mutation-unbounded-resume ResumeOnce
RemoteRun remote-run-mutation-keep-gone-record temporal
VERDICTS
