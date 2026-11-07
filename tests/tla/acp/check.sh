#!/bin/sh
# Model-check the ACP models with TLC and require each config's expected
# verdict.
#
# AcpPermissionModes: the ACP permission-mode contract, which matches the CLI's
# /permissions. AcpSpeed: the per-session Standard, Fast, and Ultrafast speed
# contract. AcpPromptDelivery: steering and queued prompts as the sh.fx spec
# defines them, which haven't landed in src/acp/ yet; its Today configs show
# fx's ACP path now, and each must fail on the rule it names. The other
# configs must pass.
#
# The planted bugs and the runs of the real `fx acp` binary are in
# ../drivers/acp/:
#   bun ../drivers/acp/permission_modes/check-spec.ts
#   bun ../drivers/acp/permission_modes/driver.ts
#   bun ../drivers/acp/speed/check-spec.ts
#   bun ../drivers/acp/speed/driver.ts
#   bun ../drivers/acp/prompt_delivery/check-spec.ts
#   bun ../drivers/acp/prompt_delivery/driver.ts   # today's fx acp; --model rules fails until the rules land
#
# With --ci it also runs every ../drivers/acp/*/driver.ts against
# zig-out/bin/fx, as CI does; the planted bugs stay local, since they measure
# the checks, not the code. Name configs to check only those.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes, and Bun and a
# built fx for --ci.
set -eu

ci=false
if [ "${1:-}" = "--ci" ]; then
    ci=true
    shift
fi

cd "$(dirname "$0")"
# shellcheck source-path=SCRIPTDIR source=../lib/tlc.sh
. ../lib/tlc.sh

status=0
tlc_verdicts "$@" <<'EOF' || status=1
MCAcpPermissionModes MCAcpPermissionModes -
MCAcpSpeed MCAcpSpeed -
MCAcpPromptDelivery MCAcpPromptDelivery -
MCAcpPromptDelivery MCAcpPromptDeliveryRefusals -
MCAcpPromptDelivery AcpPromptDeliveryToday-interrupt NoSteerWaitsOnReply
MCAcpPromptDelivery AcpPromptDeliveryToday-lost NothingLost
MCAcpPromptDelivery AcpPromptDeliveryToday-dropped DeliveryValues
MCAcpPromptDelivery AcpPromptDeliveryToday-late LateRunTogether
EOF

if [ "$ci" = true ]; then
    for driver in ../drivers/acp/*/driver.ts; do
        echo "driver ${driver#../drivers/acp/}"
        if ! bun "$driver"; then
            echo "FAIL  ${driver#../drivers/acp/}"
            status=1
        fi
    done
fi
exit "$status"
