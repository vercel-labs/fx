#!/bin/sh
# Model-check the order of one turn's messages at each step boundary, live and
# as restored from the saved turn (SavedTurn.tla), with TLC, and require each
# config's expected verdict.
#
# saved-turn.cfg must pass: the next turn's request starts with the turn's last
# request, and so does each request of a turn with the one before it. It is the
# design fx implements: a tool's notice joins once its step's results and
# feedback are in, the notice and a Stop hook's message are marked as fx's own
# steering so the save keeps them, and a boundary's notes join before the
# steering the last step ended with.
# saved-turn-today.cfg is fx before a boundary's notes joined ahead of that
# steering, where a changed runtime context joined after it (NotesFirst).
# saved-turn-double-trail.cfg is a known limit, not a defect: when a reply adds
# a second steering message to a tail the last request already carried, a note
# joins ahead of the carried one, so that one request differs from the one
# before it (RequestsExtend), and the saved turn still equals the last request.
# Each saved-turn-mutation-*.cfg plants one defect, and the rule it names must
# catch it:
#
#   notice-inline     a tool's notice between two results of its step   ResultsTogether
#   notice-plain      a tool's notice with no marker, dropped by the save  NothingDropped
#   review-plain      review mode's message with no marker               NothingDropped
#   hook-plain        a Stop hook's message with no marker               NothingDropped
#   steering-first    a restore that puts steering before notes          RoundTrip
#   prefix-dropped    the save forgets the assistant message before steering  NothingDropped
#
# SavedTurnTrace.tla checks turns of the built fx binary against the model;
# tests/tla/drivers/saved_turn/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh saved-turn saved-turn-today
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
SavedTurn saved-turn -
SavedTurn saved-turn-today NotesFirst
SavedTurn saved-turn-double-trail RequestsExtend
SavedTurn saved-turn-mutation-notice-inline ResultsTogether
SavedTurn saved-turn-mutation-notice-plain NothingDropped
SavedTurn saved-turn-mutation-review-plain NothingDropped
SavedTurn saved-turn-mutation-hook-plain NothingDropped
SavedTurn saved-turn-mutation-steering-first RoundTrip
SavedTurn saved-turn-mutation-prefix-dropped NothingDropped
VERDICTS
