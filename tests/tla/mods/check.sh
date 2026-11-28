#!/bin/sh
# Model-check the mod store (planned: src/core/mods/) with TLC and require each
# config's expected verdict.
#
# ModStore.tla: `fx mod add`, `update`, `disable`, `enable` and `remove` at
# once with a running fx loading the mod, and an installer that crashes at any
# step. mods-current.cfg reuses today's skills install transaction, whose
# update leaves a moment with no mod (LoadsSeeCommitted). mods-design-a.cfg
# (a manifest index) and mods-design-b.cfg (versioned folders behind a
# symlink) must pass. Each mods-mutant-*.cfg plants one defect, and the rule it
# names must catch it. The simulate configs make random runs of design b.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh mods-design-b mods-mutant-b-no-lock
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu
cd "$(dirname "$0")"
. ../lib/tlc.sh
tlc_verdicts "$@" <<'VERDICTS'
ModStore mods-current LoadsSeeCommitted
ModStore mods-design-a -
ModStore mods-design-b -
ModStore mods-mutant-a-no-lock LoadsSeeCommitted
ModStore mods-mutant-b-no-lock LoadsSeeCommitted
ModStore mods-mutant-b-gc-live LoadsSeeCommitted
ModStore mods-mutant-b-add-replaces OneAddWins
ModStore mods-simulate-ideal simulate -simulate num=20000 -depth 20 -seed 1
ModStore mods-simulate-nonideal simulate -simulate num=20000 -depth 20 -seed 1
VERDICTS
