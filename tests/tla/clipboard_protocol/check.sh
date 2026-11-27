#!/bin/sh
# Model-check reading a clipboard image through the terminal with OSC 5522
# (src/ui/terminal/clipboard_protocol.zig) and require each config's verdict.
#
# The design config must pass every invariant and liveness property. Each
# ClipboardRead-<mutation>.cfg enables one broken rule and must be rejected by
# the named invariant, or by a temporal property for no_mode_deadline.
# The model ends once the person stops pressing keys, so deadlock checking is
# off in every config.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'CHECKS'
ClipboardRead ClipboardRead - -deadlock
ClipboardRead ClipboardRead-no_resync NoReplyInComposer -deadlock
ClipboardRead ClipboardRead-accept_idle_packets OneOutcomePerRequest -deadlock
ClipboardRead ClipboardRead-no_size_check ImageBounded -deadlock
ClipboardRead ClipboardRead-ask_while_pending OneOutcomePerRequest -deadlock
ClipboardRead ClipboardRead-no_mode_deadline temporal -deadlock
ClipboardRead ClipboardRead-resync_timeout NoReplyInComposer -deadlock
ClipboardRead ClipboardRead-type_stalled_start NoReplyInComposer -deadlock
ClipboardRead ClipboardRead-no_start_resync NoReplyInComposer -deadlock
PasteEvents PasteEvents - -deadlock
PasteEvents PasteEvents-paste_uses_current_owner PasteTextToRecordedOwner -deadlock
PasteEvents PasteEvents-no_exit_mode_reset ModeOffAfterExit -deadlock
PasteEvents PasteEvents-paste_attach_in_modal NoImageOutsideComposer -deadlock
PasteEvents PasteEvents-listing_while_busy_accepted OneRequestAtATime -deadlock
PasteEvents PasteEvents-no_reply_deadline temporal -deadlock
PasteEvents PasteEvents-current-today temporal -deadlock
CHECKS
