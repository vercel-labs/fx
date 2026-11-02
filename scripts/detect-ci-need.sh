#!/usr/bin/env bash
# Decide which of CI's long model checks a change needs.
#
# Usage: detect-ci-need.sh <base-revision> <head-revision>
#
# libfx: the durable-session model check in the SDK (Bun + N-API/WASM) job
# model-checks tests/tla/sdk/ and drives libfx along its state graphs, which
# takes about 40 minutes. A pull request runs it only when it touches code
# libfx owns: sdk/, the SDK models in tests/tla/sdk/, their drivers in
# tests/tla/drivers/*.mjs, the Node-API and WebAssembly core entry points,
# src/acp/, src/core/hosts/, or src/core/session_manager/.
#
# mcp: the TLA+ MCP models and drivers job model-checks tests/tla/mcp/ and
# tests/tla/mcp_host/ and drives the MCP engine and fx along them, which takes
# about 20 minutes. A pull request runs it only when it touches src/mcp/,
# src/core/mcp_host/, src/core/mcp/, those models, their drivers in
# tests/tla/drivers/mcp/, tests/tla/drivers/mcp_host/, and
# tests/tla/drivers/lib/, the MCP fixtures in tests/e2e/fixtures/, or the
# helpers the drivers load: tests/e2e/tmux-helpers.ts,
# tests/evals/eval-helpers.ts, and tests/e2e/render-lab/tape.ts.
#
# Both run when the change touches build.zig, build.zig.zon,
# .github/workflows/ci.yml, or this script. A change to shared code the checks
# also run, such as the agent loop, is checked by the run on main. Set
# CI_NEED_REQUESTED to a reason to force both checks.
#
# Writes libfx=true|false and mcp=true|false to $GITHUB_OUTPUT and the reasons
# to $GITHUB_STEP_SUMMARY when those files are set. Exits non-zero when either
# revision cannot be read, so the checks fail instead of passing without having
# looked at the change.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  printf 'usage: %s <base-revision> <head-revision>\n' "$0" >&2
  exit 2
fi

base="$1"
head="$2"

libfx=false
mcp=false
libfx_reasons=()
mcp_reasons=()

require_libfx() {
  libfx=true
  libfx_reasons+=("$1")
}

require_mcp() {
  mcp=true
  mcp_reasons+=("$1")
}

require_both() {
  require_libfx "$1"
  require_mcp "$1"
}

for revision in "$base" "$head"; do
  if ! git rev-parse --verify --quiet "$revision^{commit}" >/dev/null; then
    printf 'error: cannot read revision %s; CI cannot decide which checks to run\n' "$revision" >&2
    exit 1
  fi
done

if ! changed_files="$(git diff --name-only --no-renames "$base" "$head")"; then
  printf 'error: git diff %s %s failed; CI cannot decide which checks to run\n' "$base" "$head" >&2
  exit 1
fi

if [ -n "${CI_NEED_REQUESTED:-}" ]; then
  require_both "$CI_NEED_REQUESTED"
fi

while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    .github/workflows/ci.yml | scripts/detect-ci-need.sh)
      require_both "$path: the checks changed" ;;
    build.zig | build.zig.zon)
      require_both "$path: build configuration changed" ;;
    sdk/*)
      require_libfx "$path: libfx SDK changed" ;;
    tests/tla/sdk/*)
      require_libfx "$path: libfx model changed" ;;
    # Before the libfx drivers: in a case pattern * also matches /, so the
    # *.mjs pattern below would take these folders' .mjs files too.
    tests/tla/drivers/mcp/* | tests/tla/drivers/mcp_host/* | tests/tla/drivers/lib/*)
      require_mcp "$path: MCP driver changed" ;;
    tests/tla/drivers/*.mjs)
      # The other drivers' folders hold other models' code.
      if [[ "${path#tests/tla/drivers/}" != */* ]]; then
        require_libfx "$path: libfx driver changed"
      fi ;;
    src/napi_*.zig | src/wasm_core_main.zig)
      require_libfx "$path: libfx entry point changed" ;;
    src/acp/* | src/core/hosts/* | src/core/session_manager/*)
      require_libfx "$path: code libfx owns changed" ;;
    src/mcp/* | src/core/mcp_host/* | src/core/mcp/*)
      require_mcp "$path: MCP code changed" ;;
    tests/tla/mcp/* | tests/tla/mcp_host/*)
      require_mcp "$path: MCP model changed" ;;
    tests/e2e/fixtures/mcp-* | tests/e2e/tmux-helpers.ts | tests/evals/eval-helpers.ts | tests/e2e/render-lab/tape.ts)
      require_mcp "$path: a file the MCP drivers load changed" ;;
  esac
done <<<"$changed_files"

# Prints whether one check runs, and why. The reasons follow the name and
# whether it is needed.
report() {
  local name="$1" needed="$2"
  shift 2
  if [ "$needed" = true ]; then
    printf '%s check needed:\n' "$name"
    printf '  %s\n' "$@"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      {
        printf '### %s check runs\n\n' "$name"
        printf -- '- %s\n' "$@"
        printf '\n'
      } >>"$GITHUB_STEP_SUMMARY"
    fi
  else
    printf 'No %s change; the %s check runs on main.\n' "$name" "$name"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      printf 'No %s change; the %s check runs on main.\n\n' "$name" "$name" >>"$GITHUB_STEP_SUMMARY"
    fi
  fi
}

# The ${array[@]+...} form keeps an empty array from tripping set -u in bash
# 3.2, which macOS ships.
report libfx "$libfx" ${libfx_reasons[@]+"${libfx_reasons[@]}"}
report MCP "$mcp" ${mcp_reasons[@]+"${mcp_reasons[@]}"}

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf 'libfx=%s\n' "$libfx"
    printf 'mcp=%s\n' "$mcp"
  } >>"$GITHUB_OUTPUT"
fi
