#!/bin/sh
# Model-check how the interactive TUI ends on an outside SIGINT, SIGTERM, or
# SIGHUP (TuiClose.tla), and require each config's expected verdict.
#
# current-*.cfg is today's code: each must break the one rule named.
# design-a.cfg and design-b.cfg are the two designs: each must pass every rule.
# mutant-*.cfg plants one defect in a design: the rule it names must catch it.
# simulate-*.cfg run random behaviors in ideal and non-ideal conditions;
# SIM_RUNS sets how many (default 20000).
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
tlc_verdicts "$@" <<EOF
TuiClose current-tty TtyRestored
TuiClose current-int-save CloseSavesRequest
TuiClose design-a -
TuiClose design-b -
TuiClose mutant-a-no-tty TtyRestored
TuiClose mutant-a-early-uninstall TtyRestored
TuiClose mutant-a-minimal-handler CloseSavesRequest
TuiClose mutant-a-int-uninstall ShutdownNotCut
TuiClose mutant-a-no-once OneCloser
TuiClose mutant-b-cancel CloseSavesRequest
TuiClose mutant-b-no-guard ShutdownNotCut
TuiClose mutant-b-no-tty TtyRestored
TuiClose simulate-ideal simulate $sim
TuiClose simulate-nonideal simulate $sim
TuiClose simulate-ideal-b simulate $sim
TuiClose simulate-nonideal-b simulate $sim
EOF
