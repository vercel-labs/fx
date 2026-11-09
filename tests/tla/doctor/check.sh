#!/bin/sh
# Model-check fx doctor's network probes and their one deadline, and require
# each config's expected verdict.
#
# doctor.cfg is the design and must pass. Each doctor-mutation-*.cfg removes
# one part of it, and the rule it names must catch it:
#
#   no-flag    reads a slot or pipe that is not done      NoTornReport
#   join       waits for every check, not the timer       temporal (Reports)
#   no-kill    never kills a hung child, so the join      temporal (Reports)
#              waits for it forever
#   no-group   kills only the child, not what it started  NoChildAfterExit
#   no-cancel  never cancels a hung probe or a blocked    temporal (Reports)
#              waiter, so the join waits forever
#   no-join    reports before every probe and waiter      NoTaskAfterReport
#              has ended
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh doctor doctor-mutation-join
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
Doctor doctor -
Doctor doctor-mutation-no-flag NoTornReport
Doctor doctor-mutation-join temporal
Doctor doctor-mutation-no-kill temporal
Doctor doctor-mutation-no-group NoChildAfterExit
Doctor doctor-mutation-no-cancel temporal
Doctor doctor-mutation-no-join NoTaskAfterReport
VERDICTS
