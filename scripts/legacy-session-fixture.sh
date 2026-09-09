#!/usr/bin/env bash
set -euo pipefail

# Produce real pre-journal sessions and qualify older-reader rejection with the
# same public executable. The current binary remains the recovery test subject.
legacy_ref=43c11dcc34a94a76df870af70bdb824579bf18a0
repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

if [[ -n "${FX_TEST_LEGACY_EXE:-}" ]]; then
  [[ "$FX_TEST_LEGACY_EXE" = /* && -x "$FX_TEST_LEGACY_EXE" ]] || {
    printf 'FX_TEST_LEGACY_EXE must name an absolute executable path\n' >&2
    exit 1
  }
  printf '%s\n' "$FX_TEST_LEGACY_EXE"
  exit 0
fi

cache_dir="$repo_root/.zig-cache/legacy-fixture/$legacy_ref/$(uname -s)-$(uname -m)-$(zig version)"
if [[ -x "$cache_dir/fx" ]]; then
  printf '%s\n' "$cache_dir/fx"
  exit 0
fi

if ! git -C "$repo_root" cat-file -e "$legacy_ref^{commit}" 2>/dev/null; then
  git -C "$repo_root" fetch --no-tags https://github.com/vercel-labs/fx.git "$legacy_ref" >&2
fi
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/fx-legacy-fixture.XXXXXX")"
cleanup() {
  git -C "$repo_root" worktree remove --force "$build_dir/source" >/dev/null 2>&1 || true
  rm -rf "$build_dir"
}
trap cleanup EXIT
git -C "$repo_root" worktree add --detach "$build_dir/source" "$legacy_ref" >&2
(
  cd "$build_dir/source"
  zig build -Doptimize=ReleaseSafe --prefix "$build_dir/output" >&2
)
mkdir -p "$cache_dir"
candidate="$(mktemp "$cache_dir/fx.XXXXXX")"
cp "$build_dir/output/bin/fx" "$candidate"
chmod 755 "$candidate"
mv -f "$candidate" "$cache_dir/fx"
printf '%s\n' "$cache_dir/fx"
