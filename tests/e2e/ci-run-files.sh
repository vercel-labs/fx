#!/usr/bin/env bash
# Run E2E files one at a time, each in its own Bun process with its own tmux
# server, so terminal fixtures and process state cannot leak between files.
# A failing file gets one retry after its tmux server is reset. A file that
# passes only on retry is reported as a warning so flaky files stay visible.
set -uo pipefail

if [ "$#" -eq 0 ]; then
  printf 'usage: %s <test-file>...\n' "$0" >&2
  exit 2
fi

cd "$(dirname "$0")" || exit 1

tmux_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fx-e2e-tmux"
status=0
index=0

for test_file in "$@"; do
  tmux_dir="$tmux_root-$index"
  mkdir -p "$tmux_dir"
  if ! TMUX_TMPDIR="$tmux_dir" bun test --max-concurrency 1 "./$test_file"; then
    printf 'Retrying failed E2E file after resetting tmux: %s\n' "$test_file"
    TMUX_TMPDIR="$tmux_dir" tmux kill-server 2>/dev/null || true
    if TMUX_TMPDIR="$tmux_dir" bun test --max-concurrency 1 "./$test_file"; then
      printf '::warning title=E2E passed only on retry::%s failed and then passed on retry. Investigate it as a possible race.\n' "$test_file"
    else
      status=1
    fi
  fi
  TMUX_TMPDIR="$tmux_dir" tmux kill-server 2>/dev/null || true
  index=$((index + 1))
done

exit "$status"
