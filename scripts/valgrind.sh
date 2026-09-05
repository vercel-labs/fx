#!/usr/bin/env bash
# Run di under valgrind memcheck. Builds a Debug binary (symbols kept) and
# exercises the offline CLI surface plus an optional live `di ask` turn.
#
#   scripts/valgrind.sh                 # offline checks only
#   scripts/valgrind.sh --ask "prompt"  # also run one ask turn (needs a credential)
#   scripts/valgrind.sh --tests FILTER  # run unit tests matching FILTER under valgrind
set -euo pipefail
cd "$(dirname "$0")/.."

command -v valgrind >/dev/null || { echo "valgrind not installed" >&2; exit 2; }
ZIG=${ZIG:-zig}
ZIG_BUILD_ARGS=${ZIG_BUILD_ARGS:--Dtarget=x86_64-linux-gnu}

ask_prompt=""
test_filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ask) ask_prompt=$2; shift 2 ;;
    --tests) test_filter=$2; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

out=${VALGRIND_OUT:-zig-out/valgrind}
mkdir -p "$out"
"$ZIG" build -Doptimize=Debug $ZIG_BUILD_ARGS --prefix "$out/prefix" >/dev/null
bin="$out/prefix/bin/di"

vg=(valgrind --error-exitcode=99 --leak-check=full --show-leak-kinds=definite
    --errors-for-leak-kinds=definite --track-origins=yes --suppressions=scripts/valgrind.supp)

run() {
  local name=$1; shift
  echo "== valgrind: $name"
  "${vg[@]}" --log-file="$out/$name.log" "$@" >/dev/null 2>&1 || {
    echo "FAIL $name (see $out/$name.log)" >&2
    grep -E 'ERROR SUMMARY|definitely lost' "$out/$name.log" >&2 || true
    return 1
  }
  grep -E 'ERROR SUMMARY' "$out/$name.log"
}

status=0
run version "$bin" --version || status=1
run help "$bin" --help || status=1
run doctor "$bin" doctor || status=1
run sessions "$bin" sessions || status=1

if [ -n "$ask_prompt" ]; then
  run ask "$bin" ask --no-save --quiet --auto -- "$ask_prompt" || status=1
fi

if [ -n "$test_filter" ]; then
  echo "== valgrind: tests ($test_filter)"
  "$ZIG" build test $ZIG_BUILD_ARGS -Doptimize=Debug -Dtest-filter="$test_filter" \
    --test-cmd "${vg[@]}" --test-cmd-bin 2>&1 | tail -20 || status=1
fi

exit $status
