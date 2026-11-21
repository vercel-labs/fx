#!/bin/sh
# Model-check where a preference that a command changes is saved on the
# native and JS host runtime profiles (attemptUserPreferences in
# src/core/app/app_host_config_runtime.zig) with TLC, and require each
# config's expected verdict.
#
# host-preferences.cfg and host-preferences-deep.cfg are the design and must
# pass. host-preferences-today.cfg is fx before it, where fx-term.wasm wrote
# ~/.fx/settings.json and reported HomeNotSet (HostProfileQuiet). Each
# host-preferences-mutation-*.cfg plants one defect, and the rule it names
# must catch it:
#
#   partial-guard    only the /model commit and /sound skip the write    HostProfileQuiet
#   home-check       skip by a missing HOME instead of by profile        HostNeverTouchesHome
#   every-profile    skip on every profile, silencing native failures    NativeReportsFailures
#   ack-dropped      the acknowledgment never holds host_owned            HostAckHeld
#   history-dropped  /history on turns history off on host_owned          HistoryFollowsCommand
#   fake-unchanged   host_owned announced as saved to global settings     HostNeverClaimsSaved
#
# HostPreferencesTrace.tla checks runs of fx-term.wasm and the built fx
# against the model; tests/tla/drivers/host_config/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh host-preferences host-preferences-mutation-partial-guard
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
HostPreferences host-preferences -
HostPreferences host-preferences-deep -
HostPreferences host-preferences-today HostProfileQuiet
HostPreferences host-preferences-mutation-partial-guard HostProfileQuiet
HostPreferences host-preferences-mutation-home-check HostNeverTouchesHome
HostPreferences host-preferences-mutation-every-profile NativeReportsFailures
HostPreferences host-preferences-mutation-ack-dropped HostAckHeld
HostPreferences host-preferences-mutation-history-dropped HistoryFollowsCommand
HostPreferences host-preferences-mutation-fake-unchanged HostNeverClaimsSaved
VERDICTS
