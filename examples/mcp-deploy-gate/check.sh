#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "${1:?Pass the path to the Fieldwork checkout}" && pwd)
commit=$(git -C "$repo" rev-parse --verify --end-of-options "${2:-HEAD}^{commit}")
fx_bin=$(realpath "$(command -v fx)")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
ln -s "$fx_bin" fx

git -C "$repo" ls-tree -r --name-only "$commit" -- supabase/migrations |
  while IFS= read -r path; do
    [[ $path == *.sql ]] || continue
    git -C "$repo" show "$commit:$path"
    printf '\n'
  done > migrations.sql
test -s migrations.sql
# The 0.0.18 MCP bridge reads one line, so omit the trailing newline.
git -C "$repo" show "$commit:supabase/tests/last-seat.rule.json" |
  jq -cj --rawfile sql migrations.sql '{sql: $sql, spec: (. + {format: 1, evidence: .invariant})}' > request.json

command='./fx mcp call mcp_viberaven_race_two_users - < request.json > result.json'
timeout 120s ./fx ask --ask --no-save --json --config max_agent_steps=4 \
  --system 'Run the requested shell command once. Reply Done after it exits. The caller reads the result file.' \
  "Pre-deploy check for Fieldwork at $commit. Run this exact shell command once: $command" > /dev/null

jq -es '
  if length != 1 then error("Expected one MCP result") else .[0] end
  | if has("ordersBroken") then . else .ordersBroken = (
      .brokenOrders | if type == "array" then length else null end
    ) end
  | if .complete == true and .ordersTotal == 20 and .ordersTried == .ordersTotal
       and ((.status == "no_break" and .ordersBroken == 0)
         or (.status == "broken" and (.ordersBroken | type) == "number"
             and .ordersBroken == (.ordersBroken | floor)
             and .ordersBroken > 0 and .ordersBroken <= .ordersTried))
    then {status, ordersTried, ordersTotal, ordersBroken}
    else error("Expected a completed last-seat check")
    end
' result.json
jq -e '.status == "no_break"' result.json > /dev/null
