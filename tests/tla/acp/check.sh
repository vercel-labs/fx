#!/bin/sh
# Model-check the ACP models with TLC and require each config's expected
# verdict.
#
# AcpPermissionModes: the ACP permission-mode contract, which matches the CLI's
# /permissions. AcpSpeed: the per-session Standard, Fast, and Ultrafast speed
# contract. Both configs must pass.
#
# AcpStopReasons: ACP v1 stop reasons for fx acp, fx's own names for libfx, and
# a stop reason that agrees with what the next prompt holds, for every cause: a
# failed turn that fx keeps in its history ends with end_turn, one it leaves out
# ends with refusal, and a step-limit stop ends with max_turn_requests and keeps
# its turn.
# AcpConfigCategories: only the model option has config category `model`.
# AcpCommandOutput: command progress text stays valid UTF-8 when a chunk ends
# inside a character. Their fixed configs must pass. The configs with fx's
# behavior before the fix (Unmapped, StepLimitRefused, KeptRefused, Shared, Raw)
# and the planted bugs (LibfxMapped, StepLimitDropped, DroppedEnded, SharedTail,
# NoFlush) must each violate the named invariant.
#
# The planted bugs and the runs of the real `fx acp` binary are in
# ../drivers/acp/:
#   bun ../drivers/acp/permission_modes/check-spec.ts
#   bun ../drivers/acp/permission_modes/driver.ts
#   bun ../drivers/acp/speed/check-spec.ts
#   bun ../drivers/acp/speed/driver.ts
#   bun ../drivers/acp/conformance/driver.ts
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
MCAcpPermissionModes MCAcpPermissionModes -
MCAcpSpeed MCAcpSpeed -
AcpStopReasons MCAcpStopReasons -
AcpStopReasons MCAcpStopReasonsUnmapped AcpStopReasonValid
AcpStopReasons MCAcpStopReasonsLibfxMapped LibfxKeepsNames
AcpStopReasons MCAcpStopReasonsStepLimitRefused RefusalLeavesTurnOut
AcpStopReasons MCAcpStopReasonsStepLimitDropped TurnLimitKeepsTurn
AcpStopReasons MCAcpStopReasonsKeptRefused RefusalLeavesTurnOut
AcpStopReasons MCAcpStopReasonsDroppedEnded DroppedTurnRefuses
AcpConfigCategories MCAcpConfigCategories -
AcpConfigCategories MCAcpConfigCategoriesShared ModelPickerFirst
AcpCommandOutput MCAcpCommandOutput -
AcpCommandOutput MCAcpCommandOutputRaw ProgressValidUtf8
AcpCommandOutput MCAcpCommandOutputSharedTail NothingLost
AcpCommandOutput MCAcpCommandOutputNoFlush NothingLost
EOF
