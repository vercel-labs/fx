#!/usr/bin/env bash
# Agents keep one conversation's own state in src/core/agents behind one front
# door, agents.zig. Code outside imports only that file. An agent holds no
# screen or terminal state, so the folder never imports src/ui, the terminal
# runtime, or main.zig: the app that shows an agent owns those.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

folder="src/core/agents"

reaching_in="$({
  git grep --untracked -n -E '@import\("([^"]*/)?agents/[a-z_]+\.zig"\)' -- src ":(exclude)$folder" || true
} | grep -v 'agents/agents\.zig")' || true)"
if [[ -n "$reaching_in" ]]; then
  printf 'Only %s/agents.zig may be imported from outside the agents folder:\n%s\n' "$folder" "$reaching_in" >&2
  exit 1
fi

screen_imports="$(git grep --untracked -n -E '@import\("([^"]*/)?(ui|terminal)/[^"]*"\)|@import\("([^"]*/)?main\.zig"\)' -- "$folder" || true)"
if [[ -n "$screen_imports" ]]; then
  printf 'An agent holds no screen or terminal state, so %s may not import src/ui, the terminal runtime, or main.zig:\n%s\n' "$folder" "$screen_imports" >&2
  exit 1
fi
