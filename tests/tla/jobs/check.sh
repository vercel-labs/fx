#!/bin/sh
# Model-check background job delivery (src/core/jobs/) with TLC and require
# each config's expected verdict.
#
# Jobs: a settled job's result reaches the model exactly once, through a
# leased `jobs wait` or the automatic async-result notice (D110, D111),
# and a wait takes back a queued notice the model has not read yet.
#
# Mailbox: a message between the agents of a tree reaches the recipient's
# model exactly once and in order, across a crash and a restart, and none
# is lost but by a full mailbox's drop (D185 to D189), including one sent
# before the recipient's log exists, which the root's log holds (D212).
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
Jobs Jobs-reclaim_absorbed ExactlyOnceDelivery -deadlock
Mailbox Mailbox -
Mailbox Mailbox-no_recover ExactlyOnce -deadlock
Mailbox Mailbox-commit_early NoLossAcrossRestart -deadlock
Mailbox Mailbox-overtake InOrder -deadlock
Mailbox Mailbox-release_absorbed ExactlyOnce -deadlock
Mailbox Mailbox-ignore_wait NoDeliveryUnderWait -deadlock
Mailbox Mailbox-two_carriers ExactlyOnce -deadlock
Mailbox Mailbox-held_in_memory NoLossAcrossRestart -deadlock
Mailbox Mailbox-flush_no_dedupe ExactlyOnce -deadlock
Mailbox Mailbox-take_unsettled ExactlyOnce -deadlock
EOF
