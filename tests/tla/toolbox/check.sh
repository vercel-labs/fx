#!/bin/sh
# Model-check the toolbox with TLC and require each config's expected verdict.
#
# toolbox.cfg is the design and must pass. Each toolbox-mutation-*.cfg plants
# one defect, and the rule it names must catch it:
#
#   append-tool        an opened or called tool is added to the tools       ToolsFixed
#   live-menu          the menu follows the catalog's availability          MenuFixed
#   menu-from-live     a resume rebuilds the menu from what is up now       MenuFixed
#   compact-resets-menu  compaction rebuilds the menu from what is up now   MenuFixed
#   compact-forgets-notes  after a compaction, the notes it folded away     Informed
#                        still count as told
#   skip-admission     a run goes ahead when permission was denied          RunNeedsAdmission
#   rerun-after-crash  a resume runs an interrupted call again              AtMostOnce
#   run-needs-open     a run fails unless its entry was opened first        RunWorksWhenAllowed
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh toolbox toolbox-mutation-append-tool
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
Toolbox toolbox -
Toolbox toolbox-mutation-append-tool ToolsFixed
Toolbox toolbox-mutation-live-menu MenuFixed
Toolbox toolbox-mutation-menu-from-live MenuFixed
Toolbox toolbox-mutation-compact-resets-menu MenuFixed
Toolbox toolbox-mutation-compact-forgets-notes Informed
Toolbox toolbox-mutation-skip-admission RunNeedsAdmission
Toolbox toolbox-mutation-rerun-after-crash AtMostOnce
Toolbox toolbox-mutation-run-needs-open RunWorksWhenAllowed
VERDICTS
