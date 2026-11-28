#!/bin/sh
# Model-check how a monitor's output reaches the agent with TLC, and require
# each config's expected verdict.
#
# current.cfg is the design and must pass. Each mutant-*.cfg plants one
# defect, and the rule it names must catch it:
#
#   lose-on-fail     a failed post commits the lines            NoLoss
#   ignore-gap       an event goes at any time                  GapKept
#   wake-quiet       a quiet command wakes the agent            NoQuietWake
#   no-dedupe        an event repeats the last one              NoRepeatWake
#   event-after-end  the loop posts after the end event         EndIsLast
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
Monitor mutant-lose-on-fail NoLoss
Monitor mutant-ignore-gap GapKept
Monitor mutant-wake-quiet NoQuietWake
Monitor mutant-no-dedupe NoRepeatWake
Monitor mutant-event-after-end EndIsLast
VERDICTS
