#!/usr/bin/env bash
# src/js/quickjs is the quickjs-ng release that its FORK.md names, plus fx's
# own changes, one patch file each in src/js/quickjs/patches, applied in name
# order. This script keeps the two in step.
#
#   scripts/quickjs-fork.sh check
#       Takes the patches off a copy of the folder, newest first, and checks
#       each file against the SHA-256 FORK.md records for the release. It
#       downloads nothing, so CI runs it.
#   scripts/quickjs-fork.sh save NAME
#       Writes the difference between src/js/quickjs and the release plus
#       the patches as the next patch, patches/NNNN-NAME.patch. Make a
#       change in the folder, then save it.
#   scripts/quickjs-fork.sh update REF
#       Applies the patches to the release tag or commit REF, writes the
#       result into src/js/quickjs, and records REF in FORK.md. It refuses a
#       folder with changes no patch holds. A patch that no longer applies
#       stops the update and keeps its merge to resolve.
#   scripts/quickjs-fork.sh update --continue DIR
#       Finishes that update once the merge in DIR/repo is resolved.
#
# save and update download quickjs-ng by commit and check its files against
# FORK.md. QUICKJS_FORK_UPSTREAM replaces the repository's URL, so
# scripts/quickjs-fork-test.sh can run every command against a local one.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

dir="src/js/quickjs"
patches="$dir/patches"
fork="$dir/FORK.md"
upstream="${QUICKJS_FORK_UPSTREAM:-https://github.com/quickjs-ng/quickjs}"

usage() {
  echo "usage: scripts/quickjs-fork.sh check | save NAME | update REF | update --continue DIR" >&2
  exit 2
}

field() {
  sed -n "s/^| $1 | \`\(.*\)\` |\$/\1/p" "$fork"
}

# The release's files and their SHA-256s, from the table under "## Release
# files" in FORK.md, as "HASH FILE" lines.
recorded() {
  awk '/^## / { on = ($0 == "## Release files") }
       on && /^\| `/ { split($0, cell, "`"); if (length(cell[4]) == 64) print cell[4], cell[2] }' "$fork"
}

