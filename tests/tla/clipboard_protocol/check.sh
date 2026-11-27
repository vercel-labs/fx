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
CHECKS
