#!/bin/sh
# Model-check the empty-reply nudge in the agent step loop
# (src/core/agent/runtime/orchestrator.zig) with TLC and require each
# config's expected verdict.
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

# ToolArena.tla is where a turn keeps its tool calls' memory: each call runs
# on its own arena, and only its result moves to the turn
# (src/core/agent/runtime/orchestrator.zig, src/core/tooling/tool_runtime.zig
# executeRegisteredTool). tool-arena.cfg is the design and must pass.
# tool-arena-today.cfg is fx before it, which ran every call but a file
# mutation on the turn's arena (TurnKeepsOnlyResults). Each
# tool-arena-mutation-*.cfg plants one defect, and the rule it names must
# catch it:
#
#   shallow-copy         tool_result_memory stays on the call's arena     NoDanglingHistory
#   dupe-error-code      McpInputRequired is duped onto the turn          ErrorCodeOutlivesTurn
#   backend-call-arena   shell and vision complete on the call's arena    NoDanglingHistory
#   error-on-call-arena  a tool's error is formatted on the call's arena  NoDanglingHistory
#   free-before-copy     the arena goes before the result is copied out   NoReadAfterFree
#   leak-on-return       a turn-ending call keeps its arena               CallArenaFreed
#
# ToolArenaTrace.tla checks turns of the built fx binary against the model;
# tests/tla/drivers/agent_runtime/tool_arena.ts runs it.
tlc_verdicts "$@" <<'VERDICTS'
ToolArena tool-arena -
ToolArena tool-arena-today TurnKeepsOnlyResults
ToolArena tool-arena-mutation-shallow-copy NoDanglingHistory
ToolArena tool-arena-mutation-dupe-error-code ErrorCodeOutlivesTurn
ToolArena tool-arena-mutation-backend-call-arena NoDanglingHistory
ToolArena tool-arena-mutation-error-on-call-arena NoDanglingHistory
ToolArena tool-arena-mutation-free-before-copy NoReadAfterFree
ToolArena tool-arena-mutation-leak-on-return CallArenaFreed
EmptyReply empty-reply -
EmptyReply empty-reply-deep -
EmptyReply empty-reply-today EverySeparateEmptyNudged
EmptyReply empty-reply-mutation-no-reset EverySeparateEmptyNudged
EmptyReply empty-reply-mutation-double-nudge NoDoubleNudge
EmptyReply empty-reply-mutation-ignore-limit StepsBounded
EmptyReply empty-reply-mutation-placeholder NoPlaceholder
EmptyReply empty-reply-mutation-nudge-text NudgeOnlyAfterEmptyOther
EmptyReply empty-reply-mutation-summarize-first EverySeparateEmptyNudged
VERDICTS
