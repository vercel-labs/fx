#!/bin/sh
# Model-check how fx reads a streamed Chat Completions reply on a configured
# connection (src/gateway/chat_completions_protocol.zig) with TLC and require
# each config's expected verdict.
#
# chat-stream.cfg is the design and must pass: fx fails a reply only when the
# server left the language a healthy server speaks, completes one only when it
# did not, and records the trailer's usage count, or without a trailer the
# largest count a chunk with a choice carried (RecordsUsage).
# chat-stream-today.cfg is fx before these changes, which failed benign
# replies (BenignNeverFails). Each chat-stream-old-*.cfg is one of its rules
# alone, and the rule it names must catch it:
#
#   old-model           an empty model is an error                   EmptyModelAccepted
#   old-function-call   an empty legacy function_call is an error    PlaceholderAccepted
#   old-eof             a close after the finished choice is cut off EndAfterFinishCompletes
#   old-reason          a trailer needs its finish_reason            TrailerReasonOptional
#   old-progress-usage  a usage count that falls on a chunk with a   ProgressUsageProvisional
#                       choice is an error
#   old-finish-usage    the finish chunk's usage is final, so a      FinishUsageProvisional
#                       per-chunk count there fails the turn
#
# Each chat-stream-mutation-*.cfg plants one bug that accepts too much or
# records the wrong usage:
#
#   eof-any-phase   a close before the finished choice completes   CutStreamsFail
#   skip-models     a second, different model is not checked       IdentityHeld
#   accept-call     a legacy function_call that names a call passes LegacyCallRefused
#   late-content    content in a trailer passes                    TrailerCarriesNoContent
#   no-usage        a repeated choice without usage passes         TrailerCarriesUsage
#   skip-tools      the finish reason need not match the calls     ToolsMatchReason
#   lax-final       a trailer count that falls is dropped too      FinalUsageHeld
#   skip-progress   usage on chunks with a choice is ignored       RecordsUsage
#
# ChatStreamTrace.tla checks replies of the built fx binary against the model;
# tests/tla/drivers/chat_completions/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh chat-stream chat-stream-old-eof
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
ChatStream chat-stream -
ChatStream chat-stream-today BenignNeverFails
ChatStream chat-stream-old-model EmptyModelAccepted
ChatStream chat-stream-old-function-call PlaceholderAccepted
ChatStream chat-stream-old-eof EndAfterFinishCompletes
ChatStream chat-stream-old-reason TrailerReasonOptional
ChatStream chat-stream-old-progress-usage ProgressUsageProvisional
ChatStream chat-stream-old-finish-usage FinishUsageProvisional
ChatStream chat-stream-mutation-eof-any-phase CutStreamsFail
ChatStream chat-stream-mutation-skip-models IdentityHeld
ChatStream chat-stream-mutation-accept-call LegacyCallRefused
ChatStream chat-stream-mutation-late-content TrailerCarriesNoContent
ChatStream chat-stream-mutation-no-usage TrailerCarriesUsage
ChatStream chat-stream-mutation-skip-tools ToolsMatchReason
ChatStream chat-stream-mutation-lax-final FinalUsageHeld
ChatStream chat-stream-mutation-skip-progress RecordsUsage
VERDICTS
