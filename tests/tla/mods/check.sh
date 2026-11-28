#!/bin/sh
# Model-check the mod store (src/core/mods/) with TLC and require each
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
# ModUse.tla: a running fx that loads, uses and reloads a mod while other fx
# processes update or remove it and cleanup deletes old versions. The
# mods-use-link configs read through the link, as PR 2's loaders do, and must
# fail; mods-use-pin (a shared lock on each version in use) must pass, and each
# mods-use-mutant-*.cfg must be caught by its rule.
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
ModUse mods-use-link-files UseFindsFiles
ModUse mods-use-link-coherent UseIsCoherent
ModUse mods-use-pin -
ModUse mods-use-pin-deep -
ModUse mods-use-mutant-cleanup-ignores-pins UseFindsFiles
ModUse mods-use-mutant-no-check UseFindsFiles
ModUse mods-use-mutant-keeps-old-pin temporal
ModUse mods-use-mutant-no-reload temporal
VERDICTS
