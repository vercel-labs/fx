#!/bin/sh
# Model-check fx doctor's network probes, their one deadline, and the ending
# signals, and require each config's expected verdict.
#
# doctor.cfg is the design and must pass, and so must doctor-cap.cfg, the
# same design with one slot, so the second child waits for the first. Each
# doctor-mutation-*.cfg removes one part of it, and the rule it names must
# catch it:
#
#   no-flag        reads a slot or pipe that is not done   NoTornReport
#   join           waits for every check, not the timer    temporal (Reports)
#   no-kill        never kills a hung child, so the join   temporal (Reports)
#                  waits for it forever
#   no-group       kills only the child, not what it       NoChildAfterExit
#                  started in its group
#   group-only     kills the child's group but not the     NoChildAfterExit
#                  server it started in a group of its own
#   no-cancel      never cancels a hung probe or a         temporal (Reports)
#                  blocked waiter, so the join waits forever
#   no-join        reports before every probe and waiter   NoTaskAfterReport
#                  has ended
#   no-stop-check  keeps starting checks after a signal    NoStartAfterSignalSeen
#   handler-exits  the signal handler kills the children   NoChildAfterExit
#                  listed so far and ends doctor at once,
#                  missing one spawned but not yet listed
#   no-cap         starts a child with no free slot        CapHolds
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
Doctor doctor-cap -
Doctor doctor-mutation-no-flag NoTornReport
Doctor doctor-mutation-join temporal
Doctor doctor-mutation-no-kill temporal
Doctor doctor-mutation-no-group NoChildAfterExit
Doctor doctor-mutation-group-only NoChildAfterExit
Doctor doctor-mutation-no-cancel temporal
Doctor doctor-mutation-no-join NoTaskAfterReport
Doctor doctor-mutation-no-stop-check NoStartAfterSignalSeen
Doctor doctor-mutation-handler-exits NoChildAfterExit
Doctor doctor-mutation-no-cap CapHolds
VERDICTS
