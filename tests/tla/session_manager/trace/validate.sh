#!/bin/sh
# Check that an implementation trace is a behavior of a spec.
#
# usage: ./validate.sh SPEC trace.ndjson
#   SPEC is a spec with a trace wrapper here, for example SessionLog.
#   Needs ../SPEC.tla, ./SPECTrace.tla and ./SPECTrace.cfg.
#
# Exit codes: 0 accepted, 1 rejected (prints the first step the spec does
# not allow), 2 tool or usage error.
set -u

if [ "$#" -ne 2 ]; then
    echo "usage: $0 SPEC trace.ndjson" >&2
    exit 2
fi
spec=$1
here=$(cd "$(dirname "$0")" && pwd)
trace=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")

for f in "$here/../$spec.tla" "$here/${spec}Trace.tla" "$here/${spec}Trace.cfg" "$trace"; do
    if [ ! -f "$f" ]; then
        echo "missing $f" >&2
        exit 2
    fi
done

# shellcheck source=../../lib/tlc.sh
. "$here/../../lib/tlc.sh"
tlc_find
java=$tlc_java
jar=$tlc_jar

work=$(mktemp -d "${TMPDIR:-/tmp}/session-manager-trace.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$here/../$spec.tla" "$here/${spec}Trace.tla" "$here/${spec}Trace.cfg" "$work/"
python3 "$here/to_tla.py" "$trace" "$work/TraceData.tla" || exit 2
steps=$(grep -c . "$trace" || true)

# One worker: the progress register (TLCSet/TLCGet) is per worker. TLC
# unpacks its standard modules into java.io.tmpdir; a private one lets
# several checks run at once.
mkdir "$work/java-tmp"
out=$(cd "$work" && "$java" -Djava.io.tmpdir="$work/java-tmp" -cp "$jar" tlc2.TLC -deadlock -workers 1 -cleanup \
    -metadir "$work/states" -config "${spec}Trace.cfg" "${spec}Trace.tla" 2>&1)

# Match with case, not a pipe into grep -q: grep exits at the first match
# and a large TLC output then fails printf with a broken pipe.
case $out in
    *'Invariant TraceIncomplete is violated'*) verdict=accepted ;;
    *'No error has been found'*) verdict=rejected ;;
    *) verdict=unfinished ;;
esac

if [ "$verdict" = accepted ]; then
    echo "ACCEPTED: all $steps steps are a behavior of $spec"
    exit 0
fi
if [ "$verdict" = rejected ]; then
    matched=$(printf '%s\n' "$out" | sed -n 's/.*"matched_lines", \([0-9]*\)>>.*/\1/p' | tail -1)
    matched=${matched:-0}
    bad=$((matched + 1))
    echo "REJECTED: steps 1..$matched match; step $bad of $steps is not allowed by $spec:"
    sed -n "${bad}p" "$trace"
    exit 1
fi
printf '%s\n' "$out" | tail -15
echo "TOOL ERROR: TLC did not finish the trace check" >&2
exit 2
