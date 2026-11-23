#!/bin/sh
# Model-check SmallBlobs for Design = "pack", the per-session pack of small
# bodies in src/core/session_manager/pack.zig, and require each config's
# expected verdict.
#
# design-pack.cfg must pass: the pack is synced before any line names one of
# its records, so no durable line names a record that a crash could lose
# (Dangling). mutant-early-ref.cfg plants a line that names an unsynced
# record, and Dangling must catch it.
#
# The inline design and its collector are not part of this change, so no
# config here runs them. The pack's own tests are in
# src/core/session_manager/pack.zig and session.zig.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
SmallBlobs design-pack -
SmallBlobs mutant-early-ref Dangling
EOF
