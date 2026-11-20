#!/usr/bin/env bash
# fx's hooks engine in src/hooks matches user hooks to events, runs them
# through the host it is given, and merges their answers. Code outside
# imports only the front door, hooks.zig. The engine imports only the
# standard library and its own files, and its production code, everything
# above each file's first test, does no I/O of its own: it opens no files,
# starts no processes or threads, reads no clock, draws no random numbers,
# prints nothing, and keeps no mutable global state. The host it is given,
# src/hooks/host.zig, does all of that for it.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

folder="src/hooks"

# Resolves "." and ".." parts of a path without touching the disk.
normalize() {
  local path="$1"
  local -a parts=()
  local -a kept=()
  local count=0
  local part
  IFS='/' read -r -a parts <<<"$path"
  for part in "${parts[@]}"; do
    case "$part" in
      '' | '.') ;;
      '..')
        if ((count > 0)); then
          count=$((count - 1))
        fi
        ;;
      *)
        kept[count]="$part"
        count=$((count + 1))
        ;;
    esac
  done
  local joined=""
  local index=0
  while ((index < count)); do
    if [[ -z "$joined" ]]; then
      joined="${kept[$index]}"
    else
      joined="$joined/${kept[$index]}"
    fi
    index=$((index + 1))
  done
  printf '%s\n' "$joined"
}

# Imports are relative to the importing file, and src/core/hooks also has
# files named like this engine's, so resolve each path before comparing.
# Only a path that names "hooks" can resolve inside the folder, so the rest
# skip it without running a command.
reaching_in=""
while IFS= read -r line; do
  file="${line%%:*}"
  target="${line#*@import(\"}"
  target="${target%\")}"
  case "${file%/*}/$target" in
    *hooks*) ;;
    *) continue ;;
  esac
  resolved="$(normalize "${file%/*}/$target")"
  case "$resolved" in
    "$folder/hooks.zig") ;;
    "$folder"/*) reaching_in+="$line"$'\n' ;;
  esac
done < <(git grep --untracked -n -o -E '@import\("[^"]+\.zig"\)' -- src ":(exclude)$folder" || true)
if [[ -n "$reaching_in" ]]; then
  printf 'Only %s/hooks.zig may be imported from outside the hooks engine:\n%s' "$folder" "$reaching_in" >&2
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
  printf 'The hooks engine may import only std and its own files:\n%s' "$reaching_out" >&2
  exit 1
fi

acting=""
while IFS= read -r file; do
  found="$(awk '
    /^test "/ { exit }
    /^[[:space:]]*\/\// { next }
    {
      bad = ($0 ~ /^(pub )?var /)
      rest = $0
      while (!bad && (pos = index(rest, "std.Io")) > 0) {
        rest = substr(rest, pos + 6)
        if (substr(rest, 1, 7) != ".Writer") bad = 1
      }
      if (!bad && $0 ~ /std\.(fs|posix|os|process|Thread|time|net)([^A-Za-z0-9_]|$)/) bad = 1
      if (!bad && $0 ~ /std\.crypto\.random([^A-Za-z0-9_]|$)/) bad = 1
      if (!bad && $0 ~ /std\.debug\.print/) bad = 1
      if (!bad && $0 ~ /std\.heap\.(page_allocator|c_allocator|raw_c_allocator|smp_allocator|wasm_allocator|DebugAllocator|GeneralPurposeAllocator)([^A-Za-z0-9_]|$)/) bad = 1
      if (bad) print FILENAME ":" FNR ": " $0
    }
  ' "$file")"
  if [[ -n "$found" ]]; then
    acting+="$found"$'\n'
  fi
done < <(git ls-files --cached --others --exclude-standard -- "$folder/*.zig")
if [[ -n "$acting" ]]; then
  printf 'The hooks engine does no I/O of its own: no files, processes, threads, clocks, random numbers, printing, or mutable globals above its tests:\n%s' "$acting" >&2
  exit 1
fi
