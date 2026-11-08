#!/bin/sh
# Model-check the ACP models with TLC and require each config's expected
# verdict.
#
# AcpPermissionModes: the ACP permission-mode contract, which matches the CLI's
# /permissions. AcpSpeed: the per-session Standard, Fast, and Ultrafast speed
# contract. Both configs must pass. AcpChildApproval: how a subagent's
# permission request reaches the client through its parent session. Its
# design configs (MCAcpChildApproval, MCAcpChildApprovalReserve,
# MCAcpChildApprovalAnswered, MCAcpChildApprovalNoHost) must pass. The code
# before the change (MCAcpChildApprovalToday), two planted bugs, and the
# behavior of the head the repair started from, one config per law
# (StaleCard, SpawnLeak, SharedIds, Starved, CancelGap), must each break the
# property they name.
#
# The planted bugs and the runs of the real `fx acp` binary are in
# ../drivers/acp/:
#   bun ../drivers/acp/permission_modes/check-spec.ts
#   bun ../drivers/acp/permission_modes/driver.ts
#   bun ../drivers/acp/speed/check-spec.ts
#   bun ../drivers/acp/speed/driver.ts
#   bun ../drivers/acp/child_approval/driver.ts
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
MCAcpPermissionModes MCAcpPermissionModes -
MCAcpSpeed MCAcpSpeed -
AcpChildApproval MCAcpChildApproval -
AcpChildApproval MCAcpChildApprovalReserve -
AcpChildApproval MCAcpChildApprovalAnswered -
AcpChildApproval MCAcpChildApprovalNoHost -
AcpChildApproval MCAcpChildApprovalToday temporal
AcpChildApproval MCAcpChildApprovalSplitGate NoStrandedRequest
AcpChildApproval MCAcpChildApprovalStopIgnored temporal
AcpChildApproval MCAcpChildApprovalStaleCard temporal
AcpChildApproval MCAcpChildApprovalSpawnLeak NoStrandedRequest
AcpChildApproval MCAcpChildApprovalSharedIds UniqueIds
AcpChildApproval MCAcpChildApprovalStarved ParentNeverStarved
AcpChildApproval MCAcpChildApprovalCancelGap ShownRequestIsOpen
EOF
