#!/usr/bin/env bash
# di improves itself: one autonomous `di ask` turn against this repository,
# then build + tests gate the change before it is committed and pushed.
#
#   scripts/self-improve.sh                       # one iteration, default task
#   scripts/self-improve.sh -n 5                  # five iterations
#   scripts/self-improve.sh -m muse-spark-1.3     # pick the model (OpenPaths id)
#   scripts/self-improve.sh --no-push             # commit locally only
#   scripts/self-improve.sh -- "fix /model so every credential's catalog is merged"
#   scripts/self-improve.sh --merge-upstream  # merge vercel-labs/fx main, di resolves conflicts
#
# Requires OPENPATHS_API_KEY (or OPENROUTER_API_KEY). Every iteration starts
# from a clean tree; a failing build or test suite reverts the iteration.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIG=${ZIG:-zig}
ZIG_BUILD_ARGS=${ZIG_BUILD_ARGS:--Dtarget=x86_64-linux-gnu}
DI=${DI:-zig-out/bin/di}
model=${DI_SELF_IMPROVE_MODEL:-muse-spark-1.3-contributor}
iterations=1
push=1
remote=${DI_SELF_IMPROVE_REMOTE:-fork}
valgrind=0
merge_upstream=0
upstream=${DI_UPSTREAM_REMOTE:-origin}
task=""
while [ $# -gt 0 ]; do
  case "$1" in
    -n) iterations=$2; shift 2 ;;
    -m) model=$2; shift 2 ;;
    --no-push) push=0; shift ;;
    --remote) remote=$2; shift 2 ;;
    --valgrind) valgrind=1; shift ;;
    --merge-upstream) merge_upstream=1; shift ;;
    --upstream) upstream=$2; shift 2 ;;
    --) shift; task=$*; break ;;
    *) task=$*; break ;;
  esac
done

[ -n "${OPENPATHS_API_KEY:-}${OPENROUTER_API_KEY:-}" ] || {
  echo "self-improve: set OPENPATHS_API_KEY or OPENROUTER_API_KEY" >&2; exit 2; }

