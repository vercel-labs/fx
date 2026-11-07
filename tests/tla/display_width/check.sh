#!/bin/sh
# Model-check how the composer measures Thai text, places its cursor, and
# shows the marks on a character in the last column
# (src/core/shared/display_width.zig, src/core/input/text_boundaries.zig,
# src/ui/footer/input_presentation.zig, and src/core/terminal/engine.zig) with
# TLC and require each config's expected verdict.
#
# display-width.cfg is the change and must pass. display-width-today.cfg is fx
# before it, which measured every Thai nonspacing mark as one cell
# (CursorAligned). display-width-today-margin.cfg is fx before it at the right
# margin, whose composer rows dropped the zero-width units after a full row
# (MarksShown). Each planted mutation must be caught by the rule it names:
#
#   sara-am          U+0E33 SARA AM measured as a mark                 RowAligned
#   split-cluster    nextCharacterEnd stops after one unit             StopsAtCells
#   wide-only-guard  only two-cell characters get the margin guard     MarksShown
#
# display-width-witness.cfg must reach a base with two stacked marks, the
# cursor after them, and more text to their right (NoStackedCluster), so the
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
DisplayWidth display-width-today CursorAligned
DisplayWidth display-width-today-margin MarksShown
DisplayWidth display-width-mutation-sara-am RowAligned
DisplayWidth display-width-mutation-split-cluster StopsAtCells
DisplayWidth display-width-mutation-wide-only-guard MarksShown
DisplayWidth display-width-witness NoStackedCluster
VERDICTS
