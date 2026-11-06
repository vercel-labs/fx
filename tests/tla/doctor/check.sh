#!/bin/sh
# Model-check fx doctor's network probes and their one deadline, and require
# each config's expected verdict.
#
# doctor.cfg is the design and must pass. Each doctor-mutation-*.cfg removes
# one part of it, and the rule it names must catch it:
#
#   no-flag   reads a slot or pipe that is not done       NoTornReport
#   join      waits for every check, not the timer        temporal (Reports)
#   no-kill   exits with a child still running            NoChildAfterExit
#   no-group  kills only the child, not what it started    NoChildAfterExit
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
Doctor doctor-mutation-no-kill NoChildAfterExit
Doctor doctor-mutation-no-group NoChildAfterExit
VERDICTS
