#!/usr/bin/env bash
# fx's tool bridge module in src/core/tool_bridge owns the session's per-call
# Unix socket bridge and its handler capability interface. Code outside imports
# only its front door, tool_bridge.zig. The module imports only std, builtin,
# its own files, shared basics (types.zig, io.zig, debug_trace.zig,
# text_utils.zig), and command_runner.zig. Only bridge.zig may import
# mcp_call_client.zig, because its tests drive the real `fx mcp call` client.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

folder="src/core/tool_bridge"

reaching_in="$({
  git grep --untracked -n -E '@import\("[^"]*tool_bridge/[a-z_]+\.zig"\)' -- src ":(exclude)$folder" || true
} | grep -v 'tool_bridge/tool_bridge\.zig")' || true)"
if [[ -n "$reaching_in" ]]; then
  printf 'Only %s/tool_bridge.zig may be imported from outside the tool bridge module:\n%s\n' "$folder" "$reaching_in" >&2
  exit 1
fi

allowed='^(std|builtin|[a-z_]+\.zig|\.\./shared/(types|io|debug_trace|text_utils)\.zig|\.\./execution/command_runner\.zig)$'
client_import='../mcp_host/mcp_call_client.zig'
reaching_out=""
while IFS= read -r line; do
  target="${line#*@import(\"}"
  target="${target%\")}"
  if [[ "$target" == "$client_import" && "${line%%:*}" == "$folder/bridge.zig" ]]; then
    continue
  fi
  if [[ ! "$target" =~ $allowed ]]; then
    reaching_out+="$line"$'\n'
  fi
done < <(git grep --untracked -n -o -E '@import\("[^"]+"\)' -- "$folder" || true)
if [[ -n "$reaching_out" ]]; then
  printf 'The tool bridge module may import only std, builtin, its own files, shared basics (types, io, debug_trace, text_utils), and command_runner.zig; only bridge.zig may import mcp_call_client.zig:\n%s' "$reaching_out" >&2
  exit 1
fi
