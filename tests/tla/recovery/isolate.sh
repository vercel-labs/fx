#!/bin/sh
# Require every planted defect to break exactly the rule it targets: for each
# check that must be violated, write a copy of its config without the target
# property and require the copy to pass. A defect that another rule also
# catches fails here, even though its own check passes.
#
# Reads the checks on standard input in the format tlc_verdicts takes (see
# ../lib/tlc.sh), so check.sh can pass the same table to both:
#
#   <Spec> <config> <expect> [extra TLC flags...]
#
# Checks whose <expect> is "-", "simulate", or "deadlock" have no target and
# are skipped. The target is <expect>, except for "temporal": then the config
# must list exactly one property, and that property is the target. Each
# config lists one invariant or property per line. Pass config names as
# arguments to check only those; names of checks without a target are
# ignored, and tlc_verdicts reports names that match no check. Returns 1 when
# a copy fails or when a target is missing from its config.
#
# The copies run ISOLATE_JOBS at a time (default 4), each through
# tlc_verdicts, and their results print in table order.
#
# Usage, from check.sh:
#   printf '%s\n' "$checks" | ./isolate.sh "$@"
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

isolate_jobs="${ISOLATE_JOBS:-4}"
case "$isolate_jobs" in '' | *[!0-9]* | 0)
    echo "ISOLATE_JOBS must be a positive whole number" >&2
    exit 2
    ;;
esac

copies="$(mktemp -d "${TMPDIR:-/tmp}/fx-tla-isolate.XXXXXX")" || {
    echo "cannot create a private folder under ${TMPDIR:-/tmp}" >&2
    exit 2
}
cp ./*.tla "$copies/"
echo "copies: $copies"

isolate_status=0
isolate_rows=""
while read -r spec config expect flags; do
    case "$spec" in '' | '#'*) continue ;; esac
    case "$expect" in - | simulate | deadlock) continue ;; esac
    if [ "$#" -gt 0 ]; then
        case " $* " in *" $config "*) ;; *) continue ;; esac
    fi
    target="$expect"
    if [ "$expect" = temporal ]; then
        target="$(awk '
            /^[A-Z]/ { listed = ($1 == "PROPERTY" || $1 == "PROPERTIES"); next }
            listed && NF == 1 && $1 !~ /^\\\*/ { count++; name = $1 }
            END { if (count == 1) print name }
        ' "$config.cfg")"
        if [ -z "$target" ]; then
            echo "FAIL  $config: a temporal check must list exactly one property"
            isolate_status=1
            continue
        fi
    fi
    copy="$config-without-$target"
    # Drops the target's line, and a section header left with no entries.
    if ! awk -v drop="$target" '
        /^[A-Z]/ {
            held = ""
            listed = ($1 ~ /^(INVARIANTS?|PROPERTY|PROPERTIES)$/)
            if (listed) { held = $0; next }
            print
            next
        }
        listed && NF == 1 && $1 == drop { found = 1; next }
        listed && NF == 1 && $1 !~ /^\\\*/ {
            if (held != "") { print held; held = "" }
        }
        { print }
        END { if (!found) exit 3 }
    ' "$config.cfg" >"$copies/$copy.cfg"; then
        echo "FAIL  $config: $target is not listed in $config.cfg"
        isolate_status=1
        continue
    fi
    isolate_rows="$isolate_rows$spec $copy - $flags
"
done

if [ -n "$isolate_rows" ]; then
    cd "$copies"
    isolate_count=0
    isolate_running=0
    while read -r row; do
        [ -n "$row" ] || continue
        isolate_count=$((isolate_count + 1))
        # Every copy runs: the arguments already chose the checks above.
        # A run that cannot start leaves no status file, which counts as a
        # failure below.
        (
            # shellcheck disable=SC2119
            if printf '%s\n' "$row" | tlc_verdicts >"run$isolate_count.out" 2>&1; then
                echo 0 >"run$isolate_count.status"
            else
                echo 1 >"run$isolate_count.status"
            fi
        ) &
        isolate_running=$((isolate_running + 1))
        if [ "$isolate_running" -ge "$isolate_jobs" ]; then
            wait
            isolate_running=0
        fi
    done <<EOF
$isolate_rows
EOF
    wait
    i=1
    while [ "$i" -le "$isolate_count" ]; do
        # Each run prints its own log folder; a FAIL line names its log.
        grep -v '^logs: ' "run$i.out" || true
        [ "$(cat "run$i.status" 2>/dev/null || true)" = 0 ] || isolate_status=1
        i=$((i + 1))
    done
fi
exit "$isolate_status"
