#!/bin/sh
# Model-check the one-time cleanup of old session logs with TLC, and require
# each config's expected verdict.
#
# Prune.tla: the cleanup of a legacy log, which replaces superseded usage and
#   snapshot lines with pruned lines that keep their seq, and restores the
#   original with every turn written since.
#   prune-safety.cfg and prune-live.cfg are the design and must pass.
#   simulate-prune.cfg runs the design in random simulation.
#   today-dead.cfg is fx today: the dead lines are never removed (NoDeadWeight).
#   Each mutant-*.cfg plants one bug, and the invariant it names must catch it.
#   mutant-new-shape.cfg also replaces per-reply usage lines (FoldEqual).
#   mutant-drop-tail.cfg makes a restore drop the turns written since (NoCommittedLoss).
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh mutant-drop-gap
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
Prune prune-safety -
Prune prune-live - -deadlock
Prune today-dead temporal -deadlock
Prune mutant-drop-renumber SeqPreserved
Prune mutant-drop-gap SeqContiguous
Prune mutant-newest-usage FoldEqual
Prune mutant-new-shape FoldEqual
Prune mutant-relink KeptOriginalFixed
Prune mutant-drop-tail NoCommittedLoss
Prune mutant-stale-off CompactionOffsetValid
Prune mutant-drop-newest-snap NewestSnapshotKept
Prune mutant-no-lock Lock
Prune mutant-delete-orig OriginalKept
Prune simulate-prune simulate -simulate num=20000 -depth 20 -seed 1
EOF
