#!/bin/sh
# Model-check AcpEof: stdin EOF vs outbound requests (permission, host tool,
# journal flush) in src/acp/server.zig and src/acp/prompt.zig.
#
# design-a and design-b must pass. current shows today's unbounded wait after
# EOF; mutant-* plant single defects that their named invariants must catch.
# simulate-ideal and simulate-nonideal run random simulation walks.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
tlc_verdicts "$@" <<EOF
AcpEof current NoWaitAfterEof
AcpEof design-a -
AcpEof design-b -
AcpEof mutant-no-check NoWaitAfterEof
AcpEof mutant-unlocked NoWaitAfterEof
AcpEof mutant-cancel-latch ClientStillServed
AcpEof mutant-b-no-loop NoWaitAfterEof
AcpEof simulate-ideal simulate $sim
AcpEof simulate-nonideal simulate $sim
EOF
