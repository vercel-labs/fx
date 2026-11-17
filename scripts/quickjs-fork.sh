#!/usr/bin/env bash
# src/js/quickjs is the quickjs-ng release that its FORK.md names, plus fx's
# own changes, one patch file each in src/js/quickjs/patches, applied in name
# order. This script keeps the two in step.
#
#   scripts/quickjs-fork.sh check
#       Downloads the release archive, checks its SHA-256, applies the
#       patches, and compares the result with src/js/quickjs byte for byte.
#   scripts/quickjs-fork.sh save NAME
#       Writes the difference between src/js/quickjs and the release plus
#       the patches as the next patch, patches/NNNN-NAME.patch. Make a
#       change in the folder, then save it.
#   scripts/quickjs-fork.sh update REF
#       Applies the patches to the release tag or commit REF, writes the
#       result into src/js/quickjs, and records REF in FORK.md. A patch that
#       no longer applies stops the update and names the files to resolve.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

dir="src/js/quickjs"
patches="$dir/patches"
fork="$dir/FORK.md"
upstream="https://github.com/quickjs-ng/quickjs"

field() {
  sed -n "s/^| $1 | \`\(.*\)\` |\$/\1/p" "$fork"
}

release="$(field Release)"
archive="$(field Archive)"
archive_sha="$(field 'Archive SHA-256')"
if [[ -z "$release" || -z "$archive" || -z "$archive_sha" ]]; then
  echo "$fork must name the Release, Archive, and Archive SHA-256" >&2
  exit 2
fi

work="$(mktemp -d)"
keep_work=0
cleanup() {
  if [[ "$keep_work" == 0 ]]; then rm -rf "$work"; fi
}
trap cleanup EXIT

sha256() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# fetch NAME URL: downloads and unpacks an archive into $work/NAME.
fetch() {
  if ! curl -fsSL --connect-timeout 30 --retry 3 -o "$work/$1.tar.gz" "$2"; then
    echo "could not download $2" >&2
    exit 1
  fi
  mkdir "$work/$1"
  tar -xzf "$work/$1.tar.gz" -C "$work/$1" --strip-components 1
}

# The engine's files: everything in the folder but FORK.md and the patches.
files() {
  find "$dir" -maxdepth 1 -type f ! -name FORK.md -exec basename {} \; | LC_ALL=C sort
}

in_repo() {
  git -C "$work/repo" -c user.name=quickjs-fork -c user.email=quickjs-fork@localhost "$@"
}

patch_files() {
  find "$patches" -maxdepth 1 -type f -name '*.patch' 2>/dev/null | LC_ALL=C sort
}

# A repository holding the release's copy of each engine file, committed, so a
# three-way apply can find the files each patch was made against.
start_repo() {
  fetch release "$archive"
  local actual
  actual="$(sha256 "$work/release.tar.gz")"
  if [[ "$actual" != "$archive_sha" ]]; then
    echo "$archive has SHA-256 $actual; $fork records $archive_sha" >&2
    exit 1
  fi
  git init -q "$work/repo"
  local file
  while IFS= read -r file; do
    if [[ ! -f "$work/release/$file" ]]; then
      echo "$release has no $file" >&2
      exit 1
    fi
    cp "$work/release/$file" "$work/repo/$file"
  done < <(files)
  in_repo add -A
  in_repo commit -q -m "$release"
}

# Applies every patch in name order.
apply_patches() {
  local patch
  while IFS= read -r patch; do
    if ! in_repo apply "$repo_root/$patch"; then
      echo "$patch does not apply" >&2
      return 1
    fi
  done < <(patch_files)
}

