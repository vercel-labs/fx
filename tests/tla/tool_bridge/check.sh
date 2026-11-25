#!/bin/sh
# Model-check ToolEdit, how a bash program's file edits reach fx, and
# require each config's expected verdict. This is a design model for
# `fx tool edit` and `fx tool write`. The code has landed: the bridge core,
# the file change, and the change tracker. The Bun driver in
# tests/tla/drivers/tool_bridge/ runs that real path along this model after
# TLC, see its last line, which FX_TLA_TOOL_BRIDGE_TLC_ONLY=1 skips.
#
# design-bridge and design-diff must pass. current-raw shows that today a
# program's own edits are invisible. bridge-raw and the diff-* configs show
# each design's limit: the bridge sees only edits made through it, and the
# diff blames the program for another process's write and reviews no exact
# edit. current-late-prompt shows the MCP bridge today: a queued request
# can open a prompt after its program is gone. An open prompt stays until
# the person answers it, by the bridge's recorded rule, and its answer runs
# nothing; no-answer-teardown shows that teardown waits for that answer. Each mutant-* config
# plants a bug that its property must catch. The simulate-* configs run
# random behaviors; SIM_RUNS sets how many (default 20000). The witness-*
# configs show that an edit is applied, prompted, and refused as stale.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
tlc_verdicts "$@" <<EOT
ToolEdit design-bridge -
ToolEdit design-diff -
ToolEdit current-raw RawEditsVisible
ToolEdit bridge-raw RawEditsVisible
ToolEdit diff-nonideal HonestReport
ToolEdit diff-review ExactReview
ToolEdit current-late-prompt NoAskAfterGone
ToolEdit no-answer-teardown temporal
ToolEdit mutant-no-recheck NoStaleApply
ToolEdit mutant-no-withdraw temporal
ToolEdit mutant-apply-after-gone NoApplyAfterGone
ToolEdit mutant-skip-review ExactReview
ToolEdit mutant-double-publish ShownOnce
ToolEdit witness-applied NeverApplied
ToolEdit witness-prompted NeverPrompted
ToolEdit witness-stale NeverStale
ToolEdit simulate-ideal simulate $sim
ToolEdit simulate-nonideal simulate $sim
EOT

# The driver: the design-bridge state graph walked on the real harness,
# code traces checked by TraceToolEdit.tla, and each planted bug in
# mutations.json caught. FX_TLA_TOOL_BRIDGE_QUICK=1 runs the quick settings.
# FX_TLA_TOOL_BRIDGE_TLC_ONLY=1 skips the driver and keeps the TLC verdicts,
# which every pull request checks in ci.yml.
if [ "${FX_TLA_TOOL_BRIDGE_TLC_ONLY:-0}" != "1" ]; then
    bun ../drivers/tool_bridge/verify.ts
fi
