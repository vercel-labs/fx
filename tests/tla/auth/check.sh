#!/bin/sh
# Model-check fx processes that share one saved fx login, after a 401
# (SharedLoginRefresh.tla), and require each config's expected verdict.
#
# SharedLoginRefresh.cfg (three processes, with the Settles liveness
# property) and SharedLoginRefresh.stress.cfg (four processes, more
# environment events) are the design and must pass. Each mutant plants one
# defect, and the rule it names must catch it:
#
#   always-rotate        rotates on every 401, as fx did before    NoRedundantRotation
#   decide-outside-lock  compares with a login read before the lock NoRedundantRotation
#   adopt-expired        adopts a login past its refresh deadline  AdoptOnlyLive
#
# The witnesses show the model reaches what tests/e2e/auth-refresh.test.ts
# drives: two processes sharing one rotation, and one adopting a login
# another process saved.
#
# tests/tla/drivers/auth/ runs real fx along SharedLoginRefreshTrace.tla.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh SharedLoginRefresh SharedLoginRefresh-mutant-always-rotate
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
SharedLoginRefresh SharedLoginRefresh -
SharedLoginRefresh SharedLoginRefresh.stress -
SharedLoginRefresh SharedLoginRefresh-mutant-always-rotate NoRedundantRotation
SharedLoginRefresh SharedLoginRefresh-mutant-decide-outside-lock NoRedundantRotation
SharedLoginRefresh SharedLoginRefresh-mutant-adopt-expired AdoptOnlyLive
SharedLoginRefresh SharedLoginRefresh-witness-shared-rotation NoSharedRotation
SharedLoginRefresh SharedLoginRefresh-witness-adoption NoAdoption
VERDICTS
