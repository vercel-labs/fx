#!/bin/sh
# Model-check a wait on a running shell command and its quiet notice with
# TLC, and require each config's expected verdict.
#
# quiet-wait.cfg and quiet-wait-deep.cfg are the design and must pass. Each
# quiet-wait-mutation-*.cfg plants one defect, and the rule it names must
# catch it:
#
#   notice-any-quiet  the notice shows for any quiet time                 NoticeRule
#   notice-when-done  the notice shows on a finished command              NoticeRule
#   end-unarmed       a wait that began past the limit ends for quiet     QuietEndNeedsCrossing
#   no-crossing-end   a wait never ends at the crossing                   CrossingEnds
#   no-rearm          output during a wait does not arm it                CrossingEnds
#   ceiling-late      a wait runs one tick past its ceiling               WaitBounded
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh quiet-wait quiet-wait-mutation-no-rearm
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
QuietWait quiet-wait -
QuietWait quiet-wait-deep -
QuietWait quiet-wait-mutation-notice-any-quiet NoticeRule
QuietWait quiet-wait-mutation-notice-when-done NoticeRule
QuietWait quiet-wait-mutation-end-unarmed QuietEndNeedsCrossing
QuietWait quiet-wait-mutation-no-crossing-end CrossingEnds
QuietWait quiet-wait-mutation-no-rearm CrossingEnds
QuietWait quiet-wait-mutation-ceiling-late WaitBounded
VERDICTS
