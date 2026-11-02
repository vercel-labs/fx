#!/bin/sh
# Run TLC once on a spec and a config, for the Bun drivers and Python checkers
# under tests/tla/.
#
# Usage: run-tlc.sh <Module.tla> <Config.cfg> [extra TLC arguments...]
#
# Every .tla file in the spec's folder and the config are copied into a fresh
# work folder, so TLC never writes next to the models. Set KEEP_TLC_WORK=1 to
# keep that folder. Exits with TLC's own code (0 pass, 12 safety violation,
# 13 liveness violation), or 2 for a toolchain problem. TLC and Java come from
# the same places as in tlc.sh.
set -eu

if [ "$#" -lt 2 ]; then
    echo "usage: run-tlc.sh <Module.tla> <Config.cfg> [TLC args...]" >&2
    exit 2
fi
# shellcheck source=tlc.sh
. "$(dirname "$0")/tlc.sh"
tlc_find

spec="$1"
cfg="$2"
shift 2
[ -f "$spec" ] || { echo "run-tlc.sh: spec not found: $spec" >&2; exit 2; }
[ -f "$cfg" ] || { echo "run-tlc.sh: config not found: $cfg" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/fx-tlc.XXXXXX")"
mkdir -p "$work/model" "$work/tmp" "$work/states"
cp "$(dirname "$spec")"/*.tla "$work/model/"
cp "$cfg" "$work/model/"

echo "run-tlc.sh: java=$tlc_java jar=$tlc_jar work=$work" >&2
set +e
(
    cd "$work/model" &&
        "$tlc_java" -XX:+UseParallelGC -Xmx512m "-Djava.io.tmpdir=$work/tmp" -cp "$tlc_jar" tlc2.TLC \
            -workers 1 -metadir "$work/states" -config "$(basename "$cfg")" "$@" "$(basename "$spec")"
)
status=$?
set -e

[ "${KEEP_TLC_WORK:-0}" = "1" ] || rm -rf "$work"
exit "$status"
