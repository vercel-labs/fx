#!/bin/sh
# Model-check how the composer measures Thai text, places its cursor, draws a
# mark with no base, and shows the marks on a character in the last column
# (src/core/shared/display_width.zig, src/core/input/text_boundaries.zig,
# src/ui/input/visual_layout.zig, src/ui/footer/input_presentation.zig, and
# src/core/terminal/engine.zig) with TLC and require each config's expected
# verdict.
#
# display-width.cfg is the change and must pass, and so must the change in a
# window with no content cells (display-width-no-cells.cfg, two columns or
# narrower) and with one (display-width-one-cell.cfg, three columns). They
# check that a mark with no base takes one cell on a dotted circle and never
# joins the prompt's cell, and that a cell holds at most its limit of bytes
# and never fails a step. The limit is scaled down so that it binds.
# display-width-today.cfg is fx before it, which measured every Thai
# nonspacing mark as one cell (CursorAligned). display-width-today-margin.cfg
# is fx before it at the right margin, whose composer rows dropped the
# zero-width units after a full row (MarksShown). display-width-today-bare.cfg
# is fx before the change with a mark that has no base, which joined the
# prompt's cell (MarksShown), and display-width-today-limit.cfg is fx before
# the change with a cell that has no room for a mark, which failed the step
# (Alive).
# Each planted mutation must be caught by the rule it names:
#
#   sara-am          U+0E33 SARA AM measured as a mark                 RowAligned
#   split-cluster    nextCharacterEnd stops after one unit             StopsAtCells
#   wide-only-guard  only two-cell characters get the margin guard     MarksShown
#   no-cells-keeps   a row with no content cells puts the marks of     MarksShown
#                    undrawn characters on the prefix cell
#   circle-uncounted the circle is drawn, but the layout counts no     RowAligned
#                    cell for it
#   keep-all         the engine has no limit on a cell                 CellWithinCap
#
# The old bare-marks mutation, a row with no content cells that still drew
# the marks before its first unit, is gone: with the dotted circle no mark
# comes before the first unit.
#
# display-width-witness.cfg must reach a base with two stacked marks, the
# cursor after them, and more text to their right (NoStackedCluster), and the
# other two witnesses a dropped mark (NoCapDrop) and a mark with no base on
# its circle, text after it, and the cursor at the end (NoBareCircle), so the
# passing config is not vacuous.
#
# DisplayWidthTrace.tla checks walks of the built fx composer against the
# model; tests/tla/drivers/display_width/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh display-width display-width-today
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
DisplayWidth display-width -
DisplayWidth display-width-no-cells -
DisplayWidth display-width-one-cell -
DisplayWidth display-width-today CursorAligned
DisplayWidth display-width-today-margin MarksShown
DisplayWidth display-width-today-bare MarksShown
DisplayWidth display-width-today-limit Alive
DisplayWidth display-width-no-cells-keeps MarksShown
DisplayWidth display-width-mutation-sara-am RowAligned
DisplayWidth display-width-mutation-split-cluster StopsAtCells
DisplayWidth display-width-mutation-wide-only-guard MarksShown
DisplayWidth display-width-mutation-circle-uncounted RowAligned
DisplayWidth display-width-mutation-keep-all CellWithinCap
DisplayWidth display-width-witness NoStackedCluster
DisplayWidth display-width-witness-cap NoCapDrop
DisplayWidth display-width-witness-bare NoBareCircle
VERDICTS
