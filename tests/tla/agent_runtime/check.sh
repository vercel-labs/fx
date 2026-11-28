#!/bin/sh
# Model-check the empty-reply nudge, the malformed tool call feedback, and the
# recovery after a reply cut off at its output limit in the agent step loop
# (src/core/agent/runtime/orchestrator.zig) with TLC and require each config's
# expected verdict.
#
# empty-reply.cfg and empty-reply-deep.cfg are the design and must pass.
# empty-reply-today.cfg is fx before it, which ended an empty reply that
# stopped for `other` with "Done." (EverySeparateEmptyNudged). Each
# empty-reply-mutation-*.cfg plants one defect, and the rule it names must
# catch it:
#
#   no-reset          a nudge flag that survives a step that made progress  EverySeparateEmptyNudged
#   double-nudge      a nudge sent again for the reply to a nudge           NoDoubleNudge
#   ignore-limit      a nudge sent with no step left                        StepsBounded
#   placeholder       a second empty reply ends with "Done."                NoPlaceholder
#   nudge-text        a reply with text that stops for other is nudged      NudgeOnlyAfterEmptyOther
#   summarize-first   "Summarize what you just did." sent instead           EverySeparateEmptyNudged
#
# EmptyReplyTrace.tla checks turns of the built fx binary against the model;
# tests/tla/drivers/agent_runtime/driver.ts runs it.
#
# malformed-tool-call.cfg and malformed-tool-call-deep.cfg are the design of
# the feedback after a reply that ends with MALFORMED_FUNCTION_CALL and must
# pass. malformed-tool-call-today.cfg is fx before it, which waited and resent
# such a reply as a server failure (EveryStallGetsFeedback). Each
# malformed-tool-call-mutation-*.cfg plants one defect, and the rule it names
# must catch it:
#
#   no-cap            a third feedback in one step                          EndsAfterThird
#   backoff           feedback waits the backoff                            FeedbackRightAway
#   tools-off         feedback goes with tools off                          FeedbackKeepsTools
#   no-reset          the malformed count survives a step                   EveryStallGetsFeedback
#   run-call          a malformed reply's call runs                         MalformedNeverRuns
#   reconcile-loop    a malformed reply with tools off is resent            ReconcileMalformedStops
#   search-reconcile  a failed search start turns tools off                 SearchKeepsTools
#
# MalformedToolCallTrace.tla checks turns of the built fx binary against that
# model; tests/tla/drivers/agent_runtime/malformed.ts runs it.
#
# output-limit.cfg and output-limit-deep.cfg are the design of the recovery
# after a reply cut off at its output limit, and must pass.
# output-limit-today.cfg is fx before it, which dropped every call of a reply
# cut while it called tools and ended the turn (NoNeedlessFailure);
# output-limit-today-text.cfg is fx before it too, which ended a turn whose
# reply was cut before any tool call as completed (NoFalseSuccess). Each
# output-limit-mutation-*.cfg plants one defect, and the rule it names must
# catch it:
#
#   no-cap        a third note in a row                         EndsAfterThird
#   no-reset      the cut count survives a step that was not cut  EveryCutGetsNote
#   run-cut       a call the cut left unfinished runs           CutCallNeverRuns
#   ignore-limit  a note sent with no step left                 StepsBounded
#   no-raise      the turn keeps the limit that ran out         RaisedAfterCut
#   drop-parts    the answer keeps only the reply that ended it AnswerHasEveryPart
#
# OutputLimitTrace.tla checks turns of the built fx binary against that
# model; tests/tla/drivers/agent_runtime/output_limit.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh empty-reply empty-reply-mutation-no-reset
#   ./check.sh malformed-tool-call malformed-tool-call-mutation-no-cap
#   ./check.sh output-limit output-limit-mutation-no-cap
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
EmptyReply empty-reply -
EmptyReply empty-reply-deep -
EmptyReply empty-reply-today EverySeparateEmptyNudged
EmptyReply empty-reply-mutation-no-reset EverySeparateEmptyNudged
EmptyReply empty-reply-mutation-double-nudge NoDoubleNudge
EmptyReply empty-reply-mutation-ignore-limit StepsBounded
EmptyReply empty-reply-mutation-placeholder NoPlaceholder
EmptyReply empty-reply-mutation-nudge-text NudgeOnlyAfterEmptyOther
EmptyReply empty-reply-mutation-summarize-first EverySeparateEmptyNudged
MalformedToolCall malformed-tool-call -
MalformedToolCall malformed-tool-call-deep -
MalformedToolCall malformed-tool-call-today EveryStallGetsFeedback
MalformedToolCall malformed-tool-call-mutation-no-cap EndsAfterThird
MalformedToolCall malformed-tool-call-mutation-backoff FeedbackRightAway
MalformedToolCall malformed-tool-call-mutation-tools-off FeedbackKeepsTools
MalformedToolCall malformed-tool-call-mutation-no-reset EveryStallGetsFeedback
MalformedToolCall malformed-tool-call-mutation-run-call MalformedNeverRuns
MalformedToolCall malformed-tool-call-mutation-reconcile-loop ReconcileMalformedStops
MalformedToolCall malformed-tool-call-mutation-search-reconcile SearchKeepsTools
OutputLimit output-limit -
OutputLimit output-limit-deep -
OutputLimit output-limit-today NoNeedlessFailure
OutputLimit output-limit-today-text NoFalseSuccess
OutputLimit output-limit-mutation-no-cap EndsAfterThird
OutputLimit output-limit-mutation-no-reset EveryCutGetsNote
OutputLimit output-limit-mutation-run-cut CutCallNeverRuns
OutputLimit output-limit-mutation-ignore-limit StepsBounded
OutputLimit output-limit-mutation-no-raise RaisedAfterCut
OutputLimit output-limit-mutation-drop-parts AnswerHasEveryPart
VERDICTS
