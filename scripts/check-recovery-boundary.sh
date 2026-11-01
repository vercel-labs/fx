#!/usr/bin/env bash
# fx's recovery module in src/core/recovery decides what to do about one model
# request and never acts: fx reports events to step() and carries out the
# plan it returns. Code outside imports only the front door, recovery.zig. The
# module imports only the standard library and its own files, and its
# production code, everything above each file's first test, performs no I/O,
# reads no clock, starts no thread, allocates nothing, and keeps no mutable
# global state.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

folder="src/core/recovery"

reaching_in="$({
  git grep --untracked -n -E '@import\("[^"]*recovery/[a-z_]+\.zig"\)' -- src ":(exclude)$folder" || true
} | grep -v 'recovery/recovery\.zig")' || true)"
if [[ -n "$reaching_in" ]]; then
  printf 'Only %s/recovery.zig may be imported from outside the recovery module:\n%s\n' "$folder" "$reaching_in" >&2
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
  printf 'The recovery module may import only std and its own files:\n%s' "$reaching_out" >&2
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
  printf 'The recovery module decides and never acts: no I/O, clocks, threads, allocation, or mutable globals above its tests:\n%s' "$acting" >&2
  exit 1
fi
