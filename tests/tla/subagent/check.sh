#!/bin/sh
# Model-check main's messages into its subagents' running turns
# (Owner.steer in src/core/subagent/managed_owner.zig) with TLC and require
# each config's expected verdict.
#
# StopMessage models main's stop and its next messages to a subagent
# (Runtime.stopChild and the message path in tool_host.zig, and the subagent
# group in src/core/agent/runtime/parallel_execution.zig). stop-message.cfg and
# stop-message-deep.cfg are the design and must pass, with every rule.
# stop-message-today.cfg, -today-order.cfg, -today-loss.cfg and
# -today-start.cfg are fx before it, one defect each. Each
# stop-message-mutation-*.cfg plants one defect. A defect can break more than
# one rule at about the same depth, so each of these configs checks only the
# rule named for it:
#
#   refuse-ending        a message to a stopped, ending turn is refused        RefusedOnlyWhenClosing
#   no-order             a step's calls to one subagent run in any order        StopRunsFirst
#   uncounted            a stop's answer leaves out the unread messages         NoSilentLoss
#   join-user-ending     a message joins a turn the user stopped                NoSilentLoss
#   read-after-stop      a stopped turn still reads messages                    CountedNeverRead
#   drop-waiting-at-end  the stopped turn's end drops the waiting messages      NoSilentLoss
#   queue-closing        a message to a closing subagent waits, and goes with it  NoSilentLoss
#   start-next-turn      a message to a starting turn waits for the next one    JoinsStartingWork
#   late-rearm           the slot clears the stop flags after the end hook
#                        installed the next work, so a stop in between is erased  StopHoldsForQueued
#   leftover-gap         a stop of a turn that ended, whose slot kept its unread
#                        messages, reaches nothing: the hook installs them and
#                        arms the work, so they run after the stop      StopHoldsForQueued
#   leftover-uncounted   a stop or close of such a turn drops the kept
#                        messages and does not count them                NoSilentLoss
#   note-after-take      the idle note is decided after the next turn took the
#                        waiting messages, so it says idle while a turn starts   IdleNoteHonest
#   names-busy           a new subagent's start names every other open one      NamesTheIdle
#
# stop-message-before-idle.cfg and -before-names.cfg are fx before the idle
# note: no report says its subagent is idle, and no start names any.
#
# StopMessageTrace.tla checks runs of the built fx binary against it;
# tests/tla/drivers/subagent/stop-message.test.ts runs it.
#
# The SteerQueue configs:
#
# steer-queue.cfg and steer-queue-deep.cfg are the design and must pass.
# steer-queue-today.cfg is fx before it: one list for every subagent, with
# settled entries counted and kept until the same subagent starts again, and
# steer-queue-today-close.cfg its second defect, a closed subagent's entries
# kept (both are reached at the same depth, so each config checks one). Each
# steer-queue-mutation-*.cfg plants one defect, and the rule it names must
# catch it:
#
#   global-waiting   unread messages counted across every subagent  RefusedOnlyWhenFull
#   settled-count    a subagent's read messages still counted       RefusedOnlyWhenFull
#   off-by-one       a subagent refused one message early           RefusedOnlyWhenFull
#   no-limit         no limit at all                                WaitingBounded
#   no-start-prune   a new work keeps the last work's entries      EntriesFromThisWork
#   no-close-forget  a closed subagent keeps its entries            ClosedHoldsNothing
#
# SteerQueueTrace.tla checks runs of the built fx binary against the model;
# tests/tla/drivers/subagent/driver.ts runs it.
#
# The QuietRelay configs:
#
# QuietRelay models fx's note to a parent when its subagent's shell command
# crosses the quiet limit (noteChildQuiet in tool_host.zig, raised by
# agent_adapter.zig and app_worker_runtime.zig), and the parent's wait that
# the note wakes. quiet-relay.cfg and quiet-relay-deep.cfg are the design and
# must pass. Each quiet-relay-mutation-*.cfg plants one defect, and the rule it
# names must catch it:
#
#   relay-late-notice  a later notice in the same spell is relayed     OnePerSpell
#   relay-after-close  a note for a closed subagent is posted          NoRelayAfterClose
#   silent-drop        a note the full mailbox refuses is not logged   EveryCrossingAccounted
#   no-cap             a note is posted past the mailbox bound         MailboxBounded
#   check-first        the wait checks the mailbox before it registers NoSleepOnMail
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh steer-queue steer-queue-mutation-no-start-prune
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
#
# The MainMail configs:
#
# MainMail models how a subagent's report or message reaches main
# (postMailWith, takeSteeringBoundaryIntoInner and finishProcessing in
# src/core/agent/worker_runtime.zig, runAskTurn in src/core/cli/cli_ask.zig)
# and what wait says about it (Runtime.waitForMail in tool_host.zig).
# main-mail.cfg is the design where turns take mail, the app and fx ask;
# main-mail-acp.cfg is ACP, whose turns never do. Both must pass.
# main-mail-today.cfg is fx ask before it: no turn takes mail, so a report
# that reached an open turn waits for the next one. main-mail-today-acp.cfg
# is ACP before it: wait says the report follows. Each
# main-mail-mutation-*.cfg plants one defect:
#
#   wait-always-follows  wait says it follows whatever the mail does   WaitHonest
#   lost-at-finish       a finished turn drops the mail left for it    NoneLost
#   close-with-mail      a final boundary closes with mail unread      JoinsOpenTurn
#
# tests/tla/drivers/subagent/main-mail.test.ts checks runs of the built fx
# against it (MainMailTrace.tla).

