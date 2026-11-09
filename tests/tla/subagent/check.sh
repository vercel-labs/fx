#!/bin/sh
# Model-check main's messages into its subagents' running turns
# (Owner.steer in src/core/subagent/managed_owner.zig) with TLC and require
# each config's expected verdict.
#
# steer-queue.cfg and steer-queue-deep.cfg are the design and must pass.
# steer-queue-today.cfg is fx before it: one list for every subagent, with
# settled entries counted and kept until the same subagent starts again, and
# steer-queue-today-close.cfg its second defect, a closed subagent's entries
# kept (both are reached at the same depth, so each config checks one). Each
# steer-queue-mutation-*.cfg plants one defect, and the rule it names must
# catch it:
#
#   global-waiting   unread messages counted across every subagent  RefusedOnlyWhenFull
#   settled-count    a subagent's read messages still counted       RefusedOnlyWhenFull
#   off-by-one       a subagent refused one message early           RefusedOnlyWhenFull
#   no-limit         no limit at all                                WaitingBounded
#   no-start-prune   a new work keeps the last work's entries      EntriesFromThisWork
#   no-close-forget  a closed subagent keeps its entries            ClosedHoldsNothing
#
# SteerQueueTrace.tla checks runs of the built fx binary against the model;
# tests/tla/drivers/subagent/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh steer-queue steer-queue-mutation-no-start-prune
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
SteerQueue steer-queue -
SteerQueue steer-queue-deep -
SteerQueue steer-queue-today RefusedOnlyWhenFull
SteerQueue steer-queue-today-close ClosedHoldsNothing
SteerQueue steer-queue-mutation-global-waiting RefusedOnlyWhenFull
SteerQueue steer-queue-mutation-settled-count RefusedOnlyWhenFull
SteerQueue steer-queue-mutation-off-by-one RefusedOnlyWhenFull
SteerQueue steer-queue-mutation-no-limit WaitingBounded
SteerQueue steer-queue-mutation-no-start-prune EntriesFromThisWork
SteerQueue steer-queue-mutation-no-close-forget ClosedHoldsNothing
VERDICTS
