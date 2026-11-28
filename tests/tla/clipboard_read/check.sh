#!/bin/sh
# Model-check reading a macOS clipboard image for /paste and Ctrl+V
# (ClipboardRead.tla; src/core/images/clipboard_read.zig and its wiring)
# with TLC and require each config's expected verdict.
#
# clipboard-read.cfg is the design and must pass. clipboard-read-blocking*.cfg
# is fx before it, where the input loop ran osascript itself (I414). Each
# clipboard-read-mutation-*.cfg plants one defect, and the rule it names must
# catch it:
#
#   no-guard         a second paste starts a second osascript          OneChild
#   no-timeout       nothing stops an osascript that never exits       ReadEnds
#   no-cancel        shutdown waits out the deadline                   ShutdownNeverWaitsForDeadline
#   screen-agent     the image goes to the agent on screen             ImageToRequester
#   drop-hidden      the image is dropped when its agent is hidden     DropOnlyWhenClosed
#   no-forget        a new agent at a closed one's address takes it    ImageToRequester
#   no-borrow-check  the image goes into the picker's composer         PickerComposerUntouched
#   silent-drop      shutdown frees a read without logging it          EveryReadSettles
#
# The trace-*.cfg configs check TraceClipboardRead, the checker the driver
# uses, on the sample runs in ClipboardTraces.tla: three runs of the design
# are accepted, and two runs of fx before this change are rejected with a
# deadlock. tests/tla/drivers/clipboard_read/driver.ts checks runs of the
# built fx the same way.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh clipboard-read clipboard-read-mutation-no-guard
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu
cd "$(dirname "$0")"
. ../lib/tlc.sh
tlc_verdicts "$@" <<'VERDICTS'
ClipboardRead clipboard-read -
ClipboardRead clipboard-read-blocking LoopNeverWaits
ClipboardRead clipboard-read-blocking-keys temporal
ClipboardRead clipboard-read-mutation-no-guard OneChild
ClipboardRead clipboard-read-mutation-no-timeout temporal
ClipboardRead clipboard-read-mutation-no-cancel ShutdownNeverWaitsForDeadline
ClipboardRead clipboard-read-mutation-screen-agent ImageToRequester
ClipboardRead clipboard-read-mutation-drop-hidden DropOnlyWhenClosed
ClipboardRead clipboard-read-mutation-no-forget ImageToRequester
ClipboardRead clipboard-read-mutation-no-borrow-check PickerComposerUntouched
ClipboardRead clipboard-read-mutation-silent-drop EveryReadSettles
TraceClipboardRead trace-image -
TraceClipboardRead trace-timeout -
TraceClipboardRead trace-quit -
TraceClipboardRead trace-silent-paste deadlock
TraceClipboardRead trace-stalled deadlock
VERDICTS