# Resolve the model against the live OpenPaths catalog so a not-yet-deployed
# alias (for example muse-spark-1.3-contributor) degrades to its base id.
resolve_model() {
  local want=$1 base=${OPENPATHS_BASE_URL:-https://openpaths.io} key=${OPENPATHS_API_KEY:-$OPENROUTER_API_KEY}
  local ids
  ids=$(curl -sf -m 20 "$base/v1/models" -H "Authorization: Bearer $key" 2>/dev/null | tr ',' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p') || { echo "$want"; return; }
  if grep -qx -- "$want" <<<"$ids"; then echo "$want"; return; fi
  local stripped=${want%-contributor}
  if [ "$stripped" != "$want" ] && grep -qx -- "$stripped" <<<"$ids"; then
    echo "self-improve: $want not in catalog yet; using $stripped" >&2; echo "$stripped"; return
  fi
  echo "$want"
}
model=$(resolve_model "$model")

if [ -n "$(git status --porcelain)" ]; then
  echo "self-improve: working tree must be clean" >&2; exit 2
fi

branch=$(git rev-parse --abbrev-ref HEAD)
default_task='You are di, a Zig coding agent, improving your own source tree.
Pick ONE small, concrete UI/UX defect a terminal user would notice (for example:
/model not listing every model the configured credentials can reach, a
provider switch that needs a subscription it should not need, an unclear error
line, a stale "fx" name in user-visible text). Fix it with a minimal diff, add
or update a unit test next to the code, and finish with a one-line summary
starting with "Summary:" describing the user-visible change. Do not touch
docs, CI, or unrelated files. Do not run git.'

"$ZIG" build -Doptimize=ReleaseSafe $ZIG_BUILD_ARGS

revert() { git checkout -q -- . && git clean -fdq; }

# Test gate: a change passes when it introduces no new failing test relative to
# the baseline captured from the clean tree, so pre-existing environment
# failures do not block progress. DI_SELF_IMPROVE_SKIP_TESTS=1 disables it.
failing_tests() {
  "$ZIG" build test $ZIG_BUILD_ARGS 2>&1 | sed -nE "s/^error: '([^']+)' (failed|crashed|terminated).*/\1/p" | sort -u
}
baseline_file=$(mktemp)
if [ "${DI_SELF_IMPROVE_SKIP_TESTS:-0}" != 1 ]; then
  echo "== capturing baseline test failures"
  failing_tests > "$baseline_file"
  echo "baseline failing tests: $(wc -l < "$baseline_file")"
fi
tests_pass() {
  [ "${DI_SELF_IMPROVE_SKIP_TESTS:-0}" = 1 ] && return 0
  local now; now=$(mktemp); failing_tests > "$now"
  local new; new=$(comm -13 "$baseline_file" "$now")
  rm -f "$now"
  [ -z "$new" ] || { echo "new failing tests:" >&2; echo "$new" >&2; return 1; }
}

if [ "$merge_upstream" = 1 ]; then
  echo "== merge upstream $upstream/main"
  git fetch -q "$upstream" main
  if git merge --no-edit "$upstream/main"; then
    echo "merged cleanly"
  else
    conflicts=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
    echo "conflicts: $conflicts"
    merge_task="You are di, merging upstream vercel-labs/fx into the lee101/di fork.
These files have git conflict markers: $conflicts
Resolve every conflict so the file compiles and keeps BOTH the upstream change
and di's fork behavior (product name di, OpenPaths default provider, unified
/model catalog, model fallback). Remove all conflict markers. Do not run git.
Finish with a one-line 'Summary:' of what you reconciled."
    if ! FX_MODEL="$model" "$DI" ask --yolo --no-save \
        --timeout "${DI_SELF_IMPROVE_TIMEOUT:-1800000}" -- "$merge_task"; then
      echo "self-improve: conflict resolution failed; aborting merge" >&2
      git merge --abort; exit 1
    fi
    if git grep -q '^<<<<<<< ' -- . ; then
      echo "self-improve: conflict markers remain; aborting merge" >&2
      git merge --abort; exit 1
    fi
    git add -A
  fi
  if ! "$ZIG" build -Doptimize=ReleaseSafe $ZIG_BUILD_ARGS || ! tests_pass; then
    echo "self-improve: merged tree fails build/test; aborting merge" >&2
    git merge --abort 2>/dev/null || git reset -q --hard ORIG_HEAD; exit 1
  fi
  if ! git diff --cached --quiet || [ -f .git/MERGE_HEAD ]; then
    git commit -q --no-edit -m "Merge $upstream/main into di" \
      -m "Conflicts resolved by di with $model." -m "Co-Authored-By: di <noreply@openpaths.io>"
  fi
  echo "merged $upstream/main"
  if [ "$push" = 1 ]; then git push -q "$remote" "$branch"; echo "pushed to $remote/$branch"; fi
  [ -n "$task" ] || [ "$iterations" -gt 1 ] || exit 0
fi

for i in $(seq 1 "$iterations"); do
  echo "== self-improve iteration $i/$iterations model=$model"
  prompt=${task:-$default_task}
  log=$(mktemp)
  if ! FX_MODEL="$model" "$DI" ask --yolo --no-save --auto-next-steps \
      --timeout "${DI_SELF_IMPROVE_TIMEOUT:-1800000}" -- "$prompt" | tee "$log"; then
    echo "self-improve: ask failed; reverting" >&2
    revert
    continue
  fi
  if [ -z "$(git status --porcelain)" ]; then
    echo "self-improve: no changes produced"
    continue
  fi
  if ! "$ZIG" build -Doptimize=ReleaseSafe $ZIG_BUILD_ARGS || ! tests_pass; then
    echo "self-improve: build/test failed; reverting" >&2
    revert
    continue
  fi
  if [ "$valgrind" = 1 ] && ! scripts/valgrind.sh; then
    echo "self-improve: valgrind failed; reverting" >&2
    revert
    continue
  fi
  summary=$(grep -m1 -oE '^Summary: .*' "$log" | sed 's/^Summary: //')
  [ -n "$summary" ] || summary="Self-improvement pass $i"
  git add -A
  git commit -q -m "$summary" -m "Generated by scripts/self-improve.sh with $model." \
    -m "Co-Authored-By: di <noreply@openpaths.io>"
  echo "committed: $summary"
  if [ "$push" = 1 ]; then git push -q "$remote" "$branch"; echo "pushed to $remote/$branch"; fi
  rm -f "$log"
done
