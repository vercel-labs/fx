#!/bin/sh
# Model-check what an automatic command review tells the reviewer about the
# shell that will run the command (src/core/tooling/tool_admission.zig
# reviewRequestForCall and src/core/permissions/auto_classifier.zig
# serializeEvidence) with TLC, and require each config's expected verdict.
#
# command-environment.cfg is the design and must pass: a reviewed command
# runs only after a clear on a packet that names its environment, its shell,
# and whether the user's startup aliases and functions apply, and a
# shell-routed command that cannot name its shell is held as unavailable
# without a reviewer call. command-environment-today.cfg is fx before it,
# whose packet named none of that and still said the evidence was complete
# (ReviewerSeesInterpreter). Each command-environment-mutation-*.cfg plants
# one defect, and the rule it names must catch it:
#
#   unwired           the request drops the call's environment          ReviewerSeesInterpreter
#   no-startup        no line says whether startup definitions apply    StartupDisclosed
#   unnamed-complete  an unnamed shell is sent as complete evidence     UnnamedShellNeverRuns
#   review-set        routine user-profile commands are reviewed too    ReviewSetUnchanged
#
# CommandEnvironmentTrace.tla checks runs of the built fx binary against the
# model; tests/tla/drivers/tool_admission/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh command-environment command-environment-today
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
CommandEnvironment command-environment -
CommandEnvironment command-environment-today ReviewerSeesInterpreter
CommandEnvironment command-environment-mutation-unwired ReviewerSeesInterpreter
CommandEnvironment command-environment-mutation-no-startup StartupDisclosed
CommandEnvironment command-environment-mutation-unnamed-complete UnnamedShellNeverRuns
CommandEnvironment command-environment-mutation-review-set ReviewSetUnchanged
VERDICTS
