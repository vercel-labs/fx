#!/usr/bin/env bash
# Rebuild fx-term.wasm from this checkout and copy it into the site assets.
# Requires nix + zig 0.16.0+.
#
#   site/scripts/sync-wasm.sh [source-repo-path]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$(cd "$ROOT/../.." && pwd)}"

cd "$SOURCE"
nix shell nixpkgs#zig --command zig build -Dwasm-surface=term -Doptimize=ReleaseSmall
cp zig-out/bin/fx-term.wasm "$ROOT/fx-term.wasm"
echo "synced: $ROOT/fx-term.wasm ($(stat -c%s "$ROOT/fx-term.wasm") bytes)"
