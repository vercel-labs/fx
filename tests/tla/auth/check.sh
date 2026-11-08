#!/bin/sh
# Model-check a Grok or Codex subscription login (src/core/auth/) and an MCP
# login (src/mcp/auth/client.zig) with TLC and require each config's expected
# verdict: how fx reads the saved expiry, and skew for MCP, and who holds the
# refresh token while a refresh reply is checked and saved.
#
# refresh.cfg is the design and must pass. The refresh-today-*.cfg configs are
# fx before the fix, and the refresh-mutation-*.cfg configs each plant one
# defect. The rule each names must catch it:
#
#   today-late-clear        the rotated token left the reply only after the
#                           lifetime check, so a failed check freed it twice  NoDoubleFree
#   today-checked-deadline  a checked subtraction of the one-minute margin
#                           aborted fx on a saved expiry near i64's minimum   NoAbort
#   today-plain-skew        an MCP request added the saved skew to the clock
#                           with a checked +, which aborted fx on a skew
#                           near i64's maximum                                NoAbort
#   mutation-keep-login     a refresh that fails keeps the saved login        BadReplySignsOut
#   mutation-old-token      a refresh that rotated the token saves the old one RotatedTokenSaved
#   mutation-wrap-skew      the sum wraps instead of stopping at the limit, so
#                           the largest skew reads a live login as not due    SendReadsExpiry
#
# SubscriptionRefreshTrace.tla checks runs of the built fx binary against the
# model; tests/tla/drivers/auth/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh refresh refresh-today-late-clear
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
SubscriptionRefresh refresh -
SubscriptionRefresh refresh-today-late-clear NoDoubleFree
SubscriptionRefresh refresh-today-checked-deadline NoAbort
SubscriptionRefresh refresh-today-plain-skew NoAbort
SubscriptionRefresh refresh-mutation-keep-login BadReplySignsOut
SubscriptionRefresh refresh-mutation-old-token RotatedTokenSaved
SubscriptionRefresh refresh-mutation-wrap-skew SendReadsExpiry
VERDICTS
