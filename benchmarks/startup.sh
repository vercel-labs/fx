#!/usr/bin/env bash
#
# Startup latency benchmarks for fx.
#
# Measures wall-clock time for common CLI commands using hyperfine. Each command
# runs in rounds. With --base-binary, the base commit's fx and this build take
# turns in each round on the same host, so benchmarks/check_budgets.py can
# compare their means. Round results are written to benchmarks/results/rounds/.
#
# Usage:
#   ./benchmarks/startup.sh                                 # this build, 100 runs
#   ./benchmarks/startup.sh --quick                         # this build, 20 runs
#   ./benchmarks/startup.sh --ci --base-binary <fx>         # CI: alternate with the base
#
# Requires: hyperfine (https://github.com/sharkdp/hyperfine)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FX_BIN="${REPO_ROOT}/zig-out/bin/fx"
RESULTS_DIR="${REPO_ROOT}/benchmarks/results"
ROUNDS_DIR="${RESULTS_DIR}/rounds"
# An even round count gives each side the first slot in half the rounds.
ALTERNATING_ROUNDS=4
SESSION_FIXTURE_ROOT="${TMPDIR:-/tmp}/fx-session-list-benchmark-$$"
SESSION_FIXTURE_HOME="${SESSION_FIXTURE_ROOT}/home"
SESSION_FIXTURE_WORKSPACE="${SESSION_FIXTURE_ROOT}/workspace"
GENERAL_FIXTURE_HOME="${SESSION_FIXTURE_ROOT}/general-home"

cleanup() {
  rm -rf "$SESSION_FIXTURE_ROOT"
}
trap cleanup EXIT

if ! command -v hyperfine &>/dev/null; then
  echo "error: hyperfine is not installed"
  echo "       brew install hyperfine  (macOS)"
  echo "       apt install hyperfine   (Debian/Ubuntu)"
  echo "       cargo install hyperfine (Rust/Cargo)"
  exit 1
fi

RUNS=100
WARMUP=10
SKIP_BUILD=false
CI_MODE=false
BASE_BIN=""
SHELL_OPTS=(-N)
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) RUNS=20; WARMUP=3 ;;
    --ci) RUNS=100; WARMUP=10; SKIP_BUILD=true; CI_MODE=true ;;
    --base-binary) BASE_BIN="${2:?error: --base-binary needs a path}"; shift ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$CI_MODE" = true ] && [ -z "$BASE_BIN" ]; then
  echo "error: --ci needs --base-binary: the budget compares this build with the base commit" >&2
  exit 2
fi

ROUNDS=1
if [ -n "$BASE_BIN" ]; then
  if [ ! -x "$BASE_BIN" ]; then
    echo "error: base binary not found at $BASE_BIN" >&2
    exit 1
  fi
  ROUNDS=$ALTERNATING_ROUNDS
fi
ROUND_RUNS=$((RUNS / ROUNDS))
ROUND_WARMUP=$((WARMUP / ROUNDS))

if [ "$SKIP_BUILD" = false ]; then
  echo "Building fx (ReleaseSafe)..."
  (cd "$REPO_ROOT" && zig build -Doptimize=ReleaseSafe)
fi

if [ ! -x "$FX_BIN" ]; then
  echo "error: fx binary not found at $FX_BIN"
  exit 1
fi

rm -rf "$ROUNDS_DIR"
mkdir -p "$ROUNDS_DIR"
mkdir -p "$SESSION_FIXTURE_HOME" "$SESSION_FIXTURE_WORKSPACE" "$GENERAL_FIXTURE_HOME"
mkdir -p "$GENERAL_FIXTURE_HOME/.fx"
chmod 700 "$GENERAL_FIXTURE_HOME/.fx"
printf '%s\n' \
  '{"model":"openai/gpt-5.4","effort":"high","fast_mode":false,"startup_scrollback":true,"prompt_history":{"enabled":true},"statusLine":{"sandbox":true,"context":true},"permission":{"bash":{"git status *":"allow"}}}' \
  > "$GENERAL_FIXTURE_HOME/.fx/settings.json"
chmod 600 "$GENERAL_FIXTURE_HOME/.fx/settings.json"
python3 "${REPO_ROOT}/benchmarks/session_list_fixture.py" \
  --home "$SESSION_FIXTURE_HOME" \
  --workspace "$SESSION_FIXTURE_WORKSPACE"

if [ -x /usr/bin/true ]; then
  TRUE_BIN=/usr/bin/true
elif [ -x /bin/true ]; then
  TRUE_BIN=/bin/true
else
  TRUE_BIN=true
fi

echo "=== fx startup benchmarks ==="
echo "binary: $FX_BIN"
if [ -n "$BASE_BIN" ]; then
  echo "base:   $BASE_BIN"
fi
echo "runs:   $RUNS in $ROUNDS round(s), warm-up $WARMUP"
echo ""

# measure ROUND SIDE NAME STEM HOME EXTRA_ENV COMMAND
# One hyperfine run for one command on one side; the export keeps every run time.
measure() {
  local round=$1 side=$2 name=$3 stem=$4 home=$5 extra_env=$6 command=$7
  mkdir -p "$ROUNDS_DIR/$side"
  env HOME="$home" ${extra_env:+"$extra_env"} hyperfine \
    "${SHELL_OPTS[@]}" \
    --runs "$ROUND_RUNS" \
    --warmup "$ROUND_WARMUP" \
    --export-json "$ROUNDS_DIR/$side/$stem.$round.json" \
    --command-name "$name" \
    "$command"
}

# measure_side ROUND SIDE BINARY
measure_side() {
  local round=$1 side=$2 binary=$3
  echo "--- round $round: $side ---"
  measure "$round" "$side" "process baseline" process-baseline "$GENERAL_FIXTURE_HOME" "" "$TRUE_BIN"
  measure "$round" "$side" "fx (startup)" startup "$GENERAL_FIXTURE_HOME" "FX_BENCH=1" "$binary"
  measure "$round" "$side" "fx help" help "$GENERAL_FIXTURE_HOME" "" "$binary help"
  measure "$round" "$side" "fx status --json" status "$GENERAL_FIXTURE_HOME" "" "$binary status --json"
  measure "$round" "$side" "fx sessions --json" sessions "$SESSION_FIXTURE_HOME" "" "$binary sessions --json"
  echo ""
}

for ((round = 1; round <= ROUNDS; round++)); do
  if [ -z "$BASE_BIN" ]; then
    order=(pr)
  elif ((round % 2 == 1)); then
    order=(base pr)
  else
    order=(pr base)
  fi
  for side in "${order[@]}"; do
    binary="$FX_BIN"
    if [ "$side" = base ]; then
      binary="$BASE_BIN"
    fi
    measure_side "$round" "$side" "$binary"
  done
done

echo "Round results: $ROUNDS_DIR"
