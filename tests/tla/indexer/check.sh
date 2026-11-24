#!/bin/sh
# Model-check the indexer models with TLC and require each config's expected
# verdict.
#
# Refresh: refresh.cfg and refresh-simulation.cfg must pass.
# refresh-mutation.cfg turns the reuse guard off and must violate
# NoStalePublication, which shows that the invariant catches unsafe reuse. Each
# refresh-witness-*.cfg claims that one reuse path cannot happen and must be
# violated, which shows that the path is reachable.
#
# GrepCut (merging parallel grep results), ListingWait (when the file picker
# shows a loading row), and SnapshotSources (when a listing snapshot may be
# reused): the contract and implementation configs must pass, and each
# *-mutation-* config plants one bug that its named invariant must catch.
#
# SkipNote (the note glob_files and grep_files give for entries skipped by
# name, across snapshot saves and reuse): skip-note.cfg must pass,
# skip-note-today.cfg, fx before the note, must violate NothingSilent, and
# each skip-note-mutation-* config must violate NoteHonest.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
Refresh refresh - -deadlock
Refresh refresh-simulation - -deadlock
Refresh refresh-mutation NoStalePublication -deadlock
RefreshWitness refresh-witness-NoReuse NoReuse -deadlock
RefreshWitness refresh-witness-NoReuseAfterEdit NoReuseAfterEdit -deadlock
RefreshWitness refresh-witness-NoReuseAfterIgnore NoReuseAfterIgnore -deadlock
RefreshWitness refresh-witness-NoEditAfterReuse NoEditAfterReuse -deadlock
RefreshWitness refresh-witness-NoIgnoreChangeAfterReuse NoIgnoreChangeAfterReuse -deadlock
GrepCut grep-cut - -deadlock
GrepCut grep-cut-mutation-order MergeCorrect -deadlock
GrepCut grep-cut-mutation-oom MergeCorrect -deadlock
ListingWait listing-wait - -deadlock
ListingWait listing-wait-mutation NoFlashUnlessSlow -deadlock
SnapshotSources snapshot-contract - -deadlock
SnapshotSources snapshot-implementation - -deadlock
SnapshotSources snapshot-mutation-ancestors NoStaleReuse -deadlock
SnapshotSources snapshot-mutation-follow NoStaleReuse -deadlock
SnapshotSources snapshot-mutation-key NoStaleReuse -deadlock
SkipNote skip-note - -deadlock
SkipNote skip-note-today NothingSilent -deadlock
SkipNote skip-note-mutation-flag NoteHonest -deadlock
SkipNote skip-note-mutation-unsaved NoteHonest -deadlock
SkipNote skip-note-mutation-whole-tree NoteHonest -deadlock
SkipNote skip-note-mutation-hidden NoteHonest -deadlock
SkipNote skip-note-mutation-old-format NoteHonest -deadlock
EOF
