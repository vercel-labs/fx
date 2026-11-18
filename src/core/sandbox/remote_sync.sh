# shellcheck shell=bash
# fx workspace sandbox helper.
# Run as: bash -c "$script" fx-sync <command> <folder> [args...]
set -eu
command="$1"
folder="$2"
shift 2
case "$command" in
prepare)
  # Makes the folder and its repository. Prints "new" or "existing".
  if [ ! -d "$folder" ]; then
    mkdir -p "$folder" 2>/dev/null || sudo mkdir -p "$folder"
  fi
  if [ ! -w "$folder" ]; then
    sudo chown "$(id -u):$(id -g)" "$folder"
  fi
  cd "$folder"
  if [ -d .git ] && git rev-parse -q --verify refs/fx/baseline >/dev/null 2>&1; then
    echo existing
  else
    rm -rf .git
    git init -q
    git config user.email fx@localhost
    git config user.name fx
    git config commit.gpgSign false
    git config core.fsmonitor false
    git config core.quotepath off
    echo new
  fi
  ;;
reset)
  # Removes every file git would track, so a full upload starts clean.
  # Ignored files, such as build output and caches, stay.
  cd "$folder"
  git ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' path; do rm -f -- "$path"; done
  ;;
apply)
  # Deletes the given paths, then records the baseline. Prints the commit
  # and its tree, one per line.
  cd "$folder"
  if [ "$#" -gt 0 ]; then rm -f -- "$@"; fi
  git add -A
  git commit -q --allow-empty --no-verify -m "fx sync"
  git update-ref refs/fx/baseline HEAD
  git rev-parse HEAD 'HEAD^{tree}'
  ;;
changes)
  # Prints the raw diff since the baseline commit, NUL-separated, and packs
  # the added and changed files into the archive named by the second
  # argument. No archive is written when nothing was added or changed.
  cd "$folder"
  base="$1"
  out="$2"
  rm -f "$out"
  git add -A
  git diff --cached --raw -z --no-renames --abbrev=40 "$base"
  if [ -n "$(git diff --cached --name-only --diff-filter=AMT "$base" | head -c 1)" ]; then
    git diff --cached --name-only -z --diff-filter=AMT "$base" | tar -czf "$out" --null -T -
  fi
  ;;
*)
  echo "fx-sync: unknown command $command" >&2
  exit 2
  ;;
esac
