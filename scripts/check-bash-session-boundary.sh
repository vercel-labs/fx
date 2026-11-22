#!/usr/bin/env bash
# fx's bash session module in src/core/bash_session keeps one agent's saved bash
# state. Code outside imports only its front door, bash_session.zig. The module
# imports only the standard library and its own files.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

folder="src/core/bash_session"

reaching_in="$({
  git grep --untracked -n -E '@import\("[^"]*bash_session/[a-z_]+\.zig"\)' -- src ":(exclude)$folder" || true
} | grep -v 'bash_session/bash_session\.zig")' || true)"
if [[ -n "$reaching_in" ]]; then
  printf 'Only %s/bash_session.zig may be imported from outside the bash session module:\n%s\n' "$folder" "$reaching_in" >&2
  exit 1
fi

allowed='^(std|[a-z_]+\.zig)$'
reaching_out=""
while IFS= read -r line; do
  target="${line#*@import(\"}"
  target="${target%\")}"
  if [[ ! "$target" =~ $allowed ]]; then
    reaching_out+="$line"$'\n'
  fi
done < <(git grep --untracked -n -o -E '@import\("[^"]+"\)' -- "$folder" || true)
if [[ -n "$reaching_out" ]]; then
  printf 'The bash session module may import only std and its own files:\n%s' "$reaching_out" >&2
  exit 1
fi
