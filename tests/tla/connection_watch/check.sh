#!/bin/sh
# Model-check the wait for a model response's first byte on a configured
# connection (HeadWait.tla; ConnectionWatch in src/gateway/client.zig, as
# src/gateway/chat_completions.zig starts it) with TLC and require each
# config's expected verdict.
#
# head-wait.cfg is the design and must pass: an agent stream, which has no
# caller deadline, waits for its head without a bound, as the AI Gateway's
# agent path does, and a request with its own deadline keeps the bound.
# head-wait-today.cfg is fx before it, where a configured connection gave up
# on a slow but healthy server at 120 s (SilenceNeverDropsAgent), and
# head-wait-today-resend.cfg shows the resend that followed
# (AnsweredOnFirstSend). Each head-wait-mutation-*.cfg plants one defect, and
# the rule it names must catch it:
#
#   patient-review   a request with its own deadline waits without a bound  OwnDeadlineBounded
#   ignore-deadline  the watch ignores the caller's deadline                OwnDeadlineBounded
#   ignore-cancel    Esc does not end the wait                              EscEndsWait
#   no-probes        nothing finds a peer that went silent                  DeadSocketFound
#
# tests/tla/drivers/connection_watch/driver.ts runs the built fx against a
# local server and has TLC check every run against the design
# (HeadWaitTrace.tla).
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh head-wait head-wait-mutation-no-probes
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu
cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh
tlc_verdicts "$@" <<'VERDICTS'
HeadWait head-wait -
HeadWait head-wait-today SilenceNeverDropsAgent
HeadWait head-wait-today-resend AnsweredOnFirstSend
HeadWait head-wait-mutation-patient-review OwnDeadlineBounded
HeadWait head-wait-mutation-ignore-deadline OwnDeadlineBounded
HeadWait head-wait-mutation-ignore-cancel EscEndsWait
HeadWait head-wait-mutation-no-probes DeadSocketFound
VERDICTS