release="$(field Release)"
release_commit="$(field Commit)"
if [[ -z "$release" || ! "$release_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "$fork must name the Release and its full Commit" >&2
  exit 2
fi
if [[ -z "$(recorded)" ]]; then
  echo "$fork must list the release's files and their SHA-256s under Release files" >&2
  exit 2
fi

work=""
keep_work=0
cleanup() {
  if [[ -n "$work" && "$keep_work" == 0 ]]; then rm -rf "$work"; fi
}
trap cleanup EXIT

sha256() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# The engine's files: everything in the folder but FORK.md and the patches.
files() {
  find "$dir" -maxdepth 1 -type f ! -name FORK.md -exec basename {} \; | LC_ALL=C sort
}

# The patches in name order, or none before the first save makes the folder.
patch_files() {
  if [[ -d "$patches" ]]; then
    find "$patches" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort
  fi
}

in_repo() {
  git -C "$work/repo" -c user.name=quickjs-fork -c user.email=quickjs-fork@localhost "$@"
}

# fetch NAME COMMIT: downloads quickjs-ng at COMMIT and unpacks it into
# $work/NAME. GitHub keeps a commit's files the same in every archive of it,
# though not the archive's compressed bytes, so callers check the files.
fetch() {
  local url="$upstream/archive/$2.tar.gz"
  if ! curl -fsSL --connect-timeout 30 --max-time 300 --retry 3 -o "$work/$1.tar.gz" "$url"; then
    echo "could not download $url" >&2
    exit 1
  fi
  mkdir "$work/$1"
  tar -xzf "$work/$1.tar.gz" -C "$work/$1" --strip-components 1
}

# copy_files FROM WHAT: copies each engine file from FROM, the unpacked
# release WHAT, into the work repository.
copy_files() {
  local file
  while IFS= read -r file; do
    if [[ ! -f "$1/$file" ]]; then
      echo "$2 has no $file; find what replaced it" >&2
      exit 1
    fi
    cp "$1/$file" "$work/repo/$file"
  done < <(files)
}

# folder_matches: takes the patches off a copy of the folder, newest first,
# and checks the result against the release's recorded files. git apply takes
# a patch off only where its lines are unchanged, so a change in a patch's
# lines stops it, and a change elsewhere shows as a file that differs.
folder_matches() {
  local status=0 hash file patch
  mkdir "$work/back"
  git init -q "$work/back"
  recorded | cut -d' ' -f2 > "$work/names"
  while IFS= read -r file; do
    if ! grep -qxF -- "$file" "$work/names"; then
      echo "$dir/$file is not one of $release's files in $fork" >&2
      status=1
    fi
    cp "$dir/$file" "$work/back/$file"
  done < <(files)
  while IFS= read -r patch; do
    if ! git -C "$work/back" apply -R "$repo_root/$patch"; then
      echo "$patch no longer comes off $dir: its lines changed without a new patch" >&2
      return 1
    fi
  done < <(patch_files | LC_ALL=C sort -r)
  while read -r hash file; do
    if [[ ! -f "$work/back/$file" ]]; then
      echo "$dir has no $file, which $release has" >&2
      status=1
    elif [[ "$(sha256 "$work/back/$file")" != "$hash" ]]; then
      echo "$dir/$file differs from $release plus the patches in $patches" >&2
      status=1
    fi
  done < <(recorded)
  return "$status"
}

# start_repo: downloads the release FORK.md names, checks its files, and
# commits its copy of each engine file in a work repository, so a three-way
# apply can find the files each patch was made against.
start_repo() {
  local status=0 hash file
  fetch release "$release_commit"
  while read -r hash file; do
    if [[ ! -f "$work/release/$file" || "$(sha256 "$work/release/$file")" != "$hash" ]]; then
      echo "$file at $release_commit does not match the SHA-256 in $fork" >&2
      status=1
    fi
  done < <(recorded)
  if [[ "$status" != 0 ]]; then exit 1; fi
  git init -q "$work/repo"
  copy_files "$work/release" "$release"
  in_repo add -A
  in_repo commit -q -m "$release"
}

# Applies every patch in name order.
apply_patches() {
  local patch
  while IFS= read -r patch; do
    if ! in_repo apply "$repo_root/$patch"; then
      echo "$patch does not apply to $release" >&2
      exit 1
    fi
  done < <(patch_files)
}

# resolve REF: prints REF's commit, peeling an annotated tag to its commit.
resolve() {
  if [[ "$1" =~ ^[0-9a-f]{40}$ ]]; then
    echo "$1"
    return
  fi
  git ls-remote "$upstream" "refs/tags/$1" "refs/tags/$1^{}" |
    awk '$2 ~ /\^\{\}$/ { peeled = $1 } $2 !~ /\^\{\}$/ { plain = $1 }
         END { print (peeled != "" ? peeled : plain) }'
}

# record_patch PATCH: keeps the staged change as PATCH's version for the new
# release, or drops PATCH when the release already has its change, and moves
# on to the next pending patch.
record_patch() {
  local name ref
  name="$(basename "$1")"
  ref="$(sed -n 1p "$work/target")"
  in_repo diff --cached --no-color > "$work/patches/$name"
  if [[ -s "$work/patches/$name" ]]; then
    in_repo commit -q -m "$name"
  else
    echo "$ref already has the change in $1; removing it, so remove its entry in $fork too"
    rm "$work/patches/$name"
  fi
  tail -n +2 "$work/pending" > "$work/pending.next"
  mv "$work/pending.next" "$work/pending"
}

# Applies each pending patch to the new release with a three-way merge, and
# records it again against that release, so the next update finds the files
# each one starts from. A conflict keeps the work folder and stops.
apply_pending() {
  local patch
  while [[ -s "$work/pending" ]]; do
    patch="$(head -1 "$work/pending")"
    if ! in_repo apply --3way "$repo_root/$patch"; then
      keep_work=1
      echo "$patch does not apply to $(sed -n 1p "$work/target"). Resolve the conflicts in $work/repo, then run:" >&2
      echo "  scripts/quickjs-fork.sh update --continue $work" >&2
      exit 1
    fi
    record_patch "$patch"
  done
}

# Writes the new release's files, the patches recorded against it, and its
# name, commit, and file hashes in FORK.md. A stop part way leaves a folder
# that check rejects; git checkout restores it, and the update runs again.
finish() {
  local ref ref_commit file patch name
  ref="$(sed -n 1p "$work/target")"
  ref_commit="$(sed -n 2p "$work/target")"
  while IFS= read -r file; do
    cp "$work/repo/$file" "$dir/$file"
  done < <(files)
  patch_files > "$work/old-patches"
  while IFS= read -r patch; do
    name="$(basename "$patch")"
    if [[ -f "$work/patches/$name" ]]; then
      cp "$work/patches/$name" "$patch"
    else
      rm "$patch"
    fi
  done < "$work/old-patches"
  awk -v ref="$ref" -v commit="$ref_commit" -v rows="$work/next.sha256" '
    /^## / { on = ($0 == "## Release files") }
    /^\| Release \| `.*` \|$/ { $0 = "| Release | `" ref "` |" }
    /^\| Commit \| `.*` \|$/ { $0 = "| Commit | `" commit "` |" }
    on && /^\| `/ { next }
    { print }
    on && $0 == "| --- | --- |" {
      while ((getline line < rows) > 0) { split(line, f, " "); print "| `" f[2] "` | `" f[1] "` |" }
    }' "$fork" > "$work/FORK.md"
  cp "$work/FORK.md" "$fork"
  keep_work=0
  echo "$dir is now $ref plus the patches, and $fork records it."
  echo "Run zig build test-js and the code-mode tests next."
}

update_start() {
  local ref="$1" ref_commit patch file
  if [[ ! "$ref" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "usage: scripts/quickjs-fork.sh update REF, with REF a release tag or a full commit" >&2
    exit 2
  fi
  ref_commit="$(resolve "$ref")"
  if [[ -z "$ref_commit" ]]; then
    echo "quickjs-ng has no tag $ref" >&2
    exit 1
  fi
  work="$(mktemp -d)"
  if ! folder_matches; then
    echo "Save a change you made with scripts/quickjs-fork.sh save NAME, or, if an update stopped while writing $dir, restore it with git checkout -- $dir. Then run the update again." >&2
    exit 1
  fi
  start_repo
  # Store each patch's starting point, so a three-way merge can find it.
  while IFS= read -r patch; do
    in_repo apply "$repo_root/$patch"
    in_repo add -A
  done < <(patch_files)
  fetch next "$ref_commit"
  copy_files "$work/next" "$ref"
  in_repo add -A
  in_repo commit -q --allow-empty -m "$ref"
  while IFS= read -r file; do
    echo "$(sha256 "$work/next/$file") $file"
  done < <(files) > "$work/next.sha256"
  printf '%s\n%s\n' "$ref" "$ref_commit" > "$work/target"
  patch_files > "$work/pending"
  mkdir "$work/patches"
  apply_pending
  finish
}

update_continue() {
  local patch file
  if [[ ! -f "$1/target" || ! -f "$1/pending" || ! -d "$1/repo" ]]; then
    echo "$1 is not an update stopped at a conflict" >&2
    exit 2
  fi
  work="$1"
  keep_work=1
  patch="$(head -1 "$work/pending")"
  if [[ -n "$patch" && "$(in_repo log -1 --format=%s)" == "$(basename "$patch")" ]]; then
    # An earlier continue recorded this patch and stopped before moving on.
    tail -n +2 "$work/pending" > "$work/pending.next"
    mv "$work/pending.next" "$work/pending"
  else
    while IFS= read -r file; do
      if grep -qE '^(<<<<<<<|>>>>>>>)( |$)' "$work/repo/$file"; then
        echo "$work/repo/$file still has conflict markers; resolve them, then run update --continue again" >&2
        exit 1
      fi
    done < <(files)
    in_repo add -A
    record_patch "$patch"
  fi
  apply_pending
  finish
}

case "${1:-}" in
  check)
    work="$(mktemp -d)"
    if ! folder_matches; then
      echo "Save each change to the folder with scripts/quickjs-fork.sh save NAME, or, if an update stopped while writing it, restore it with git checkout -- $dir." >&2
      exit 1
    fi
    echo "$dir is $release plus $(patch_files | wc -l | tr -d ' ') patches"
    ;;

  save)
    name="${2:-}"
    if [[ ! "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
      echo "usage: scripts/quickjs-fork.sh save NAME, with NAME in lowercase words joined by hyphens" >&2
      exit 2
    fi
    work="$(mktemp -d)"
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
    if [[ "${2:-}" == "--continue" ]]; then
      if [[ -z "${3:-}" ]]; then usage; fi
      update_continue "$3"
    elif [[ -n "${2:-}" ]]; then
      update_start "$2"
    else
      usage
    fi
    ;;

  *)
    usage
    ;;
esac
