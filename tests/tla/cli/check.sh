#!/bin/sh
# Model-check LaunchSelection, the launch-time --model, --fast, --ultrafast,
# and --effort handling of `fx` and `fx ask`, and require each config's
# expected verdict.
#
# proposed.cfg and current-holds.cfg must pass. Each current-*.cfg shows a
# property the design without launch validation breaks, and each mutant-*.cfg
# plants a bug in the proposed design that its property must catch. The
# simulate-*.cfg configs run random behaviors in ideal and non-ideal
# conditions; SIM_RUNS sets how many (default 20000).
#
# Run the real binary through every modeled scenario and have TLC replay it:
#   bun test ../drivers/cli/
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
tlc_verdicts "$@" <<EOF
LaunchSelection proposed -
LaunchSelection current-holds -
LaunchSelection current-model ValidModel
LaunchSelection current-speed HonestSpeed
LaunchSelection current-effort HonestEffort
LaunchSelection current-late-error AskFailsEarly
LaunchSelection current-canonical Canonical
LaunchSelection mutant-reject-weak NoFalseReject
LaunchSelection mutant-no-canonical Canonical
LaunchSelection mutant-block-frame FirstFrameNotBlocked
LaunchSelection mutant-persist SettingsUntouched
LaunchSelection mutant-silent CorrectionsAnnounced
LaunchSelection simulate-ideal simulate $sim
LaunchSelection simulate-nonideal simulate $sim
EOF
