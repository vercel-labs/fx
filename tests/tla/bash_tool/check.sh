#!/bin/sh
# Model-check the one bash tool's session and result store with TLC, and
# require each config's expected verdict.
#
# result-store.cfg is the design and must pass. Each mutation config plants
# one defect, and the rule it names must catch it:
#
#   show-before-save  a preview reaches the model before its output is saved  SavedBeforeShown
#   skip-index        an fx command result is saved without its index line     IndexMatchesStore
#   rerun-on-wait     wait_more starts the program again                       RunOnce
#   torn-save         a killed program leaves the bash state half-written      StateNeverTorn
#   exit-skips-save   a program that ends with exit does not save its state    EndedSaves
#   silent-refusal    a state over the size cap is not saved, with no notice   RefusalNoticed
#   big-save-torn     a refused save leaves the bash state half-written        StateNeverTorn
#   silent-heal       a heal drops the saved state with no notice              LossNoticed
#   skip-heal         a program runs on damaged session files                  NeverLoadsDamaged
#   forget-on-fail    a failed heal forgets an unreported loss                 ReportedBeforeRun
#
# No Bun driver runs the built fx along this model yet; the bash tool's unit
# and e2e tests cover the session part that has landed.
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   sh check.sh
#   sh check.sh result-store result-store-mutation-skip-index
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
ResultStore result-store -
ResultStore result-store-mutation-show-before-save SavedBeforeShown
ResultStore result-store-mutation-skip-index IndexMatchesStore
ResultStore result-store-mutation-rerun-on-wait RunOnce
ResultStore result-store-mutation-torn-save StateNeverTorn
ResultStore result-store-mutation-exit-skips-save EndedSaves
ResultStore result-store-mutation-silent-refusal RefusalNoticed
ResultStore result-store-mutation-big-save-torn StateNeverTorn
ResultStore result-store-mutation-silent-heal LossNoticed
ResultStore result-store-mutation-skip-heal NeverLoadsDamaged
ResultStore result-store-mutation-forget-on-fail ReportedBeforeRun
VERDICTS
