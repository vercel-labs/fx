#!/bin/sh
# Prove the trace tooling can both accept and reject.
#
# Runs the Python stand-in log three ways and checks the verdicts:
#   correct implementation            -> ACCEPTED
#   recovery keeps a torn tail (bug)  -> REJECTED at step 8 (the Recover)
#   one field changed in a good trace -> REJECTED at step 5 (acked 2 -> 3)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/session-manager-selftest.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

python3 "$here/stand_in_log.py" "$tmp/good.log" "$tmp/good.ndjson"
python3 "$here/stand_in_log.py" "$tmp/bad.log" "$tmp/bad.ndjson" keep_torn_tail
sed '5s/"acked": 2/"acked": 3/' "$tmp/good.ndjson" > "$tmp/tampered.ndjson"

failures=0
expect() { # name trace wanted_exit wanted_text
    set +e
    got=$("$here/validate.sh" SessionLog "$2" 2>&1)
    code=$?
    set -e
    if [ "$code" -eq "$3" ] && printf '%s' "$got" | grep -q "$4"; then
        echo "ok    $1: $(printf '%s' "$got" | head -1)"
    else
        echo "FAIL  $1: exit $code, wanted $3 and '$4'"
        printf '%s\n' "$got" | sed 's/^/      /'
        failures=$((failures + 1))
    fi
}

expect "correct implementation" "$tmp/good.ndjson" 0 "ACCEPTED"
expect "recovery keeps a torn tail" "$tmp/bad.ndjson" 1 "step 8 of"
expect "tampered acked field" "$tmp/tampered.ndjson" 1 "step 5 of"

if [ "$failures" -eq 0 ]; then
    echo "trace selftest passed"
    exit 0
fi
echo "trace selftest failed: $failures case(s)"
exit 1
