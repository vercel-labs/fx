#!/bin/sh
# Model-checks the order Ctrl+O shows a turn in, live and after a resume
# (FullDetailOrder.tla), and how a turn saves its call records beside its
# steering so every write only adds to the end (FullDetailLog.tla), with TLC:
# the design passes, and each planted bug is caught by the invariant named
# next to it. ../README.md lists the requirements.
#
# Usage:
#   ./check.sh                    # every config
#   ./check.sh PinTop NeverSaved  # selected configs
set -eu
cd "$(dirname "$0")"
. ../lib/tlc.sh
tlc_find
tlc_verdicts "$@" <<'CHECKS'
FullDetailOrder FullDetailOrder -
FullDetailOrder PinTop PromptFirst
FullDetailOrder NeverSaved ReplayMatchesSaved
FullDetailOrder SavedAtCommit ReplayMatchesSaved
FullDetailOrder NoFailureSplit ReplayMatchesSaved
FullDetailLog FullDetailLog -
FullDetailLog RecordsAfterSteering AppendOnly
CHECKS
