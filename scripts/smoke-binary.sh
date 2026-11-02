#!/usr/bin/env bash
# Run a freshly built fx binary through quick commands. Each command must exit
# zero, print to stdout, and leave stderr empty.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  printf 'usage: %s <fx-binary>\n' "$0" >&2
  exit 2
fi

binary="$1"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

check() {
  local label="$1"
  shift
  if ! "$binary" "$@" >"$work_dir/stdout" 2>"$work_dir/stderr"; then
    printf '::error title=Binary smoke test::fx %s exited with an error\n' "$label"
    cat "$work_dir/stderr" >&2
    return 1
  fi
  if [ ! -s "$work_dir/stdout" ]; then
    printf '::error title=Binary smoke test::fx %s printed nothing\n' "$label"
    return 1
  fi
  if [ -s "$work_dir/stderr" ]; then
    printf '::error title=Binary smoke test::fx %s wrote to stderr\n' "$label"
    cat "$work_dir/stderr" >&2
    return 1
  fi
  printf 'fx %s: ok\n' "$label"
}

check "--version" --version
check "help" help
check "status --json" status --json
