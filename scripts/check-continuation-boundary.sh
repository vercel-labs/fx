#!/usr/bin/env bash
# fx's continuation module in src/core/continuation decides how a turn that fx
# stopped goes on: the answer for each tool call the stop left running, and
# whether the model reads a resume notice. It never acts: its callers carry out
# its answers. Code outside imports only the front door, continuation.zig.
# The module imports only the standard library and its own files, and its
# production code, everything above each file's first test, performs no I/O,
# reads no clock, starts no thread, allocates nothing, and keeps no mutable
# global state.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

folder="src/core/continuation"

reaching_in="$({
  git grep --untracked -n -E '@import\("[^"]*continuation/[a-z_]+\.zig"\)' -- src ":(exclude)$folder" || true
} | grep -v 'continuation/continuation\.zig")' || true)"
if [[ -n "$reaching_in" ]]; then
  printf 'Only %s/continuation.zig may be imported from outside the continuation module:\n%s\n' "$folder" "$reaching_in" >&2
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
  printf 'The continuation module may import only std and its own files:\n%s' "$reaching_out" >&2
  exit 1
fi

acting=""
while IFS= read -r file; do
  found="$(awk '
    /^test "/ { exit }
    /^[[:space:]]*\/\// { next }
    /std\.(Io|fs|posix|os|process|Thread|time|heap|crypto\.random)([^A-Za-z_]|$)|std\.debug\.print|Allocator|^(pub )?var / {
      print FILENAME ":" FNR ": " $0
    }
  ' "$file")"
  if [[ -n "$found" ]]; then
    acting+="$found"$'\n'
  fi
done < <(git ls-files --cached --others --exclude-standard -- "$folder/*.zig")
if [[ -n "$acting" ]]; then
  printf 'The continuation module decides and never acts: no I/O, clocks, threads, allocation, or mutable globals above its tests:\n%s' "$acting" >&2
  exit 1
fi
