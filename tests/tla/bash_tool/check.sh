#!/bin/sh
# Model-check the one bash tool's session and result store with TLC, require
# each config's expected verdict, then run the Bun driver that runs the real
# result store along this model.
#
# result-store.cfg is the design, with three programs and Faults = FALSE, and
# must pass. Faults = FALSE leaves out the failure steps (a file or an index line
# that cannot be written), which keeps this check at its size without them.
# result-store-faults.cfg checks those steps on two programs (Faults = TRUE), and
# the driver's two walked instances turn them on too. Each mutation config plants
# one defect, and the rule it names must catch it. The silent-index one runs on
# the two-program instance with Faults = TRUE, since its failure step must happen:
#
#   show-before-save   a preview reaches the model before its output is indexed      SavedBeforeShown
#   skip-index         a result file is saved without its index line                 SavedBeforeShown
#   rerun-on-wait      wait_more starts the program again                            RunOnce
#   torn-save          a killed program leaves the bash state half-written           StateNeverTorn
#   exit-skips-save    a program that ends with exit does not save its state         EndedSaves
#   silent-refusal     a state over the size cap is not saved, with no notice        RefusalNoticed
#   big-save-torn      a refused save leaves the bash state half-written             StateNeverTorn
#   silent-heal        a heal drops the saved state with no notice                   LossNoticed
#   skip-heal          a program runs on damaged session files                       NeverLoadsDamaged
#   forget-on-fail     a failed heal forgets an unreported loss                      ReportedBeforeRun
#   number-from-index  the next number ignores a file with no index line             NoReuse
#   silent-full        output that finds no room is dropped with no notice           FullNoticed
#   silent-index       a file whose index line fails is shown with no notice         SavedBeforeShown
#
# Each witness config must be violated, to show TLC reaches that case: a file
# left without its index line when fx stops (OrphanWitness), output that finds
# no room (FullWitness), and a later result shown above such a file
# (ResumeWitness).
#
# result-store-small-room2 and result-store-small-room1 are the design with two
# programs (room for two files, and for one) and Faults = TRUE. Their graphs are
# small enough for the driver to walk every distinct step on the real result store.
#
# Then the driver, tests/tla/drivers/bash_tool/verify.ts, walks those two graphs
# on the real result store (src/core/session/result_files.zig,
# src/core/bash_results/, src/tools/bash/program_output.zig), checks recorded
# runs of the three-program store against TraceResultStore.tla, and builds each
# planted bug in mutations.json into its own copy of src/, which its named rule
# must catch. It runs only when no config is named. FX_TLA_BASH_TOOL_TLC_ONLY=1
# skips it (Build & Test runs that way, and tla-bash-tool.yml runs the driver).
# FX_TLA_BASH_TOOL_QUICK=1 runs its quick settings.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes, and Zig and Bun
# for the driver.
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
ResultStore result-store-small-room2 -
ResultStore result-store-faults -
ResultStore result-store-small-room1 -
ResultStore result-store-mutation-show-before-save SavedBeforeShown
ResultStore result-store-mutation-skip-index SavedBeforeShown
ResultStore result-store-mutation-rerun-on-wait RunOnce
ResultStore result-store-mutation-torn-save StateNeverTorn
ResultStore result-store-mutation-exit-skips-save EndedSaves
ResultStore result-store-mutation-silent-refusal RefusalNoticed
ResultStore result-store-mutation-big-save-torn StateNeverTorn
ResultStore result-store-mutation-silent-heal LossNoticed
ResultStore result-store-mutation-skip-heal NeverLoadsDamaged
ResultStore result-store-mutation-forget-on-fail ReportedBeforeRun
ResultStore result-store-mutation-number-from-index NoReuse
ResultStore result-store-mutation-silent-full FullNoticed
ResultStore result-store-mutation-silent-index SavedBeforeShown
ResultStore result-store-witness-orphan OrphanWitness
ResultStore result-store-witness-full FullWitness
ResultStore result-store-witness-resume ResumeWitness
VERDICTS

if [ "$#" -eq 0 ] && [ "${FX_TLA_BASH_TOOL_TLC_ONLY:-0}" != "1" ]; then
    bun ../drivers/bash_tool/verify.ts
fi
