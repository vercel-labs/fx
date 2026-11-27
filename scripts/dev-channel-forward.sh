#!/usr/bin/env bash
# Decide whether a dev build may replace the build a dev channel names.
#
# Usage: dev-channel-forward.sh <channel-commit> <build-commit> <main-commit>
#
# <channel-commit> is the commit the channel names now, or "" when it could
# not be read. Run it in a checkout that has main's history.
#
# The channel only moves forward. CI on main often ends after newer commits
# merge, so a build may be behind main and still newer than the channel:
# - The build is already in the history of the channel's commit, and differs
#   from it: the channel stays.
# - The channel's commit is in the build's history, or is the build: the
#   channel moves. A rerun for the same commit writes the channel again.
# - The channel's commit is empty or outside this history: only main's
#   newest commit may replace it.
#
# Writes move=true or move=false to $GITHUB_OUTPUT when it is set, and prints
# why. Dev Release (dev.json) and Publish libfx (the npm dev tag) use it.

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: dev-channel-forward.sh <channel-commit> <build-commit> <main-commit>" >&2
  exit 2
fi

channel_sha=$1
build_sha=$2
main_sha=$3

decide() {
  echo "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "move=$1" >> "$GITHUB_OUTPUT"
  fi
  exit 0
}

channel_known=false
if [ -n "$channel_sha" ] && git cat-file -e "${channel_sha}^{commit}" 2>/dev/null; then
  channel_known=true
fi

if [ "$channel_known" = true ] && [ "$channel_sha" != "$build_sha" ] &&
  git merge-base --is-ancestor "$build_sha" "$channel_sha"; then
  decide false "the channel names ${channel_sha}, which already includes ${build_sha}; leaving it unchanged"
fi
if [ "$channel_known" = true ] && git merge-base --is-ancestor "$channel_sha" "$build_sha"; then
  decide true "the channel names ${channel_sha}; moving it to ${build_sha}"
fi
if [ "$main_sha" = "$build_sha" ]; then
  decide true "the channel names no commit in the history of ${build_sha}, which is main's newest commit; moving it"
fi
if [ -z "$channel_sha" ]; then
  decide false "the channel could not be read, and main advanced to ${main_sha}; leaving it unchanged"
fi
decide false "the channel's commit ${channel_sha} is not in the history of ${build_sha}, and main advanced to ${main_sha}; leaving it unchanged"
