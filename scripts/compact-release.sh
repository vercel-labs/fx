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
# --mergefunc runs the whole-program bitcode through LLVM's mergefunc pass
# and recompiles at -Oz before linking. Identical functions that Zig's own
# pipeline leaves separate are folded, and on macOS the ld64 link dedups
# __cstring constants that the Zig linker keeps verbatim. Measured on
# aarch64-macos: ~54 KiB below the plain ReleaseSmall link.
#
# Usage:
#   scripts/compact-release.sh                     # host platform only
#   scripts/compact-release.sh --all               # all four native targets
#   scripts/compact-release.sh --target=aarch64-macos
#   scripts/compact-release.sh --xz                # also emit .xz artifacts
#   scripts/compact-release.sh --mergefunc         # LLVM mergefunc pipeline
#
# Requires: zig on PATH. --mergefunc additionally requires an LLVM toolchain
# with opt and clang (brew install llvm; or set LLVM_DIR). macOS targets use
# the host `strip` tool; Linux targets use llvm-strip when present.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/zig-out/compact"
TARGETS=()
EMIT_XZ=false
USE_MERGEFUNC=false

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
    --mergefunc)
      USE_MERGEFUNC=true
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

# Directory containing an LLVM toolchain with opt and clang for --mergefunc.
find_llvm_dir() {
  if [ -n "${LLVM_DIR:-}" ] && [ -x "${LLVM_DIR}/bin/opt" ] && [ -x "${LLVM_DIR}/bin/clang" ]; then
    printf '%s\n' "${LLVM_DIR}/bin"
    return 0
  fi
  for candidate in /opt/homebrew/opt/llvm@*/bin /usr/local/opt/llvm@*/bin; do
    if [ -x "$candidate/opt" ] && [ -x "$candidate/clang" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# Build via whole-program bitcode: mergefunc folds identical functions, the
# -Oz recompile re-runs codegen, and the ld64 link on macOS merges duplicate
# __cstring constants that the Zig linker emits verbatim.
build_mergefunc() {
  local target="$1" cache="$2" prefix="$3" bin_out="$4"
  local llvm_dir
  if ! llvm_dir="$(find_llvm_dir)"; then
    echo "error: --mergefunc needs LLVM opt and clang (brew install llvm, or set LLVM_DIR)" >&2
    exit 1
  fi

  local ztargs=()
  if [ -n "$target" ]; then
    ztargs=("-Dtarget=$target")
  fi

  zig build pgso-ir -Dpgso-artifact=fx -Doptimize=ReleaseSmall \
    ${ztargs[@]+"${ztargs[@]}"} \
    --prefix "$prefix" \
    --cache-dir "$cache" \
    --global-cache-dir "${cache}-global"
  local bc="$prefix/pgso/fx.bc"
  "$llvm_dir/opt" -passes=mergefunc "$bc" -o "$prefix/fx.mf.bc"

  local effective="$target"
  if [ -z "$effective" ]; then
    case "$(uname -sm)" in
      "Darwin arm64") effective=aarch64-macos ;;
      "Darwin x86_64") effective=x86_64-macos ;;
      *) echo "error: --mergefunc only supports macOS hosts: $(uname -sm)" >&2; exit 1 ;;
    esac
  fi

  local obj="$prefix/fx.mf.o"
  local arch sdkroot crt
  case "$effective" in
    aarch64-macos) arch=arm64 ;;
    x86_64-macos) arch=x86_64 ;;
    *)
      echo "error: --mergefunc only supports macOS targets: $effective" >&2
      exit 1
      ;;
  esac
  sdkroot="$(xcrun --sdk macosx --show-sdk-path)"
  # compiler_rt builtins are referenced by the object; the per-target
  # global cache holds the archive Zig linked for this exact target.
  crt="$(find "${cache}-global" -name 'libcompiler_rt_zcu.o' | head -1)"
  if [ -z "$crt" ]; then
    echo "error: compiler_rt object not found under ${cache}-global" >&2
    exit 1
  fi
  "$llvm_dir/clang" -arch "$arch" -Oz -c "$prefix/fx.mf.bc" -o "$obj"
  mkdir -p "$(dirname "$bin_out")"
  "$llvm_dir/clang" -arch "$arch" -Wl,-dead_strip -isysroot "$sdkroot" \
    "$obj" "$crt" -lSystem -o "$bin_out"
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
    prefix="$OUT_DIR/native"
    label="native"
  else
    prefix="$OUT_DIR/$target"
    label="$target"
  fi

  if [ "$USE_MERGEFUNC" = true ]; then
    case "$target" in
      aarch64-macos | x86_64-macos)
        build_mergefunc "$target" "$cache" "$prefix" "$prefix/bin/fx"
        ;;
      native)
        if [ "$(uname -s)" = "Darwin" ]; then
          build_mergefunc "" "$cache" "$prefix" "$prefix/bin/fx"
        else
          echo "note: --mergefunc only helps macOS targets; plain build for native" >&2
          zig build -Doptimize=ReleaseSmall \
            --prefix "$prefix" \
            --cache-dir "$cache" \
            --global-cache-dir "${cache}-global"
        fi
        ;;
      *)
        echo "note: --mergefunc only helps macOS targets; plain build for $target" >&2
        zig build -Doptimize=ReleaseSmall \
          -Dtarget="$target" \
          --prefix "$prefix" \
          --cache-dir "$cache" \
          --global-cache-dir "${cache}-global"
        ;;
    esac
  elif [ "$target" = "native" ]; then
    zig build -Doptimize=ReleaseSmall \
      --prefix "$prefix" \
      --cache-dir "$cache" \
      --global-cache-dir "${cache}-global"
  else
    zig build -Doptimize=ReleaseSmall \
      -Dtarget="$target" \
      --prefix "$prefix" \
      --cache-dir "$cache" \
      --global-cache-dir "${cache}-global"
  fi
  bin="$prefix/bin/fx"

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
