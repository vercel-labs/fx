#!/bin/sh
# Model-check the empty-reply nudge in the agent step loop and the reading
# of request-wrapped tool calls (src/core/agent/runtime/orchestrator.zig)
# with TLC and require each config's expected verdict.
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
# RequestWrapper.tla models a shell, read_tool_result, or subagent call
# whose arguments sit in a `request` wrapper, as an object or as its JSON
# text. request-wrapper.cfg is the design and must pass.
# request-wrapper-today.cfg is fx before it, which refused the JSON text
# (ExactWrapperRuns). Each request-wrapper-mutation-*.cfg plants one defect,
# and the rule it names must catch it:
#
#   no-bound      text longer than the bound is read           BadTextRefused
#   siblings      the text form drops the fields beside it     SiblingsNotDropped
#   replay-raw    read_tool_result replays the text as sent    ReplayFlat
#   decode-side   shell's decoder reads the text, so the call  ReplayFlat
#                 is admitted and saved wrapped
#
# RequestWrapperTrace.tla checks calls of the built fx binary against the
# model; tests/tla/drivers/agent_runtime/request-wrapper.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh empty-reply empty-reply-mutation-no-reset
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
RequestWrapper request-wrapper -
RequestWrapper request-wrapper-today ExactWrapperRuns
RequestWrapper request-wrapper-mutation-no-bound BadTextRefused
RequestWrapper request-wrapper-mutation-siblings SiblingsNotDropped
RequestWrapper request-wrapper-mutation-replay-raw ReplayFlat
RequestWrapper request-wrapper-mutation-decode-side ReplayFlat
VERDICTS
