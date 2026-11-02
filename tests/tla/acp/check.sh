#!/bin/sh
# Model-check the ACP models with TLC and require each config's expected
# verdict.
#
# AcpPermissionModes: the ACP permission-mode contract, which matches the CLI's
# /permissions. AcpSpeed: the per-session Standard, Fast, and Ultrafast speed
# contract. Both configs must pass.
#
# The planted bugs and the runs of the real `fx acp` binary are in
# ../drivers/acp/:
#   bun ../drivers/acp/permission_modes/check-spec.ts
#   bun ../drivers/acp/permission_modes/driver.ts
#   bun ../drivers/acp/speed/check-spec.ts
#   bun ../drivers/acp/speed/driver.ts
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
MCAcpPermissionModes MCAcpPermissionModes -
MCAcpSpeed MCAcpSpeed -
EOF