set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
SteerQueue steer-queue -
SteerQueue steer-queue-deep -
SteerQueue steer-queue-today RefusedOnlyWhenFull
SteerQueue steer-queue-today-close ClosedHoldsNothing
SteerQueue steer-queue-mutation-global-waiting RefusedOnlyWhenFull
SteerQueue steer-queue-mutation-settled-count RefusedOnlyWhenFull
SteerQueue steer-queue-mutation-off-by-one RefusedOnlyWhenFull
SteerQueue steer-queue-mutation-no-limit WaitingBounded
SteerQueue steer-queue-mutation-no-start-prune EntriesFromThisWork
SteerQueue steer-queue-mutation-no-close-forget ClosedHoldsNothing
StopMessage stop-message -
StopMessage stop-message-deep -
StopMessage stop-message-today RefusedOnlyWhenClosing
StopMessage stop-message-today-order StopRunsFirst
StopMessage stop-message-today-loss NoSilentLoss
StopMessage stop-message-today-start JoinsStartingWork
StopMessage stop-message-mutation-refuse-ending RefusedOnlyWhenClosing
StopMessage stop-message-mutation-no-order StopRunsFirst
StopMessage stop-message-mutation-uncounted NoSilentLoss
StopMessage stop-message-mutation-join-user-ending NoSilentLoss
StopMessage stop-message-mutation-read-after-stop CountedNeverRead
StopMessage stop-message-mutation-drop-waiting-at-end NoSilentLoss
StopMessage stop-message-mutation-queue-closing NoSilentLoss
StopMessage stop-message-mutation-start-next-turn JoinsStartingWork
StopMessage stop-message-mutation-late-rearm StopHoldsForQueued
StopMessage stop-message-mutation-leftover-gap StopHoldsForQueued
StopMessage stop-message-mutation-leftover-uncounted NoSilentLoss
StopMessage stop-message-before-idle IdleNoteHonest
StopMessage stop-message-before-names NamesTheIdle
StopMessage stop-message-mutation-note-after-take IdleNoteHonest
StopMessage stop-message-mutation-names-busy NamesTheIdle
MainMail main-mail -
MainMail main-mail-acp -
MainMail main-mail-today JoinsOpenTurn
MainMail main-mail-today-acp WaitHonest
MainMail main-mail-mutation-wait-always-follows WaitHonest
MainMail main-mail-mutation-lost-at-finish NoneLost
MainMail main-mail-mutation-close-with-mail JoinsOpenTurn
QuietRelay quiet-relay -
QuietRelay quiet-relay-deep -
QuietRelay quiet-relay-mutation-relay-late-notice OnePerSpell
QuietRelay quiet-relay-mutation-relay-after-close NoRelayAfterClose
QuietRelay quiet-relay-mutation-silent-drop EveryCrossingAccounted
QuietRelay quiet-relay-mutation-no-cap MailboxBounded
QuietRelay quiet-relay-mutation-check-first NoSleepOnMail
VERDICTS
