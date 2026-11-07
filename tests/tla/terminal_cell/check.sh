#!/bin/sh
# Model-check what a terminal cell does with the zero-width units written on
# it after its base character (TerminalCell.tla; appendCombiningSuffix in
# src/core/terminal/engine.zig) with TLC and require each config's expected
# verdict.
#
# terminal-cell.cfg is the design and must pass: fx keeps running, the cell
# holds at most Cap bytes of base plus suffix, a dropped unit does not move the
# cursor, the result does not depend on where the reads cut the stream, kept
# marks stay, and a unit that has room is kept. terminal-cell-today.cfg is fx
# before the change, which exited when a cell was full (StaysRunning), and
# terminal-cell-today-live.cfg shows the same as a liveness failure: the feed
# never completes. Each terminal-cell-mutation-*.cfg plants one defect, and the
# rule it names must catch it:
#
#   suffix-only     the cap counts the suffix alone, as before       CellWithinCap
#   cursor          a dropped unit advances the cursor               CursorAligned
#   call-atomic     a read that does not fit whole is dropped whole  SplitIndependent
#   stop-at-first   after one drop, every later unit is dropped      GreedyFits
#   evict-earlier   a unit that does not fit pushes earlier ones out KeepsEarlier
#
# The two witness configs must reach a drop and a unit kept after a drop
# (NoDrop, NoDropThenKeep), so the passing config is not vacuous.
#
# tests/tla/drivers/terminal_cell/driver.ts replays long runs of marks through
# the built fx and has TLC check each one against this model
# (TerminalCellTrace.tla).
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh terminal-cell terminal-cell-today
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu
cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh
tlc_verdicts "$@" <<'VERDICTS'
TerminalCell terminal-cell -
TerminalCell terminal-cell-today StaysRunning
TerminalCell terminal-cell-today-live temporal
TerminalCell terminal-cell-mutation-suffix-only CellWithinCap
TerminalCell terminal-cell-mutation-cursor CursorAligned
TerminalCell terminal-cell-mutation-call-atomic SplitIndependent
TerminalCell terminal-cell-mutation-stop-at-first GreedyFits
TerminalCell terminal-cell-mutation-evict-earlier KeepsEarlier
TerminalCell terminal-cell-witness-drop NoDrop
TerminalCell terminal-cell-witness-keep NoDropThenKeep
VERDICTS
