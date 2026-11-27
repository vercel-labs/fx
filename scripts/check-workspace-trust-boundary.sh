#!/usr/bin/env bash
# fx's workspace trust module in src/core/workspace_trust decides whether the
# TUI asks to trust the folder fx starts in, and which saved record covers it.
# Code outside imports only its front door, workspace_trust.zig. Inside the
# folder, the module imports only the standard library, its own files, and five
# files from outside it: repo_root.zig, io.zig, profile_paths.zig, debug_trace.zig,
# and config_runtime.zig.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

folder="src/core/workspace_trust"

reaching_in="$({
  git grep --untracked -n -E '@import\("[^"]*workspace_trust/[a-z_]+\.zig"\)' -- src ":(exclude)$folder" || true
} | grep -v 'workspace_trust/workspace_trust\.zig")' || true)"
if [[ -n "$reaching_in" ]]; then
  printf 'Only %s/workspace_trust.zig may be imported from outside the workspace trust module:\n%s\n' "$folder" "$reaching_in" >&2
  exit 1
fi

allowed='^(std|[a-z_]+\.zig|\.\./workspace/repo_root\.zig|\.\./shared/(io|profile_paths|debug_trace)\.zig|\.\./config/config_runtime\.zig)$'
reaching_out=""
while IFS= read -r line; do
  target="${line#*@import(\"}"
  target="${target%\")}"
  if [[ ! "$target" =~ $allowed ]]; then
    reaching_out+="$line"$'\n'
  fi
done < <(git grep --untracked -n -o -E '@import\("[^"]+"\)' -- "$folder" || true)
if [[ -n "$reaching_out" ]]; then
  printf 'The workspace trust module may import only std, its own files, repo_root.zig, io.zig, profile_paths.zig, debug_trace.zig and config_runtime.zig:\n%s' "$reaching_out" >&2
  exit 1
fi
