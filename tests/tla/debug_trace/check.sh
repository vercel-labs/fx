#!/bin/sh
# Model-check the turn, step, and subagent ids fx hands out
# (src/core/shared/debug_trace.zig) and the tool block each step's calls join
# on the screen, with TLC, and require each config's expected verdict.
#
# trace-ids.cfg is the design and must pass. trace-ids-wasi-constant.cfg and
# trace-ids-wasi-constant-turns.cfg are fx-term.wasm before it, which gave
# every turn and step id 1: a call after text joined the block above the text
# (TextSplitsBlocks), and a later turn's calls carried a finished turn's id,
# which the transcript refuses, and showed nowhere (EveryCallShows). Each
# trace-ids-mutation-*.cfg plants one defect, and the rule it names must
# catch it:
#
#   step-constant      only step ids stay 1             TextSplitsBlocks
#   turn-constant      only turn ids stay 1             EveryCallShows
#   subagent-constant  only subagent ids stay 1         DistinctIds
#   zero-start         counters start at 0, "no id"     IdsNonZero
#
# TraceIdsTrace.tla checks sessions of the built fx-term.wasm against the
# model; tests/tla/drivers/debug_trace/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh trace-ids trace-ids-wasi-constant
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
TraceIds trace-ids -
TraceIds trace-ids-wasi-constant TextSplitsBlocks
TraceIds trace-ids-wasi-constant-turns EveryCallShows
TraceIds trace-ids-mutation-step-constant TextSplitsBlocks
TraceIds trace-ids-mutation-turn-constant EveryCallShows
TraceIds trace-ids-mutation-subagent-constant DistinctIds
TraceIds trace-ids-mutation-zero-start IdsNonZero
VERDICTS
