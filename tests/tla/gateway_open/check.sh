#!/bin/sh
# Model-check a request's connection open racing Esc and the setup deadline
# (OpenCancel.tla; src/gateway/open_job.zig and OpenJob in
# src/gateway/client.zig) with TLC and require each config's expected verdict.
#
# open-cancel.cfg is the design and must pass. open-cancel-today.cfg is fx
# before the open job, where Esc waited for a DNS lookup that never returned
# (CancelReturns). Each open-cancel-mutation-*.cfg plants one defect, and the
# rule it names must catch it:
#
#   no-close         a request walks away and nobody releases the late open  LateClosed
#   not-atomic       each side reads and writes the state word separately    LateClosed
#   no-stop-connect  a walked-away job stays in a connect nobody answers      AbandonedOpenCloses
#   free-on-return   the request frees the client the job still opens on     NoFreeUnderJob
#
# tests/tla/drivers/gateway_open/driver.ts walks open_job.zig along the
# design's state graph.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh open-cancel open-cancel-mutation-not-atomic
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu
cd "$(dirname "$0")"
. ../lib/tlc.sh
tlc_verdicts "$@" <<'VERDICTS'
OpenCancel open-cancel -
OpenCancel open-cancel-today temporal
OpenCancel open-cancel-mutation-no-close temporal
OpenCancel open-cancel-mutation-not-atomic temporal
OpenCancel open-cancel-mutation-no-stop-connect temporal
OpenCancel open-cancel-mutation-free-on-return NoFreeUnderJob
VERDICTS
