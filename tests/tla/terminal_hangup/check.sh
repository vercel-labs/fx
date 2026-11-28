#!/bin/sh
# Model-check TerminalHangup for today's interactive TUI code, Design A
# (classify at each site), Design B (classify at exit), planted mutants, and
# random simulation under ideal and nonideal conditions.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
tlc_verdicts "$@" <<EOF
TerminalHangup current-gone GoneIsQuiet
TerminalHangup current-nospin NoSpin
TerminalHangup design-a -
TerminalHangup design-b -
TerminalHangup mutant-a-no-init-hangup GoneIsQuiet
TerminalHangup mutant-a-no-pollnval NoSpin
TerminalHangup mutant-a-no-orphan GoneIsQuiet
TerminalHangup mutant-a-blind-eio OpenEioIsReported
TerminalHangup mutant-b-no-pollnval NoSpin
TerminalHangup mutant-b-no-exit-check GoneIsQuiet
TerminalHangup mutant-b-blind-eio OpenEioIsReported
TerminalHangup simulate-ideal simulate $sim
TerminalHangup simulate-nonideal simulate $sim
EOF
