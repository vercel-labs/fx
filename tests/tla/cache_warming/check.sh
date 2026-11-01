#!/bin/sh
# Model-check Claude cache warming with TLC and require each config's
# expected verdict.
#
# cache-warming.cfg and cache-warming-deep.cfg are the design and must pass.
# Each cache-warming-mutation-*.cfg plants one defect, and the rule it names
# must catch it:
#
#   ping-at-ttl         pings when the entry expires, not before       NoWritingPing
#   no-cap              keeps pinging past the cap                      PingsBounded
#   no-cap-action       the same, seen at the ping                      PingWithinCap
#   no-late-check       pings after a sleep outlived the entry          NoWritingPing
#   stale-finish        a stale ping's answer stops a newer arm         NoStaleStop
#   ping-while-sending  pings while a real request is out               NoPingWhileSending
#   no-shutdown-cancel  a ping survives shutdown                        NoPingAfterShutdown
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh cache-warming cache-warming-mutation-no-cap
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
CacheWarming cache-warming -
CacheWarming cache-warming-deep -
CacheWarming cache-warming-mutation-ping-at-ttl NoWritingPing
CacheWarming cache-warming-mutation-no-cap PingsBounded
CacheWarming cache-warming-mutation-no-cap-action PingWithinCap
CacheWarming cache-warming-mutation-no-late-check NoWritingPing
CacheWarming cache-warming-mutation-stale-finish NoStaleStop
CacheWarming cache-warming-mutation-ping-while-sending NoPingWhileSending
CacheWarming cache-warming-mutation-no-shutdown-cancel NoPingAfterShutdown
VERDICTS
