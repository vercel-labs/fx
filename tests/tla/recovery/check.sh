#!/bin/sh
# Model-check the recovery module's model with TLC and require each config's
# expected verdict.
#
# recovery.cfg and recovery-deep.cfg are the correct module and must pass.
# Each recovery-mutation-*.cfg plants one defect, and the rule it names must
# catch it. Most are bugs fx has shipped:
#
#   stall-stop          stops a request after repeated quick failures      NeverGivesUp
#   no-wake             a wait whose deadline never fires                  Heals
#   stale-socket        a dead pooled connection shown as a failure        NoFalseAlarm
#   frozen-status       a retry warning left over a streaming answer       StatusHonest
#   no-closing          a closed window treated as a crash                 ResumesAfterClose
#   never-ask           a request that crashes fx resumes forever          CrashLoopAsks
#   hot-retry           resending at once after a failure                  NoHotRetry
#   send-without-save   a retry sent without saving the record first       SaveBeforeSend
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh recovery recovery-mutation-no-closing
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
Recovery recovery -
Recovery recovery-deep -
Recovery recovery-mutation-stall-stop NeverGivesUp
Recovery recovery-mutation-no-wake temporal
Recovery recovery-mutation-stale-socket NoFalseAlarm
Recovery recovery-mutation-frozen-status StatusHonest
Recovery recovery-mutation-no-closing ResumesAfterClose
Recovery recovery-mutation-never-ask CrashLoopAsks
Recovery recovery-mutation-hot-retry NoHotRetry
Recovery recovery-mutation-send-without-save SaveBeforeSend
EOF