case "${1:-}" in
  check)
    start_repo
    apply_patches
    status=0
    while IFS= read -r file; do
      if ! cmp -s "$work/repo/$file" "$dir/$file"; then
        echo "$dir/$file differs from $release plus the patches in $patches" >&2
        status=1
      fi
    done < <(files)
    if [[ "$status" == 0 ]]; then
      echo "$dir is $release plus $(patch_files | wc -l | tr -d ' ') patches"
    else
      echo "Save each change to the folder with: scripts/quickjs-fork.sh save NAME" >&2
    fi
    exit "$status"
    ;;

  save)
    name="${2:-}"
    if [[ ! "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
      echo "usage: scripts/quickjs-fork.sh save NAME, with NAME in lowercase words joined by hyphens" >&2
      exit 2
    fi
    start_repo
    apply_patches
    in_repo add -A
    in_repo commit -q --allow-empty -m "patches"
    while IFS= read -r file; do
      cp "$dir/$file" "$work/repo/$file"
    done < <(files)
    if in_repo diff --quiet; then
      echo "$dir has no change beyond $release plus the patches" >&2
      exit 1
    fi
    last="$(patch_files | tail -1)"
    number=1
    if [[ -n "$last" ]]; then
      last_name="$(basename "$last")"
      number=$((10#${last_name%%-*} + 1))
    fi
    mkdir -p "$patches"
    out="$(printf '%s/%04d-%s.patch' "$patches" "$number" "$name")"
    in_repo diff --no-color > "$out"
    echo "wrote $out; describe the change under Changes from upstream in $fork"
    ;;

  update)
    ref="${2:-}"
    if [[ -z "$ref" ]]; then
      echo "usage: scripts/quickjs-fork.sh update REF, with REF a release tag or commit" >&2
      exit 2
    fi
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
      next_archive="$upstream/archive/$ref.tar.gz"
      commit="$ref"
    else
      next_archive="$upstream/archive/refs/tags/$ref.tar.gz"
      commit="$(git ls-remote "$upstream" "refs/tags/$ref^{}" "refs/tags/$ref" | head -1 | cut -f1)"
      if [[ -z "$commit" ]]; then
        echo "quickjs-ng has no tag $ref" >&2
        exit 1
      fi
    fi
    start_repo
    # Store each patch's starting point, so a three-way merge can find it.
    while IFS= read -r patch; do
      if ! in_repo apply "$repo_root/$patch"; then
        echo "$patch does not apply to $release; run check first" >&2
        exit 1
      fi
      in_repo add -A
    done < <(patch_files)
    fetch next "$next_archive"
    while IFS= read -r file; do
      if [[ ! -f "$work/next/$file" ]]; then
        echo "$ref has no $file; find what replaced it before updating" >&2
        exit 1
      fi
      cp "$work/next/$file" "$work/repo/$file"
    done < <(files)
    in_repo add -A
    in_repo commit -q --allow-empty -m "$ref"
    # Apply each patch and record it again against REF, so the next update
    # finds the files each one starts from.
    mkdir "$work/patches"
    while IFS= read -r patch; do
      name="$(basename "$patch")"
      if ! in_repo apply --3way "$repo_root/$patch"; then
        keep_work=1
        echo "$patch does not apply to $ref. Resolve the conflicts in $work/repo," >&2
        echo "then copy its files into $dir and save the change again." >&2
        exit 1
      fi
      in_repo diff --cached --no-color > "$work/patches/$name"
      if [[ ! -s "$work/patches/$name" ]]; then
        echo "$ref already has the change in $patch; removing it, so remove its entry in $fork too"
        rm "$work/patches/$name"
        continue
      fi
      in_repo commit -q -m "$name"
    done < <(patch_files)
    while IFS= read -r file; do
      cp "$work/repo/$file" "$dir/$file"
    done < <(files)
    while IFS= read -r patch; do
      name="$(basename "$patch")"
      if [[ -f "$work/patches/$name" ]]; then
        cp "$work/patches/$name" "$patch"
      else
        rm "$patch"
      fi
    done < <(patch_files)
    next_sha="$(sha256 "$work/next.tar.gz")"
    sed -i.bak \
      -e "s#^| Release | \`.*\` |\$#| Release | \`$ref\` |#" \
      -e "s#^| Commit | \`.*\` |\$#| Commit | \`$commit\` |#" \
      -e "s#^| Archive | \`.*\` |\$#| Archive | \`$next_archive\` |#" \
      -e "s#^| Archive SHA-256 | \`.*\` |\$#| Archive SHA-256 | \`$next_sha\` |#" \
      "$fork"
    rm -f "$fork.bak"
    echo "$dir is now $ref plus the patches, and $fork records it."
    echo "Run zig build test-js and the code-mode tests next."
    ;;

  *)
    echo "usage: scripts/quickjs-fork.sh check | save NAME | update REF" >&2
    exit 2
    ;;
esac
