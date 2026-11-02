#!/bin/sh
# Model-check the /usage models with TLC and require each config's expected
# verdict.
#
# LeanUsage (src/usage/policy.zig, view.zig): two processes and two identities
# sharing one usage cache, with the refresh timer, the 60-second floor, failure
# backoff, and the UTC day rollover. LeanUsageSmall and LeanUsageDrive must
# pass. The full LeanUsage config explores many more states; run it by name:
#   ./check.sh LeanUsage
#
# UsageModel: the refresh and shared-cache model in ideal conditions (Ideal)
# and with failures, crashes, an unreadable cache, and clock correction
# (Hostile, HostileSwitch). Each must pass.
#
# The planted bugs and the runs against real fx TUIs are in ../drivers/usage/:
#   bun ../drivers/usage/model/model.ts           # base configs and planted bugs
#   bun test ../drivers/usage/model/              # replay TLC behaviors in tmux
#   bun ../drivers/usage/lean/drive.ts --traces 4
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

if [ "$#" -eq 0 ]; then
    set -- LeanUsageSmall LeanUsageDrive Ideal Hostile HostileSwitch
fi
tlc_verdicts "$@" <<'EOF'
LeanUsage LeanUsageSmall -
LeanUsage LeanUsage -
LeanUsageDrive LeanUsageDrive - -deadlock
UsageModel Ideal -
UsageModel Hostile -
UsageModel HostileSwitch -
EOF
