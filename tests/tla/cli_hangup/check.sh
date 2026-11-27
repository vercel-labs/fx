#!/bin/sh
# Model-check CliHangup: CLI read/write hang-up classification vs open-terminal
# and file errors (`src/core/cli/`, `src/core/auth/`, `src/ui/ask_presentation.zig`,
# `src/core/app/app_entry_runtime.zig`).
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
tlc_verdicts "$@" <<EOF
CliHangup current GoneIsQuiet
CliHangup design-a -
CliHangup design-b GoneIsQuiet
CliHangup mutant-swallow-catch GoneIsQuiet
CliHangup mutant-erase-eio GoneIsQuiet
CliHangup mutant-blind-eio OpenErrorIsReported
CliHangup mutant-ignore-hup-eof GoneIsQuiet
CliHangup simulate-ideal simulate $sim
CliHangup simulate-nonideal simulate $sim
EOF
