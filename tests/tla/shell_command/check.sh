#!/bin/sh
# Model-check the shell command models with TLC and require each config's
# expected verdict.
#
# GitAdmission (src/core/shell_command/safe_git.zig): how an agent git command
# is planned, admitted, and run in every permission mode and shell environment.
# git-admission.cfg must pass; git-admission-mutation.cfg plants a bug that
# HoldSafety must catch, and git-admission-env-mutation.cfg drops the agent
# environment, which ExposureOnlyDocumented must catch.
#
# ShellContract: one model turn through the shell tool, for the design fx
# implements ("current") and a redesign ("proposed"). proposed.cfg and
# current-holds.cfg must pass. Each current-*.cfg shows a property the current
# design breaks, and each mutant-*.cfg plants a bug that its property must
# catch.
#
# Run the real binary through every modeled shell call and have TLC replay it:
#   bun test ../drivers/shell_command/
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
GitAdmission git-admission - -deadlock
GitAdmission git-admission-mutation HoldSafety -deadlock
GitAdmission git-admission-env-mutation ExposureOnlyDocumented -deadlock
ShellContract proposed -
ShellContract current-holds -
ShellContract current-completeness Completeness
ShellContract current-history HistoryFidelity
ShellContract current-zsh ZshForgiving
ShellContract mutant-admission-raw AdmissionConsistency
ShellContract mutant-guess Exactness
EOF
