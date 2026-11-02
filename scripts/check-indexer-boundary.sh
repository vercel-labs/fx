#!/usr/bin/env bash
# fx-indexer keeps native workspace discovery in src/core/indexer behind one
# front door, indexer.zig. Code outside imports only that file. The indexer
# imports only the standard library, its own files, and fx's shared io.zig and
# debug_trace.zig, and it never starts a process: it reads repository metadata
# as data, so a repository's configuration can never make it run a program.
# @-completion and the glob and grep tools list files only through it, so
# their production code, everything above each file's first test, never
# starts a process either.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

folder="src/core/indexer"

reaching_in="$({
  git grep --untracked -n -E '@import\("[^"]*indexer/[a-z_]+\.zig"\)' -- src ":(exclude)$folder" || true
} | grep -v 'indexer/indexer\.zig")' || true)"
if [[ -n "$reaching_in" ]]; then
  printf 'Only %s/indexer.zig may be imported from outside the indexer:\n%s\n' "$folder" "$reaching_in" >&2
  exit 1
fi

allowed='^(std|builtin|[a-z_]+\.zig|\.\./shared/(io|debug_trace)\.zig)$'
reaching_out=""
while IFS= read -r line; do
  target="${line#*@import(\"}"
  target="${target%\")}"
  if [[ ! "$target" =~ $allowed ]]; then
    reaching_out+="$line"$'\n'
  fi
done < <(git grep --untracked -n -o -E '@import\("[^"]+"\)' -- "$folder" || true)
if [[ -n "$reaching_out" ]]; then
  printf 'The indexer may import only std, its own files, io.zig and debug_trace.zig:\n%s' "$reaching_out" >&2
  exit 1
fi

spawning="$(git grep --untracked -n -E 'std\.process|posix_spawn|execv[pe]*\(|fork\(|popen\(' -- "$folder" || true)"
if [[ -n "$spawning" ]]; then
  printf 'The indexer must never start a process:\n%s\n' "$spawning" >&2
  exit 1
fi

listing_features=(
  src/core/workspace/file_index.zig
  src/core/workspace/tool_files.zig
  src/core/workspace/grep_search.zig
  src/tools/filesystem/glob_files.zig
  src/tools/filesystem/grep_files.zig
)
feature_spawning=""
for file in "${listing_features[@]}"; do
  found="$(awk '/^test "/ { exit } /std\.process\.(run|spawn|Child)|safe_git/ { print FILENAME ":" FNR ": " $0 }' "$file")"
  if [[ -n "$found" ]]; then
    feature_spawning+="$found"$'\n'
  fi
done
if [[ -n "$feature_spawning" ]]; then
  printf '@-completion, glob_files and grep_files must list files through the indexer and never start a process:\n%s' "$feature_spawning" >&2
  exit 1
fi
