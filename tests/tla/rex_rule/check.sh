#!/bin/sh
# Model-check RexRule: the require line and fx.lua in Rex's init.lua, fx's
# lock, and the rollback, against five safety invariants.
#
# design and design-three must pass, with crashes and faults on. Each
# mutant-* plants one bug and must fail the invariant named in its verdict
# below. simulate-ideal and simulate-nonideal run random walks; SIM_RUNS sets
# how many (default 20000).
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes. CI does not
# run this check.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
tlc_verdicts "$@" <<EOF
RexRule design -
RexRule design-three -
RexRule mutant-line-first NoDanglingRequire
RexRule mutant-rollback-order NoDanglingRequire
RexRule mutant-no-lock OneWriter
RexRule mutant-ignore-removal NoReAddAfterRemoval
RexRule mutant-double-line AtMostOneLine
RexRule mutant-restore-backup UserTextKept
RexRule simulate-ideal simulate $sim
RexRule simulate-nonideal simulate $sim
EOF
