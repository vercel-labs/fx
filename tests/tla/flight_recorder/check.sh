#!/bin/sh
# Model-check FlightRecorder.tla across the three designs ("current", "queue",
# "mmap"), nine planted mmap mutants (including reservation hole resync, segment
# switch CAS, and size-cap eviction), and ideal/non-ideal simulations.
#
# design-mmap must pass every invariant (R1-R8, EvictOnlySealed, and OneSwitchPerSegment).
# design-queue, current-ring, current-reset, and each mutant-* config must fail
# its named invariant. simulate-ideal and simulate-nonideal run random traces;
# SIM_RUNS sets how many (default 20000).
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
tlc_verdicts "$@" <<EOF
FlightRecorder design-mmap -
FlightRecorder design-queue NoSilentLoss
FlightRecorder current-ring NoSilentLoss
FlightRecorder current-reset NoSilentLoss
FlightRecorder mutant-no-length-header TornOnlyInFlight
FlightRecorder mutant-no-resync NoSilentLoss
FlightRecorder mutant-switch-without-cas OneSwitchPerSegment
FlightRecorder mutant-counter-in-memory NoSilentLoss
FlightRecorder mutant-wait-for-prealloc UiNeverWaitsOnDisk
FlightRecorder mutant-no-exit-mark InstanceEndKnown
FlightRecorder mutant-evict-without-gap NoSilentLoss
FlightRecorder mutant-delete-before-gap NoSilentLoss
FlightRecorder mutant-evict-open EvictOnlySealed
FlightRecorder simulate-ideal simulate $sim
FlightRecorder simulate-nonideal simulate $sim
EOF
