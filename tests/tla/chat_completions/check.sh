#!/bin/sh
# Model-check how fx reads a streamed Chat Completions reply on a configured
# connection (src/gateway/chat_completions_protocol.zig) with TLC and require
# each config's expected verdict.
#
# chat-stream.cfg is the design and must pass: fx fails a reply only when the
# server left the language a healthy server speaks, and completes one only
# when it did not. chat-stream-today.cfg is fx before the change, which failed
# benign replies (BenignNeverFails). Each chat-stream-old-*.cfg is one of its
# rules alone, and the rule it names must catch it:
#
#   old-model           an empty model is an error                   EmptyModelAccepted
#   old-function-call   an empty legacy function_call is an error    PlaceholderAccepted
#   old-eof             a close after the finished choice is cut off EndAfterFinishCompletes
#   old-reason          a trailer needs its finish_reason            TrailerReasonOptional
#
# Each chat-stream-mutation-*.cfg plants one bug that accepts too much:
#
#   eof-any-phase   a close before the finished choice completes   CutStreamsFail
#   skip-models     a second, different model is not checked       IdentityHeld
#   accept-call     a legacy function_call that names a call passes LegacyCallRefused
#   late-content    content in a trailer passes                    TrailerCarriesNoContent
#   no-usage        a repeated choice without usage passes         TrailerCarriesUsage
#   skip-tools      the finish reason need not match the calls     ToolsMatchReason
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
ChatStream chat-stream-mutation-eof-any-phase CutStreamsFail
ChatStream chat-stream-mutation-skip-models IdentityHeld
ChatStream chat-stream-mutation-accept-call LegacyCallRefused
ChatStream chat-stream-mutation-late-content TrailerCarriesNoContent
ChatStream chat-stream-mutation-no-usage TrailerCarriesUsage
ChatStream chat-stream-mutation-skip-tools ToolsMatchReason
VERDICTS
