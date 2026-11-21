#!/bin/sh
# Model-check the compaction row's number with TLC and require each config's
# expected verdict.
#
# compaction-progress.cfg and compaction-progress-deep.cfg are the design and
# must pass. The other configs must each break the rule they name:
#
#   compaction-progress-today                fx before: the row is 0% while the model reads  WaitingMoves
#   compaction-progress-mutation-ask-resets  a new request starts the row again from zero    CountNeverFalls
#   compaction-progress-mutation-no-rebase   a new request counts notes already shown        AskKeepsTheCount
#   compaction-progress-mutation-thaw        the wait earns after the notes arrive           OnlyNotesMoveAfterNotes
#   compaction-progress-mutation-unbounded   a wait can earn all the room that is left       WaitIsBounded
#   compaction-progress-mutation-no-cap      the row reaches 100% before saving              FullOnlyWhenSaving
#   compaction-progress-mutation-keeps-old   a new compaction keeps the last one's numbers   StartsClean
#   compaction-progress-mutation-clock-back  a clock set back takes the wait back            CountNeverFalls
#
# Then run the driver, which walks src/core/output/compaction_progress.zig
# along the model's graph:
#   bun tests/tla/drivers/compaction_progress/driver.ts --self-check
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh compaction-progress compaction-progress-today
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
CompactionProgress compaction-progress -
CompactionProgress compaction-progress-deep -
CompactionProgress compaction-progress-today WaitingMoves
CompactionProgress compaction-progress-mutation-ask-resets CountNeverFalls
CompactionProgress compaction-progress-mutation-no-rebase AskKeepsTheCount
CompactionProgress compaction-progress-mutation-thaw OnlyNotesMoveAfterNotes
CompactionProgress compaction-progress-mutation-unbounded WaitIsBounded
CompactionProgress compaction-progress-mutation-no-cap FullOnlyWhenSaving
CompactionProgress compaction-progress-mutation-keeps-old StartsClean
CompactionProgress compaction-progress-mutation-clock-back CountNeverFalls
VERDICTS
