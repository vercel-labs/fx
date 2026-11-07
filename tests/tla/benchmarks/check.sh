#!/bin/sh
# Model-check the fixture folder of benchmarks/startup.sh with TLC and require
# each config's expected verdict.
#
# startup-fixture.cfg is the design and must pass: mktemp -d makes the folder,
# the EXIT trap is set only after mktemp succeeds, and other programs may make
# folders under TMPDIR at any time. startup-fixture-today.cfg is the script
# before the change, which removed a folder already at its PID path
# (RemovesOnlyOwn). Each startup-fixture-mutation-*.cfg plants one defect, and
# the rule it names must catch it:
#
#   no-trap           mktemp, but no EXIT trap                       LeavesNothing
#   glob-cleanup      cleanup removes every fixture-named folder     RemovesOnlyOwn
#   reused-name       a pattern name made with mkdir -p, unchecked   WorksInOwn
#   mkdir-after-trap  the PID path, a plain mkdir after the trap     RemovesOnlyOwn
#
# StartupFixtureTrace.tla checks runs of the real script against the model;
# tests/tla/drivers/benchmarks/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh startup-fixture startup-fixture-today
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
StartupFixture startup-fixture -
StartupFixture startup-fixture-today RemovesOnlyOwn
StartupFixture startup-fixture-mutation-no-trap LeavesNothing
StartupFixture startup-fixture-mutation-glob-cleanup RemovesOnlyOwn
StartupFixture startup-fixture-mutation-reused-name WorksInOwn
StartupFixture startup-fixture-mutation-mkdir-after-trap RemovesOnlyOwn
VERDICTS
