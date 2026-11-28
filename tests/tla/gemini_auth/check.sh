#!/bin/sh
# Model-check fx processes sharing one Google Gemini DPoP-bound login
# (GeminiDpopRefresh.tla), and require each config's expected verdict.
#
# design-a and design-a-no-rotate hold every invariant and Settles.
# design-b-no-rotate fails SignOutSticks (a late refresh write restores the
# saved login after SignOut deletes it; concurrent refreshes also violate
# NoStaleOverwrite).
# design-b-rotate now reports SignOutSticks first at depth 7 (before
# NoSpentRefresh at depth 10) because SignOutSticks is checked in all configs.
# mutant-signout-unlocked (Design A without locking SignOut) fails SignOutSticks.
#
# tests/tla/drivers/gemini_auth/ runs real fx along GeminiDpopRefreshTrace.tla:
#   zig build && cd tests/tla/drivers/gemini_auth && bun test
#
# Usage:
#   ./check.sh
#   ./check.sh design-a design-b-no-rotate
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
tlc_verdicts "$@" <<EOF
GeminiDpopRefresh design-a -
GeminiDpopRefresh design-a-no-rotate -
GeminiDpopRefresh design-b-no-rotate SignOutSticks
GeminiDpopRefresh design-b-rotate SignOutSticks
GeminiDpopRefresh mutant-unbounded-nonce-retry NonceRetryAtMostOnce
GeminiDpopRefresh mutant-clear-on-offline ClearOnlyWithCause
GeminiDpopRefresh mutant-decide-outside-lock NoSpentRefresh
GeminiDpopRefresh mutant-signout-unlocked SignOutSticks
GeminiDpopRefresh simulate-ideal simulate $sim
GeminiDpopRefresh simulate-nonideal simulate $sim
EOF
