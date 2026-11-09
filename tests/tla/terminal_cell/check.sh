#!/bin/sh
# Model-check what a terminal cell does with the zero-width units written on
# it after its base character (TerminalCell.tla; appendCombiningSuffix in
# src/core/terminal/engine.zig) with TLC and require each config's expected
# verdict.
#
# terminal-cell.cfg is the design and must pass: fx keeps running however full
# a cell or the grid's suffix pool is, the cell holds at most Cap bytes of base
# plus suffix, a dropped unit does not move the cursor, the result does not
# depend on where the reads cut the stream, kept marks stay, a unit that has
# room in the cell and the pool is kept, and every unit is either kept, with
# one pool entry, or dropped and counted. terminal-cell-today.cfg is fx before
# the cell cap, which exited when a cell was full (StaysRunning), and
# terminal-cell-today-live.cfg shows the same as a liveness failure: the feed
# never completes. terminal-cell-pool-today.cfg is fx with the cell cap but
# before the pool change, which exited when the pool was full (StaysRunning).
# Each terminal-cell-mutation-*.cfg plants one defect, and the rule it names
# must catch it:
#
#   suffix-only         the cap counts the suffix alone, as before      CellWithinCap
#   cursor              a dropped unit advances the cursor              CursorAligned
#   call-atomic         a read that does not fit whole is dropped whole SplitIndependent
#   stop-at-first       after one drop, every later unit is dropped     GreedyFits
#   evict-earlier       a unit that does not fit pushes earlier ones out KeepsEarlier
#   pool-evict-earlier  a unit the full pool drops pushes earlier out   KeepsEarlier
#   pool-cursor         a unit the full pool drops advances the cursor  CursorAligned
#
# The witness configs must reach a drop, a unit kept after a drop, and a drop
# by the full pool (NoDrop, NoDropThenKeep, NoPoolDrop), so the passing config
# is not vacuous.
#
# tests/tla/drivers/terminal_cell/driver.ts replays long runs of marks through
# the built fx, and tapes that fill the whole suffix pool before the marks, and
# has TLC check each one against this model (TerminalCellTrace.tla).
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
TerminalCell terminal-cell-pool-today StaysRunning
TerminalCell terminal-cell-mutation-suffix-only CellWithinCap
TerminalCell terminal-cell-mutation-cursor CursorAligned
TerminalCell terminal-cell-mutation-call-atomic SplitIndependent
TerminalCell terminal-cell-mutation-stop-at-first GreedyFits
TerminalCell terminal-cell-mutation-evict-earlier KeepsEarlier
TerminalCell terminal-cell-mutation-pool-evict-earlier KeepsEarlier
TerminalCell terminal-cell-mutation-pool-cursor CursorAligned
TerminalCell terminal-cell-witness-drop NoDrop
TerminalCell terminal-cell-witness-keep NoDropThenKeep
TerminalCell terminal-cell-witness-pool-drop NoPoolDrop
VERDICTS
