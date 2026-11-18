# shellcheck shell=bash
# fx isolated sandbox helper.
# Run as: bash -c "$script" fx-iso <command> <folder> <state> [args...]
set -eu
command="$1"
folder="$2"
state="$3"
shift 3
case "$command" in
prepare)
  # Makes the folder, and the extra folders given, writable by this user.
  for dir in "$folder" "$@"; do
    if [ ! -d "$dir" ]; then
      mkdir -p "$dir" 2>/dev/null || sudo mkdir -p "$dir"
    fi
    if [ ! -w "$dir" ]; then
      sudo chown "$(id -u):$(id -g)" "$dir"
    fi
  done
  ;;
baseline)
  # Records every file in the folder, ignored or not, in a repository kept
  # outside the folder, so the folder itself gets no .git.
  mkdir -p "$state"
  export GIT_DIR="$state" GIT_WORK_TREE="$folder"
  git init -q
  git config user.email fx@localhost
  git config user.name fx
  git config core.fsmonitor false
  git config core.excludesFile /dev/null
  cd "$folder"
  git add -A --force
  git commit -q --allow-empty --no-verify -m before
  ;;
outputs)
  # Prints the raw diff of the folder since the baseline, NUL-separated, and
  # packs the added and changed files into the archive given.
  export GIT_DIR="$state" GIT_WORK_TREE="$folder"
  cd "$folder"
  out="$1"
  rm -f "$out"
  git add -A --force
  git diff --cached --raw -z --no-renames --abbrev=40 HEAD
  if [ -n "$(git diff --cached --name-only --diff-filter=AMT HEAD | head -c 1)" ]; then
    git diff --cached --name-only -z --diff-filter=AMT HEAD | tar -czf "$out" --null -T -
  fi
  ;;
*)
  echo "fx-iso: unknown command $command" >&2
  exit 2
  ;;
esac
