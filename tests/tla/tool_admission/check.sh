#!/bin/sh
# Model-check auto mode's routine-command lane for `user` profile shell
# commands against the shell snapshot (RoutineNames.tla) and require each
# config's expected verdict.
#
# RoutineNames.cfg is the rule fx implements: it must pass every invariant and
# EveryCommandFinishes with deadlock checking on. RoutineNames-main.cfg is fx
# before it, RoutineNames-review_unknown.cfg is the design fx did not take,
# RoutineNames-late_check.cfg is the rerun after a failed replay checking the
# files after the owner failed the generation, and each other
# RoutineNames-<bug>.cfg plants one bug. Those check safety only and must be
# rejected by the named invariant.
#
# Run the built binary along the model and have TLC check every turn it
# observes (RoutineNamesTrace.tla):
#   bun tests/tla/drivers/tool_admission/driver.ts --self-check
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
RoutineNames RoutineNames -
RoutineNames RoutineNames-main NoUnreviewedAlias -deadlock
RoutineNames RoutineNames-review_unknown ZeroReview -deadlock
RoutineNames RoutineNames-unbound NoUnreviewedAlias -deadlock
RoutineNames RoutineNames-reload_routine RefusedOnlyAfterRefresh -deadlock
RoutineNames RoutineNames-failed_clear NoUnreviewedAlias -deadlock
RoutineNames RoutineNames-fallback_unchecked NoUnreviewedAlias -deadlock
RoutineNames RoutineNames-capture_again CapturesBounded -deadlock
RoutineNames RoutineNames-late_check NoFalseRefusal -deadlock
RoutineNames RoutineNames-moved_unchecked NoUnreviewedAlias -deadlock
EOF
