#!/usr/bin/env bash
#
# Compact binary builds for fx.
#
# Builds stripped ReleaseSmall binaries per supported platform and reports
# their sizes. ReleaseSmall trades peak throughput for size: safety checks
# are disabled, inlining obeys -Os, and the symbol table is removed after
# linking. The macOS linker keeps local symbols for ReleaseSmall even with
# strip enabled, so the post-link strip pass is required for the compact
# size contract.
#
# Sizes land well below the ReleaseSafe PGSO ceiling: aarch64-macos builds
# are the compact surface reference and stay under 5 MiB.
#
# Usage:
#   scripts/compact-release.sh                     # host platform only
#   scripts/compact-release.sh --all               # all four native targets
#   scripts/compact-release.sh --target=aarch64-macos
#   scripts/compact-release.sh --xz                # also emit .xz artifacts
#
# Requires: zig on PATH. macOS targets additionally require the host
# `strip` tool; Linux targets use llvm-strip when present.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/zig-out/compact"
TARGETS=()
EMIT_XZ=false

while [ $# -gt 0 ]; do
  case "$1" in
    --all)
      TARGETS=(aarch64-macos x86_64-macos aarch64-linux x86_64-linux)
      ;;
    --target=*)
      TARGETS+=("${1#--target=}")
      ;;
    --xz)
      EMIT_XZ=true
      ;;
    *)
      echo "error: unknown option: $1" >&2
      exit 1
      ;;
  esac
  shift
done

if [ ${#TARGETS[@]} -eq 0 ]; then
  TARGETS=(native)
fi

find_llvm_strip() {
  if command -v llvm-strip &>/dev/null; then
    command -v llvm-strip
    return 0
  fi
  for candidate in /opt/homebrew/opt/llvm@*/bin/llvm-strip /usr/local/opt/llvm@*/bin/llvm-strip; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

strip_binary() {
  local bin="$1"
  local format
  format="$(file -b "$bin")"
  case "$format" in
    Mach-O*)
      strip "$bin"
      ;;
    ELF*)
      local elf_strip
      if elf_strip="$(find_llvm_strip)"; then
        "$elf_strip" --strip-all "$bin"
      else
        # GNU strip on Linux hosts handles ELF; macOS strip cannot.
        strip --strip-all "$bin" 2>/dev/null || true
        case "$(file -b "$bin")" in
          ELF*) ;;
          *)
            echo "error: no usable ELF strip tool found" >&2
            echo "       brew install llvm  (macOS hosts)" >&2
            exit 1
            ;;
        esac
      fi
      ;;
    *)
      echo "error: unsupported binary format: $format" >&2
      exit 1
      ;;
  esac
}

mkdir -p "$OUT_DIR"

printf "%-18s %12s %10s\n" "TARGET" "BYTES" "MiB"
for target in "${TARGETS[@]}"; do
  cache="${REPO_ROOT}/.zig-cache/compact-${target}"
  if [ "$target" = "native" ]; then
    zig build -Doptimize=ReleaseSmall \
      --prefix "$OUT_DIR/native" \
      --cache-dir "$cache" \
      --global-cache-dir "${cache}-global"
    bin="$OUT_DIR/native/bin/fx"
    label="native"
  else
    zig build -Doptimize=ReleaseSmall \
      -Dtarget="$target" \
      --prefix "$OUT_DIR/$target" \
      --cache-dir "$cache" \
      --global-cache-dir "${cache}-global"
    bin="$OUT_DIR/$target/bin/fx"
    label="$target"
  fi

  strip_binary "$bin"

  bytes="$(stat -f%z "$bin" 2>/dev/null || stat -c%s "$bin")"
  mib="$(awk -v b="$bytes" 'BEGIN { printf "%.3f", b / 1048576 }')"
  printf "%-18s %12d %10s\n" "$label" "$bytes" "$mib"

  if [ "$EMIT_XZ" = true ]; then
    xz -9 -T0 -c "$bin" > "$bin.xz"
    xz_bytes="$(stat -f%z "$bin.xz" 2>/dev/null || stat -c%s "$bin.xz")"
    xz_mib="$(awk -v b="$xz_bytes" 'BEGIN { printf "%.3f", b / 1048576 }')"
    printf "%-18s %12d %10s  (%s)\n" "$label" "$xz_bytes" "$xz_mib" "$bin.xz"
  fi
done
