#!/bin/sh
# Model-check compaction for providers that bind reasoning to its prefix,
# and require each config's expected verdict.
#
# provider-compaction.cfg and provider-compaction-deep.cfg are the design:
# the provider writes the summary block, the newest turns stay unchanged
# after it or, when the running turn alone does not fit, its first message
# follows a block over everything; a failed provider compaction falls back
# to fx's summary with nothing but that message after it. They must pass.
#
#   today                          fx's summary with turns kept after it         NoDroppedReasoning
#   mutation-fallback-keeps        the fallback keeps turns or steps after it    NoDroppedReasoning
#   mutation-switch-sends-block    a switched-to model gets the old block        Readable
#   mutation-whole-forgets-task    the whole-turn compaction drops its message   TaskKept
#   mutation-keeps-foreign-reasoning  another model's steps keep their reasoning
#                                  after a block                                 NoDroppedReasoning
#
# Usage: ./check.sh [config ...]
set -eu
cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh
tlc_verdicts "$@" <<'VERDICTS'
ProviderCompaction provider-compaction - -deadlock
ProviderCompaction provider-compaction-deep - -deadlock
ProviderCompaction provider-compaction-today NoDroppedReasoning -deadlock
ProviderCompaction provider-compaction-mutation-fallback-keeps NoDroppedReasoning -deadlock
ProviderCompaction provider-compaction-mutation-switch-sends-block Readable -deadlock
ProviderCompaction provider-compaction-mutation-whole-forgets-task TaskKept -deadlock
ProviderCompaction provider-compaction-mutation-keeps-foreign-reasoning NoDroppedReasoning -deadlock
VERDICTS
