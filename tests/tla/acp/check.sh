#!/bin/sh
# Model-check the ACP models with TLC and require each config's expected
# verdict.
#
# AcpPermissionModes: the ACP permission-mode contract, which matches the CLI's
# /permissions. AcpSpeed: the per-session Standard, Fast, and Ultrafast speed
# contract. AcpSessionTarget: how a request that names a session is answered,
# under ACP v1's error rules, in fx acp and in libfx's minimal kernel (the
# libfx/* methods). AcpSystemPrompt: the client's systemPrompt on session/new,
# session/load and session/resume, and the prompt each turn sends. Their Before
# configs show fx before those rules,
# and each must fail on the rule it names. The other configs must pass.
#
# The planted bugs and the runs of the real `fx acp` binary are in
# ../drivers/acp/:
#   bun ../drivers/acp/permission_modes/check-spec.ts
#   bun ../drivers/acp/permission_modes/driver.ts
#   bun ../drivers/acp/speed/check-spec.ts
#   bun ../drivers/acp/speed/driver.ts
#   bun ../drivers/acp/session_target/check-spec.ts
#   bun ../drivers/acp/session_target/driver.ts   # kernel plans need the native addon
#   bun ../drivers/acp/system_prompt/check-spec.ts
#   bun ../drivers/acp/system_prompt/driver.ts
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
MCAcpPermissionModes MCAcpPermissionModes -
MCAcpSpeed MCAcpSpeed -
MCAcpSessionTarget MCAcpSessionTarget -
MCAcpSessionTarget AcpSessionTargetBefore-unknown UnknownSessionAnswer
MCAcpSessionTarget AcpSessionTargetBefore-close CloseIdempotent
MCAcpSessionTarget AcpSessionTargetBefore-oversize NeverAuthCode
MCAcpSystemPrompt MCAcpSystemPrompt -
MCAcpSystemPrompt AcpSystemPromptBefore-v1-refused V1Accepted
MCAcpSystemPrompt AcpSystemPromptBefore-old-accepted OtherShapesRefused
MCAcpSystemPrompt AcpSystemPromptBefore-load-ignores LoadAppliesPrompt
EOF
