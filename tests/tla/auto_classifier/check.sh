#!/bin/sh
# Model-check what an automatic permission review sends to its provider
# (src/core/permissions/auto_classifier.zig Reviewer.review and the reviewer
# edges in src/gateway/chat_completions.zig, responses_permission_reviewer.zig,
# and src/builtins/gateway/permission_reviewer.zig) with TLC, and require each
# config's expected verdict.
#
# review-packet.cfg is the design and must pass: the Chat Completions edge
# sends only the instruction and the user context, never the pending
# assistant call. review-packet-today-*.cfg is fx before it: a DeepSeek
# thinking endpoint that cannot restore the call's omitted reasoning answers
# 400 (ReviewNeverRejected), and one that restores it from the tool-call ID
# hands the main agent's reasoning to the reviewer (NoReasoningToReviewer).
# review-packet-placeholder-if-empty-counts.cfg shows that an empty
# reasoning_content placeholder works only if the endpoint counts "" as passed
# back. Each review-packet-mutation-*.cfg plants one defect, and the rule it
# names must catch it:
#
#   placeholder     an empty reasoning_content the endpoint treats as missing  NoReasoningToReviewer
#   replay          the core forwards the call's real reasoning              NoReasoningToReviewer
#   core-text-only  the core drops the pending call for every provider       SharedPacketsUnchanged
#
# ReviewPacketTrace.tla checks runs of the built fx binary against the model;
# tests/tla/drivers/auto_classifier/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh review-packet review-packet-today-reject
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
ReviewPacket review-packet -
ReviewPacket review-packet-today-reject ReviewNeverRejected
ReviewPacket review-packet-today-restore NoReasoningToReviewer
ReviewPacket review-packet-placeholder-if-empty-counts -
ReviewPacket review-packet-mutation-placeholder NoReasoningToReviewer
ReviewPacket review-packet-mutation-replay NoReasoningToReviewer
ReviewPacket review-packet-mutation-core-text-only SharedPacketsUnchanged
VERDICTS
