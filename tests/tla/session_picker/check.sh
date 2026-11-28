#!/bin/sh
# Model-check SessionOpen.tla, opening a saved session from the session
# picker (`fx -r`, `/resume`): SessionPickerOpen in
# src/core/app/session_persistence.zig and its steps in
# src/core/app/app_session_runtime.zig. Each config must meet its verdict.
#
# design-b.cfg is the design and must pass, with its liveness rules.
# current.cfg is fx before: Enter opens, decodes, replays, finalizes, and
# installs on the UI thread, which breaks UiNeverSlow. design-a.cfg runs the
# replay on the worker too, where it reads app state the UI thread changes
# (NoWorkerReadsAppState). Each mutant-*.cfg plants one bug in design-b:
#
#   install-after-cancel    a finished open installs after Esc     NoHalfOpen
#   second-enter            Enter while opening starts another     OneOpen
#   esc-frees-worker-result Esc frees what the worker still holds  NoUseAfterFree
#   drop-keeps-lock         a dropped result is not closed         LocksOwned
#   pending-starts-early    a queued open takes the worker slot an
#                           abandoned open still runs in, so that
#                           open's result loses its owner          NoUseAfterFree
#
# The simulate-*.cfg configs run random behaviors without and with failed
# opens; SIM_RUNS sets how many (default 20000).
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
tlc_verdicts "$@" <<EOF2
SessionOpen design-b -
SessionOpen current UiNeverSlow
SessionOpen design-a NoWorkerReadsAppState
SessionOpen mutant-install-after-cancel NoHalfOpen
SessionOpen mutant-second-enter OneOpen
SessionOpen mutant-esc-frees-worker-result NoUseAfterFree
SessionOpen mutant-drop-keeps-lock LocksOwned
SessionOpen mutant-pending-starts-early NoUseAfterFree
SessionOpen simulate-ideal simulate $sim
SessionOpen simulate-nonideal simulate $sim
EOF2
