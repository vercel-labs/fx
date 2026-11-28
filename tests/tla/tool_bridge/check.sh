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
# AgentWait models `fx tool agent wait`: the subagent's wait reads its cancel
# flag, and the bridge's agent operations call it with each request's flag.
# agent-design must pass. agent-mutant-ignore-cancel and
# agent-mutant-ignore-cancel-hang plant a wait that ignores its cancel flag, so
# a wait whose program is gone never ends and its bash call never returns.
# agent-mutant-yield-while-held plants a yield that ignores the bridge's hold,
# and agent-mutant-takes-mail plants a wait that takes the mail it saw, so the
# mail reaches no one. The agent-witness-* configs show a canceled wait, a
# quiet wait, a wait that ended on mail, and a wait refused after the first
# call yielded.
#
# AskWait models `fx tool ask`, the slice-8 design, built in src/core/tool_bridge/bridge.zig and src/core/tooling/tool_runtime.zig. A
# question holds the bridge's prompt lock until it ends, so one prompt shows at a
# time, and a watch withdraws a question whose program is gone. ask-design must
# pass. ask-mutant-watch-off removes the watch, so a gone program's bash call
# waits for a person who may never answer. ask-mutant-admission-lock-only holds
# the lock only for the permission check, as the bridge does today, so a second
# question fills the session's one question slot. The ask-witness-* configs show
# an answer, a withdrawn question, a request that gave up, Esc, a host with no
# question UI, a refusal after the yield, and two questions in turn.
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
AgentWait agent-design -
AgentWait agent-mutant-yield-while-held NoYieldWhileHeld
AgentWait agent-mutant-ignore-cancel temporal
AgentWait agent-mutant-ignore-cancel-hang temporal
AgentWait agent-mutant-takes-mail NoMailLost
AgentWait agent-witness-canceled NeverCanceled
AgentWait agent-witness-quiet NeverQuiet
AgentWait agent-witness-mail NeverMailAfterWait
AgentWait agent-witness-unavailable NeverUnavailable
AskWait ask-design -
AskWait ask-mutant-watch-off temporal
AskWait ask-mutant-admission-lock-only NoCrash
AskWait ask-witness-answered NeverAnswered
AskWait ask-witness-withdrawn NeverWithdrawn
AskWait ask-witness-gave-up NeverGaveUp
AskWait ask-witness-esc NeverEsc
AskWait ask-witness-no-ui NeverNoUi
AskWait ask-witness-unavailable NeverUnavailable
AskWait ask-witness-two-asked NeverTwoAsked
EOT

# The driver: the design-bridge state graph walked on the real harness,
# code traces checked by TraceToolEdit.tla, and each planted bug in
# mutations.json caught. The AgentWait graph is walked on the real subagent
# wait, its traces are checked by TraceAgentWait.tla, the bridge grace is timed,
# and each planted bug in agent-mutations.json is caught.
# FX_TLA_TOOL_BRIDGE_QUICK=1 runs the quick settings.
# FX_TLA_TOOL_BRIDGE_TLC_ONLY=1 skips the driver and keeps the TLC verdicts,
# which every pull request checks in ci.yml.
if [ "${FX_TLA_TOOL_BRIDGE_TLC_ONLY:-0}" != "1" ]; then
    bun ../drivers/tool_bridge/verify.ts
fi
