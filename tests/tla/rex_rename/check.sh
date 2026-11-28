#!/bin/sh
# Model-check the Rex session rename queue with TLC and require each config's
# expected verdict.
#
# rex-rename.cfg and rex-rename-deep.cfg are the design and must pass. Each
# rex-rename-mutation-*.cfg plants one defect, and the rule it names must
# catch it:
#
#   start-without-await       a second task starts before the last one ended   AtMostOneTask
#   end-without-lock          the task marks itself ended outside the mutex    NewestApplied
#   end-without-lock-waiting  the same, seen as a title with no taker          WaitingOnlyWhileRunning
#   apply-after-stop          take hands out a title after the stop            NoApplyAfterStop
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh rex-rename rex-rename-mutation-end-without-lock
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
RexRename rex-rename -
RexRename rex-rename-deep -
RexRename rex-rename-mutation-start-without-await AtMostOneTask
RexRename rex-rename-mutation-end-without-lock NewestApplied
RexRename rex-rename-mutation-end-without-lock-waiting WaitingOnlyWhileRunning
RexRename rex-rename-mutation-apply-after-stop NoApplyAfterStop
VERDICTS
