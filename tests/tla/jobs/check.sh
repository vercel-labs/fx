#!/bin/sh
# Model-check background job delivery (src/core/jobs/) with TLC and require
# each config's expected verdict.
#
# Jobs: a settled job's result reaches the model exactly once, through a
# leased `jobs wait` or the automatic async-result notice (D110, D111).
#
# The design config must pass every invariant and liveness property. Each
# Jobs-<mutation>.cfg enables one broken rule and must be rejected by the
# named property.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
Jobs Jobs -
Jobs Jobs-double_reserve ExactlyOnceDelivery -deadlock
Jobs Jobs-ignore_lease NoDeliveryUnderLease -deadlock
Jobs Jobs-release_delivered ExactlyOnceDelivery -deadlock
Jobs Jobs-lease_leak temporal -deadlock
EOF
