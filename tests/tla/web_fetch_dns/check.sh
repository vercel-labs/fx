#!/bin/sh
# Model-check WebFetchDns: web_fetch DNS lookup vs turn cancellation and
# hop deadline (src/tools/web/http_fetch.zig).
#
# design-b and design-a-interruptible must pass. current and design-a (when
# getaddrinfo ignores/retries signals) violate CancelIsPrompt. Each mutant-*
# plants one defect that its named invariant must catch.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
tlc_verdicts "$@" <<EOF
WebFetchDns current CancelIsPrompt
WebFetchDns design-a CancelIsPrompt
WebFetchDns design-a-interruptible -
WebFetchDns design-b -
WebFetchDns mutant-a-no-check CancelIsPrompt
WebFetchDns mutant-b-caller-frees-early NoUseAfterReturn
WebFetchDns mutant-b-non-atomic NoUseAfterReturn
WebFetchDns mutant-b-reads-caller-flag NoUseAfterReturn
WebFetchDns mutant-b-no-deadline DeadlineStillWorks
WebFetchDns simulate-ideal simulate $sim
WebFetchDns simulate-nonideal simulate $sim
EOF
