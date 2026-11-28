#!/bin/sh
# Model-check CatalogOpen: fx processes that read and write the saved model
# catalog, crash at any step, and answer requests (src/core/gateway/
# saved_catalog.zig, saved_catalog_plan.zig, gateway_provider.zig).
#
# design must pass. current is fx before the saved catalog: a start with a
# usable saved file still waits. mutant-* plant single defects that their
# named invariants must catch.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<EOF
CatalogOpen design -
CatalogOpen current WarmStartNeverWaits
CatalogOpen mutant-no-rename FileWhole
CatalogOpen mutant-ignore-team OwnTeamOnly
CatalogOpen mutant-use-old NeverOlderThanADay
CatalogOpen mutant-wait-with-catalog NeverWaitWithCatalog
CatalogOpen mutant-saved-marks-answer SavedMarksNeverAnswer
CatalogOpen mutant-skip-landed LandedTakenNext
EOF
