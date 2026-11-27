#!/usr/bin/env bash
# fx's bash results module in src/core/bash_results turns a bash program's output
# into the model's header, shape, and preview. Code outside imports only its front
# door, bash_results.zig. The module imports only the standard library, its own
# files, and fuzz_corpus (the saved inputs the build gives its fuzz test).

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

folder="src/core/bash_results"

reaching_in="$({
  git grep --untracked -n -E '@import\("[^"]*bash_results/[a-z_]+\.zig"\)' -- src ":(exclude)$folder" || true
} | grep -v 'bash_results/bash_results\.zig")' || true)"
if [[ -n "$reaching_in" ]]; then
  printf 'Only %s/bash_results.zig may be imported from outside the bash results module:\n%s\n' "$folder" "$reaching_in" >&2
  exit 1
fi

allowed='^(std|fuzz_corpus|[a-z_]+\.zig)$'
reaching_out=""
while IFS= read -r line; do
  target="${line#*@import(\"}"
  target="${target%\")}"
  if [[ ! "$target" =~ $allowed ]]; then
    reaching_out+="$line"$'\n'
  fi
done < <(git grep --untracked -n -o -E '@import\("[^"]+"\)' -- "$folder" || true)
if [[ -n "$reaching_out" ]]; then
  printf 'The bash results module may import only std and its own files:\n%s' "$reaching_out" >&2
  exit 1
fi
