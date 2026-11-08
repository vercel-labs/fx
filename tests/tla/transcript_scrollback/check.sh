#!/bin/sh
# Model-check where a resumed session's rows go between the screen and the
# scrollback, and require each config's expected verdict.
#
# scrollback.cfg is the design and must pass. The scrollback-today-*.cfg files
# are origin/main's rule, which loses the rows that the first frame after the
# handoff covers, and each law named must catch it. Each mutation-*.cfg plants
# one more defect in the design:
#
#   overscroll   scrolls one row too many                          NothingBoth
#   undercount   scrolls one row too few                           NothingAbove
#   mark-ahead   claims a row that is not in scrollback            MarkHonest
#   keep-mark    leaves the handoff mark armed for a later frame   NothingBoth
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh scrollback scrollback-today-above
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
TranscriptScrollback scrollback -
TranscriptScrollback scrollback-today-above NothingAbove
TranscriptScrollback scrollback-today-mark MarkHonest
TranscriptScrollback scrollback-today-order InOrderOnce
TranscriptScrollback mutation-overscroll NothingBoth
TranscriptScrollback mutation-undercount NothingAbove
TranscriptScrollback mutation-mark-ahead MarkHonest
TranscriptScrollback mutation-keep-mark NothingBoth
VERDICTS
