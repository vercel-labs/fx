#!/bin/sh
# Model-check ShellEvalError, the error prefix the quoting-error test of
# tests/e2e/ask-presentation.test.ts accepts for each login shell, and require
# each config's expected verdict.
#
# fixed.cfg must pass. head.cfg is the rule before the fix and must fail
# QuotingErrorAccepted for bash 3.2. mutant-any-line.cfg plants a matcher that
# accepts any line and must fail CleanLineRejected.
#
# Run the real shells through the test's real matcher and have TLC replay them:
#   bun test ../drivers/shell_eval_error/
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<EOT
ShellEvalError fixed -
ShellEvalError head QuotingErrorAccepted
ShellEvalError mutant-any-line CleanLineRejected
EOT
