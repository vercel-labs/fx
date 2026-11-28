#!/bin/sh
# Model-check how a monitor's output reaches the agent with TLC, and require
# each config's expected verdict.
#
# current.cfg is the design and must pass. Each mutant-*.cfg plants one
# defect, and the rule it names must catch it:
#
#   ignore-gap       an event is made at any time               GapKept
#   wake-quiet       a quiet command makes an event             NoQuietWake
#   no-dedupe        an event repeats the last one              NoRepeatWake
#   event-after-end  an event follows the end event             EndIsLast
#   unbounded-held   the list keeps every event                 HeldBounded
#   post-when-full   a message goes into a full queue           OneQueued
#   lose-count       a dropped event is not counted             DropCounted
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh current mutant-no-dedupe
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
Monitor current -
Monitor mutant-ignore-gap GapKept
Monitor mutant-wake-quiet NoQuietWake
Monitor mutant-no-dedupe NoRepeatWake
Monitor mutant-event-after-end EndIsLast
Monitor mutant-unbounded-held HeldBounded
Monitor mutant-post-when-full OneQueued
Monitor mutant-lose-count DropCounted
VERDICTS
