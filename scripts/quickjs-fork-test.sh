#!/usr/bin/env bash
# Tests scripts/quickjs-fork.sh with no network. A local git repository stands
# in for quickjs-ng with four tagged releases of a three-line engine, and
# QUICKJS_FORK_UPSTREAM points the script at it, so tags resolve through git
# ls-remote and archives download as file:// URLs. Each case runs in a fresh
# copy of a small repository laid out like fx's: the script, and an engine
# folder at the first release plus one patch.

set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/quickjs-fork.sh"
root="$(mktemp -d)"
kept=""
trap 'rm -rf "$root" ${kept:+"$kept"}' EXIT

g() {
  git -c user.name=test -c user.email=test@localhost -c init.defaultBranch=main "$@"
}

# engine A B C: an engine file whose three settings sit far enough apart that
# a change to one is not next to a change to another, as in real code.
engine() {
  printf 'int a = %s;\n' "$1"
  printf '/* %s */\n' one two three four
  printf 'int b = %s;\n' "$2"
  printf '/* %s */\n' five six seven eight
  printf 'int c = %s;\n' "$3"
}

# The stand-in for quickjs-ng. fx's first patch changes line a to 10.
#   v1  a = 1    b = 2  c = 3    the release fx starts from
#   v2  a = 1    b = 2  c = 30   an annotated tag; a change beside fx's
#   v3  a = 100  b = 2  c = 30   a change to fx's line, so its patch conflicts
#   v4  a = 10   b = 2  c = 30   fx's change itself
up="$root/upstream"
mkdir -p "$up/archive"
g init -q "$up"
release() {
  local tag="$1" a="$2" c="$3" kind="${4:-light}" sha
  engine "$a" 2 "$c" > "$up/engine.c"
  printf 'MIT License\n' > "$up/LICENSE"
  g -C "$up" add engine.c LICENSE
  g -C "$up" commit -q -m "$tag"
  if [[ "$kind" == annotated ]]; then
    g -C "$up" tag -a -m "$tag" "$tag"
  else
    g -C "$up" tag "$tag"
  fi
  sha="$(g -C "$up" rev-parse HEAD)"
  g -C "$up" archive --format=tar.gz --prefix="quickjs-$sha/" -o "$up/archive/$sha.tar.gz" HEAD
}
release v1 1 3
release v2 1 30 annotated
release v3 100 30
release v4 10 30
v1_sha="$(g -C "$up" rev-parse 'v1^{commit}')"
v2_sha="$(g -C "$up" rev-parse 'v2^{commit}')"
export QUICKJS_FORK_UPSTREAM="file://$up"

sha256() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# The fixture: v1's files, a FORK.md that records them, and fx's first patch.
fixture="$root/fixture"
engine="$fixture/src/js/quickjs"
mkdir -p "$fixture/scripts" "$engine"
g init -q "$fixture"
cp "$script" "$fixture/scripts/quickjs-fork.sh"
g -C "$up" show "$v1_sha:engine.c" > "$engine/engine.c"
g -C "$up" show "$v1_sha:LICENSE" > "$engine/LICENSE"
cat > "$engine/FORK.md" <<EOF
# quickjs-ng in fx

