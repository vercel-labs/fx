#!/usr/bin/env bash
# fx's tool bridge module in src/core/tool_bridge owns the session's per-call
# Unix socket bridge and its handler capability interface. Code outside imports
# only its front door, tool_bridge.zig. The module imports only std, builtin,
# fuzz_corpus (the saved inputs the build gives a fuzz test),
# its own files, shared basics (types.zig, io.zig, debug_trace.zig,
# text_utils.zig), and command_runner.zig.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

folder="src/core/tool_bridge"
front_door="$folder/tool_bridge.zig"

# Prints PATH with its `.`, empty, and `..` parts resolved, as the compiler
# resolves an import: `a//b/./c` becomes `a/b/c`, and `a/b/../c` becomes `a/c`.
normalize_path() {
  local result="" part
  local IFS=/
  set -f
  for part in $1; do
    case "$part" in
      .) ;;
      ..)
        if [[ "$result" == */* ]]; then
          result="${result%/*}"
        else
          result=""
        fi
        ;;
      *)
        if [[ -z "$result" ]]; then
          result="$part"
        else
          result="$result/$part"
        fi
        ;;
    esac
  done
  set +f
  printf '%s' "$result"
}

# Every import in src outside the folder, as "file:line:target", with the
# target resolved from the importing file's folder. Imports by module name
# have no slash and never name a file inside the folder.
reaching_in=""
while IFS= read -r line; do
  file="${line%%:*}"
  rest="${line#*:}"
  target="${rest#*@import(\"}"
  target="${target%\")}"
  case "$target" in
    */* | *.zig) ;;
    *) continue ;;
  esac
  if [[ "$target" == /* ]]; then
    resolved="$(normalize_path "$target")"
  else
    resolved="$(normalize_path "${file%/*}/$target")"
  fi
  case "$resolved" in
    "$folder"/*)
      # Fuzz roots name the file that declares the test (`test_fuzz_nightly.py`).
      if [[ "$resolved" != "$front_door" ]] && ! [[ "$file" == "src/fuzz_targets.zig" && ( "$resolved" == "$folder/edit_blocks.zig" || "$resolved" == "$folder/wire.zig" ) ]]; then
        reaching_in+="$line"$'\n'
      fi
      ;;
  esac
done < <(git grep --untracked -n -o -E '@import\("[^"]+"\)' -- src ":(exclude)$folder" || true)
if [[ -n "$reaching_in" ]]; then
  printf 'Only %s may be imported from outside the tool bridge module:\n%s' "$front_door" "$reaching_in" >&2
  exit 1
fi

allowed='^(std|builtin|fuzz_corpus|[a-z_]+\.zig|\.\./shared/(types|io|debug_trace|text_utils)\.zig|\.\./execution/command_runner\.zig)$'
reaching_out=""
while IFS= read -r line; do
  target="${line#*@import(\"}"
  target="${target%\")}"
  if [[ ! "$target" =~ $allowed ]]; then
    reaching_out+="$line"$'\n'
  fi
done < <(git grep --untracked -n -o -E '@import\("[^"]+"\)' -- "$folder" || true)
if [[ -n "$reaching_out" ]]; then
  printf 'The tool bridge module may import only std, builtin, fuzz_corpus, its own files, shared basics (types, io, debug_trace, text_utils), and command_runner.zig:\n%s' "$reaching_out" >&2
  exit 1
fi
