#!/bin/sh
# Plants one code bug of tests/tla/agents_menu/mutations.json in a copy of this
# checkout, builds the copy, and runs row-order.ts on it.
#
# Usage: row-order-mutant.sh <bug|late>
#   bug   fx before the fix: a subagent whose turn ended but is not applied
#         shows idle, and hidden agents are visited late, so the gap is wide
#         enough to draw. row-order.ts must fail (exit 1).
#   late  the fix with the same late visits. row-order.ts must pass: the row
#         stays working until its turn is applied, however long that takes.
set -eu
mode="${1:-}"
case "$mode" in bug | late) ;; *)
    echo "usage: row-order-mutant.sh <bug|late>" >&2
    exit 2
    ;;
esac
root="$(cd "$(dirname "$0")/../../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/fx-row-order-mutant.XXXXXX")"
tar -C "$root" --exclude=.git --exclude=.zig-cache --exclude=zig-out --exclude=node_modules -cf - . | tar -C "$work" -xf -
python3 - "$work" "$mode" <<'PY'
import json, sys
work, mode = sys.argv[1], sys.argv[2]
plan = json.load(open(f"{work}/tests/tla/agents_menu/mutations.json"))["code"]
for edit in plan["edits"]:
    if mode == "late" and not edit.get("late"):
        continue
    path = f"{work}/{edit['file']}"
    text = open(path).read()
    if text.count(edit["find"]) != 1:
        sys.exit(f"{edit['file']}: the find string must occur exactly once")
    open(path, "w").write(text.replace(edit["find"], edit["replace"]))
PY
(cd "$work" && zig build -Doptimize=ReleaseSafe)
FX_WORKTREE="$work" bun "$work/tests/tla/drivers/agents_menu/row-order.ts" --runs "${RUNS:-3}"
