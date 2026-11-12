#!/bin/sh
# Model-check the thinking row's clocks with TLC and require each config's
# expected verdict.
#
# turn-clock.cfg and turn-clock-deep.cfg are the design and must pass. The
# other configs must each break the rule they name:
#
#   turn-clock-today                   fx before: compaction time is added to the turn   CompactionTimeExcluded
#   compaction-clock-today             fx before: automatic compaction shows the turn's clock  CompactionCountsFromZero
#   turn-clock-mutation-no-shift       the clock is not moved past a finished wait        TurnClockCountsWork
#   turn-clock-mutation-visible-holds  failed feedback on screen holds the clock          RunsWhenNothingWaits
#   turn-clock-mutation-stage-restart  each compaction step restarts its clock            CompactionCountsFromZero
#   turn-clock-mutation-falls          a lower count replaces a higher one                CountNeverFalls
#   turn-clock-mutation-no-cap         the count reaches 100% before saving               FullOnlyWhenSaving
#   turn-clock-mutation-stale-applies  a late count for an older compaction counts        CountIsThisCompactions
#   turn-clock-mutation-keeps-old      a new compaction starts from the last one's count  CountIsThisCompactions
#
# Then run the driver, which walks src/core/output/turn_clock.zig along the
# model's graph: bun tests/tla/drivers/turn_clock/driver.ts --self-check
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh turn-clock turn-clock-today
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
TurnClock turn-clock -
TurnClock turn-clock-deep -
TurnClock turn-clock-today CompactionTimeExcluded
TurnClock compaction-clock-today CompactionCountsFromZero
TurnClock turn-clock-mutation-no-shift TurnClockCountsWork
TurnClock turn-clock-mutation-visible-holds RunsWhenNothingWaits
TurnClock turn-clock-mutation-stage-restart CompactionCountsFromZero
TurnClock turn-clock-mutation-falls CountNeverFalls
TurnClock turn-clock-mutation-no-cap FullOnlyWhenSaving
TurnClock turn-clock-mutation-stale-applies CountIsThisCompactions
TurnClock turn-clock-mutation-keeps-old CountIsThisCompactions
VERDICTS
