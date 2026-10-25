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

# One step out: a file the folder imports may not import src/ui or main.zig
# itself, so the folder never holds a type through an app runtime that owns
# the screen.
one_step=""
while IFS= read -r match; do
  [[ -z "$match" ]] && continue
  source_file="${match%%:*}"
  relative="${match#*@import(\"}"
  relative="${relative%%\")*}"
  [[ "$relative" == *.zig ]] || continue
  target_dir="$(cd "$(dirname "$source_file")/$(dirname "$relative")" 2>/dev/null && pwd -P)" || continue
  target="$target_dir/$(basename "$relative")"
  [[ -f "$target" ]] || continue
  case "$target" in "$repo_root/$folder/"*) continue ;; esac
  if grep -q -E '@import\("([^"]*/)?ui/[^"]*"\)|@import\("([^"]*/)?main\.zig"\)' "$target"; then
    one_step+="${source_file} imports ${target#"$repo_root"/}, which imports src/ui or main.zig"$'\n'
  fi
done < <(git grep --untracked -o -E '@import\("[^"]+\.zig"\)' -- "$folder")
if [[ -n "$one_step" ]]; then
  printf 'An agent reaches no screen through the files it imports:\n%s' "$one_step" >&2
  exit 1
fi