| Field | Value |
| --- | --- |
| Release | \`v1\` |
| Commit | \`$v1_sha\` |

## Release files

| File | SHA-256 |
| --- | --- |
| \`LICENSE\` | \`$(sha256 "$engine/LICENSE")\` |
| \`engine.c\` | \`$(sha256 "$engine/engine.c")\` |

## Changes from upstream
EOF
sed -i.bak 's/^int a = 1;$/int a = 10;/' "$engine/engine.c"
rm "$engine/engine.c.bak"
(cd "$fixture" && scripts/quickjs-fork.sh save first-change >/dev/null)
g -C "$fixture" add -A
g -C "$fixture" commit -q -m fixture

fork=scripts/quickjs-fork.sh
src=src/js/quickjs
failures=0
out=""

# fresh: starts a case in a new copy of the fixture.
fresh() {
  cd "$root"
  rm -rf case
  cp -R "$fixture" case
  cd case
}

# expect DESC STATUS TEXT COMMAND...: runs COMMAND, and passes when it exits
# with STATUS and its output holds TEXT.
expect() {
  local desc="$1" want="$2" text="$3" status
  shift 3
  if out="$("$@" 2>&1)"; then status=0; else status=$?; fi
  if [[ "$status" == "$want" && "$out" == *"$text"* ]]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc: exit $status, wanted $want and \"$text\" in:"
    printf '%s\n' "$out" | sed 's/^/    /'
    failures=$((failures + 1))
  fi
}

# holds DESC COMMAND...: passes when COMMAND succeeds.
holds() {
  local desc="$1"
  shift
  if "$@"; then
    echo "ok - $desc"
  else
    echo "not ok - $desc"
    failures=$((failures + 1))
  fi
}

edit() {
  sed -i.bak "$1" "$src/$2"
  rm "$src/$2.bak"
}

fresh
expect "check passes on the release plus its patch" 0 "$src is v1 plus 1 patches" $fork check
expect "check downloads nothing" 0 "$src is v1 plus 1 patches" env QUICKJS_FORK_UPSTREAM=file:///nonexistent $fork check

fresh
echo 'int d = 4;' >> "$src/engine.c"
expect "check fails on an edit beside the patch's lines" 1 "$src/engine.c differs from v1 plus the patches" $fork check
holds "check says to save the change or restore the folder" grep -q "save NAME, or, if an update stopped" <<< "$out"

fresh
edit 's/^int a = 10;$/int a = 11;/' engine.c
expect "check fails on an edit to the patch's lines" 1 "0001-first-change.patch no longer comes off" $fork check

fresh
edit "s/| \`engine.c\` | \`[0-9a-f]*\` |/| \`engine.c\` | \`$(printf '%064d' 0)\` |/" FORK.md
expect "check fails when FORK.md records other contents" 1 "$src/engine.c differs from v1" $fork check
expect "save refuses a download that does not match FORK.md" 1 "engine.c at $v1_sha does not match the SHA-256" $fork save next

fresh
touch "$src/extra.h"
expect "check fails on a file the release does not have" 1 "$src/extra.h is not one of v1's files" $fork check
expect "save refuses a file the release does not have and says where it goes" 1 "keep a file of fx's own outside $src" $fork save extra-header
holds "save wrote no patch for it" test ! -e "$src/patches/0002-extra-header.patch"
expect "update refuses a file the release does not have" 1 "keep a file of fx's own outside $src" $fork update v2

fresh
edit "s/^| Commit | \`.*\` |\$/| Commit | \`$(printf '%040d' 0)\` |/" FORK.md
expect "save names a download that fails" 1 "could not download file://$up/archive/$(printf '%040d' 0).tar.gz" $fork save next

fresh
edit 's/^int c = 3;$/int c = 33;/' engine.c
expect "save writes the next patch" 0 "wrote $src/patches/0002-second-change.patch" $fork save second-change
expect "check passes with the saved patch" 0 "$src is v1 plus 2 patches" $fork check

fresh
expect "save refuses a name that is not lowercase words" 2 "usage" $fork save "Second Change"
expect "save refuses a folder with nothing to save" 1 "$src has no change beyond v1" $fork save nothing

fresh
expect "update applies the patch to an annotated tag" 0 "$src is now v2 plus the patches" $fork update v2
holds "update records the tag's commit, not the tag object" grep -qF "| Commit | \`$v2_sha\` |" "$src/FORK.md"
holds "update keeps fx's change on the new release" grep -qx 'int a = 10;' "$src/engine.c"
holds "update takes the new release's change" grep -qx 'int c = 30;' "$src/engine.c"
expect "check passes on the updated folder" 0 "$src is v2 plus 1 patches" $fork check

fresh
echo 'int d = 4;' >> "$src/engine.c"
expect "update refuses a folder with an unsaved change" 1 "Save a change you made with scripts/quickjs-fork.sh save NAME" $fork update v2
holds "update leaves that folder as it was" grep -qx 'int d = 4;' "$src/engine.c"
holds "update leaves FORK.md on the old release" grep -qF "| Release | \`v1\` |" "$src/FORK.md"

fresh
g -C "$up" show "$v2_sha:engine.c" > "$src/engine.c"
expect "update after one that stopped while writing says how to restore" 1 "restore it with git checkout -- $src" $fork update v2
git checkout -q -- "$src"
expect "update runs again once the folder is restored" 0 "$src is now v2 plus the patches" $fork update v2

fresh
edit 's/^int b = 2;$/int b = 22;/' engine.c
$fork save second-change >/dev/null
expect "update stops at a patch that conflicts" 1 "0001-first-change.patch does not apply to v3" $fork update v3
kept="$(printf '%s\n' "$out" | sed -n 's/^  scripts\/quickjs-fork.sh update --continue //p')"
holds "update names the folder to continue from" test -d "$kept/repo"
holds "the stopped update leaves the engine folder as it was" grep -qx 'int a = 10;' "$src/engine.c"
expect "update --continue refuses a conflict still marked" 1 "still has conflict markers" $fork update --continue "$kept"
engine 1000 2 30 > "$kept/repo/engine.c"
expect "update --continue finishes the update" 0 "$src is now v3 plus the patches" $fork update --continue "$kept"
holds "the resolved line is in the folder" grep -qx 'int a = 1000;' "$src/engine.c"
holds "the patch after the conflict is applied too" grep -qx 'int b = 22;' "$src/engine.c"
expect "check passes after the continued update" 0 "$src is v3 plus 2 patches" $fork check
holds "update --continue removes the work folder" test ! -e "$kept"
expect "update --continue refuses a folder it did not make" 2 "is not an update stopped at a conflict" $fork update --continue "$root"

fresh
edit 's/^int b = 2;$/int b = 22;/' engine.c
$fork save second-change >/dev/null
expect "update stops at a patch that conflicts, again" 1 "0001-first-change.patch does not apply to v3" $fork update v3
kept="$(printf '%s\n' "$out" | sed -n 's/^  scripts\/quickjs-fork.sh update --continue //p')"
engine 1000 2 30 > "$kept/repo/engine.c"
awk '{ print } /^    in_repo commit -q -m "\$name"$/ { print "    exit 99" }' $fork > scripts/stop-after-record.sh
chmod +x scripts/stop-after-record.sh
expect "a continue stopped right after recording its patch" 99 "" scripts/stop-after-record.sh update --continue "$kept"
expect "update --continue again moves on without dropping that patch" 0 "$src is now v3 plus the patches" $fork update --continue "$kept"
holds "the recorded patch is kept" test -s "$src/patches/0001-first-change.patch"
expect "check passes after the retried continue" 0 "$src is v3 plus 2 patches" $fork check

fresh
expect "update drops a patch the release already has" 0 "v4 already has the change in $src/patches/0001-first-change.patch" $fork update v4
holds "the dropped patch's file is gone" test ! -e "$src/patches/0001-first-change.patch"
expect "check passes with no patches left" 0 "$src is v4 plus 0 patches" $fork check

fresh
expect "update names a tag quickjs-ng does not have" 1 "quickjs-ng has no tag v9" $fork update v9
expect "update refuses a REF that is not a tag or commit" 2 "usage" $fork update 'v1;true'

if [[ "$failures" != 0 ]]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
