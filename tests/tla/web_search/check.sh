#!/bin/sh
# Model-check web search slots with TLC and require each config's verdict.
#
# web-search-slots.cfg is the design and must pass. Each mutation removes one
# mechanism, and the rule it names must catch it:
#
#   no-advance   a refusal waits for the user and resends as is   BoundedSends
#   no-team-key  a block outlives a team change                   NoStaleSkip
#   non-atomic   the block reads, then writes in a later step     OneNotice
#
# Usage:
#   ./check.sh
#   ./check.sh web-search-slots
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
WebSearchSlots web-search-slots -
WebSearchSlots web-search-slots-mutation-no-advance BoundedSends
WebSearchSlots web-search-slots-mutation-no-team-key NoStaleSkip
WebSearchSlots web-search-slots-mutation-non-atomic OneNotice
VERDICTS
