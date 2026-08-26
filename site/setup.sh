#!/usr/bin/env bash
# oh-my-fx installer — builds from source with Zig (no release binaries yet).
# Once releases exist, switch this to fetching tarballs from a releases URL.
set -euo pipefail

BIN_DIR="${FX_INSTALL_DIR:-$HOME/.local/bin}"

err() { printf 'error: %s\n' "$*" >&2; exit 1; }

TMP_DIR=""
cleanup() {
  [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

is_interactive() { [ -t 0 ] && [ -t 2 ]; }

check_zig() {
  command -v zig >/dev/null 2>&1 || err "zig 0.16.0+ is required (https://ziglang.org/download/)"
  local version major minor
  version="$(zig version)"
  major="${version%%.*}"
  minor="${version#*.}"
  minor="${minor%%.*}"
  if [ "$major" -eq 0 ] && [ "$minor" -lt 16 ]; then
    err "zig 0.16.0+ is required (https://ziglang.org/download/)"
  fi
}

main() {
  check_zig
  command -v git >/dev/null 2>&1 || err "git is required (https://git-scm.com/)"

  TMP_DIR="$(mktemp -d)"
  git clone --depth 1 https://github.com/y0usaf/oh-my-fx "$TMP_DIR/oh-my-fx"

  (
    cd "$TMP_DIR/oh-my-fx"
    zig build -Doptimize=ReleaseSafe
  )

  mkdir -p "$BIN_DIR"
  cp "$TMP_DIR/oh-my-fx/zig-out/bin/fx" "$BIN_DIR/fx"
  chmod +x "$BIN_DIR/fx"

  # The CLI has no --version flag, so read the version constant from source.
  version="$(grep -m1 'pub const version' "$TMP_DIR/oh-my-fx/src/main.zig" | sed -E 's/.*"([^"]+)".*/\1/')"
  printf "installed fx %s\n" "$version" >&2

  if ! printf '%s' "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    local shell_name rc_file=""
    shell_name="$(basename "${SHELL:-/bin/sh}")"
    case "$shell_name" in
      zsh) rc_file="$HOME/.zshrc" ;;
      bash)
        if [ -f "$HOME/.bash_profile" ]; then
          rc_file="$HOME/.bash_profile"
        else
          rc_file="$HOME/.bashrc"
        fi
        ;;
      fish) rc_file="$HOME/.config/fish/config.fish" ;;
    esac

    local path_line
    if [ "$shell_name" = "fish" ]; then
      path_line="set -gx PATH ${BIN_DIR} \$PATH"
    else
      path_line="export PATH=\"${BIN_DIR}:\$PATH\""
    fi

    if [ -n "$rc_file" ] && ! grep -qF "$BIN_DIR" "$rc_file" 2>/dev/null; then
      {
        echo ""
        echo "# fx"
        echo "$path_line"
      } >> "$rc_file"
    fi

    if is_interactive; then
      printf "run this to use fx now: %s\n" "$path_line" >&2
      printf "or restart your shell\n" >&2
    else
      printf "to use fx, add to PATH: %s\n" "$BIN_DIR" >&2
    fi
  fi

  if ! is_interactive; then
    printf '%s\n' "$BIN_DIR/fx"
  fi
}

main "$@"
