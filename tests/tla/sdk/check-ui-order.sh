#!/bin/sh
# Model-checks UiStreamOrder.tla with TLC: the order a viewer sees a session's
# UI lines in, for each way libfx writes them and each way a World lands
# and reads them. check.sh runs it with the rest of the sdk models.
#
# UiStreamOrder is local() with the fix, InOrderLanding is a World that keeps
# writeMulti because it lands a call's chunks in order, and IdOrderReader is
# a reader that waits for lower ids. ParallelMulti is local() before the fix:
# it must fail DeliveredInOrder, and ParallelMultiGap LandedIsPrefix. Reach
# fails NotAllDelivered, which shows every line can be delivered.
#
# UiStreamOrderTrace.tla checks runs of the real code against the model;
# tests/tla/drivers/sdk/ui-order.ts runs it:
#   bun ../drivers/sdk/ui-order.ts
#   bun ../drivers/sdk/ui-order.ts --fuzz 20 --seed 7
#
# Needs Java 11+ and tla2tools.jar, as check.sh describes.
#
# Usage:
#   ./check-ui-order.sh
#   ./check-ui-order.sh UiStreamOrder UiStreamOrder-ParallelMulti
set -eu
cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

echo "== UiStreamOrder"
tlc_verdicts "$@" <<'VERDICTS'
UiStreamOrder UiStreamOrder -
UiStreamOrder UiStreamOrder-InOrderLanding -
UiStreamOrder UiStreamOrder-IdOrderReader -
UiStreamOrder UiStreamOrder-ParallelMulti DeliveredInOrder
UiStreamOrder UiStreamOrder-ParallelMultiGap LandedIsPrefix
UiStreamOrder UiStreamOrder-Reach NotAllDelivered
VERDICTS
