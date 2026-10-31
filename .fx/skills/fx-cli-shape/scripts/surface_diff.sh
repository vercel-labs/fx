#!/usr/bin/env bash
# List the user-facing controls a change adds or removes: env vars, flags,
# top-level commands, slash commands, and settings keys.
#
# Usage:
#   surface_diff.sh                     changes since the merge base with origin/main, including uncommitted work
#   surface_diff.sh --base <rev>        changes since the merge base with <rev>
#   surface_diff.sh --diff-file <path>  read a unified diff from a file
#
# Output lines look like "+ flag --fast-diff  src/builtins/commands.zig".
# A "+" means added, a "-" means removed. Matches come from string literals, so
# test fixtures and sentinels can appear; check each line against the rules.
set -euo pipefail

base="origin/main"
diff_file=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      base="${2:?--base needs a revision}"
      shift 2
      ;;
    --diff-file)
      diff_file="${2:?--diff-file needs a path}"
      shift 2
      ;;
    -h | --help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "surface_diff.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

read_diff() {
  if [ -n "${diff_file}" ]; then
    cat "${diff_file}"
    return
  fi
  local merge_base
  if ! merge_base="$(git merge-base "${base}" HEAD 2>/dev/null)"; then
    echo "surface_diff.sh: cannot find a merge base with ${base}; fetch it or pass --base" >&2
    exit 2
  fi
  git diff --unified=0 "${merge_base}" -- src
}

read_diff | awk '
function emit(sign, kind, name) {
  print sign " " kind " " name "  " file
}
function scan(text, re, kind, skip,    found, name) {
  while (match(text, re)) {
    found = substr(text, RSTART, RLENGTH)
    name = substr(found, skip + 1)
    emit(sign, kind, name)
    text = substr(text, RSTART + RLENGTH)
  }
}
/^--- / { old = $2; sub(/^a\//, "", old); next }
/^\+\+\+ / { file = $2; sub(/^b\//, "", file); if (file == "/dev/null") file = old; next }
/^diff --git / || /^@@/ { next }
/^[+-]/ {
  sign = substr($0, 1, 1)
  line = substr($0, 2)
  scan(line, "\"FX_[A-Z0-9_]+", "env", 1)
  scan(line, "\"--[a-z0-9][a-z0-9-]*", "flag", 1)
  scan(line, "\\.token = \"[a-z][a-z0-9-]*", "command", 10)
  scan(line, "\\.command = \"/[a-z][a-z0-9-]*", "slash", 12)
  if (file ~ /^src\/core\/config\//) {
    scan(line, "\\.get\\(\"[A-Za-z_][A-Za-z0-9_.]*", "setting", 6)
    scan(line, "\\.getPtr\\(\"[A-Za-z_][A-Za-z0-9_.]*", "setting", 9)
    scan(line, "\\.contains\\(\"[A-Za-z_][A-Za-z0-9_.]*", "setting", 11)
  }
}
' | sort -u
