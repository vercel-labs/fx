#!/bin/sh
# Model-check one turn with user hooks (HookTurn.tla; the code it names in the
# spec's header) with TLC and require each config's expected verdict.
#
# hook-turn.cfg is the design and must pass. hook-turn-deep.cfg is the same
# design with a longer turn (MaxSteps = 7) and must pass too. Each
# hook-turn-mutation-*.cfg plants one defect, and the rule it names must catch
# it:
#
#   no-stop-cap         the Stop cap is not checked before the Stop hook starts  StopCapBound
#   model-after-cancel  a cancel does not stop the model call; the loop calls the model  NoWorkAfterCancel
#   run-after-cancel    a tool run does not check the cancel flag; the call runs  NoWorkAfterCancel
#   fail-allows         a failed PreToolUse hook counts as an allow              ToolRunsWithGrant
#   no-retry-cap        the PermissionDenied cap is not checked before its hook  RetryCapBound
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh hook-turn hook-turn-mutation-fail-allows
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu
cd "$(dirname "$0")"
. ../lib/tlc.sh
tlc_verdicts "$@" <<'VERDICTS'
HookTurn hook-turn -
HookTurn hook-turn-deep -
HookTurn hook-turn-mutation-no-stop-cap StopCapBound
HookTurn hook-turn-mutation-model-after-cancel NoWorkAfterCancel
HookTurn hook-turn-mutation-run-after-cancel NoWorkAfterCancel
HookTurn hook-turn-mutation-fail-allows ToolRunsWithGrant
HookTurn hook-turn-mutation-no-retry-cap RetryCapBound
VERDICTS
