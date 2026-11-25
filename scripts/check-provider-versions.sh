#!/usr/bin/env bash
# Fails when a Codex or Grok client version that fx pins is behind the
# provider's current stable release. fx sends these versions to ChatGPT and
# Grok and pins them in each release, so it never looks them up at runtime
# (RULES.md R4.7). The stable release runs this check before it publishes.
set -euo pipefail

cd "$(dirname "$0")/.."
pins_file="src/core/gateway/provider_versions.zig"
version_pattern='^[0-9]+\.[0-9]+\.[0-9]+$'
status=0

pinned() {
  sed -n "s/^pub const $1 = \"\([0-9.]*\)\";\$/\1/p" "$pins_file"
}

is_behind() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]
}

check() {
  local label="$1" constant="$2" latest="$3"
  local pin
  pin="$(pinned "$constant")"
  if ! [[ "$pin" =~ $version_pattern ]]; then
    echo "::error file=$pins_file::Could not read $constant from $pins_file."
    status=1
    return
  fi
  if ! [[ "$latest" =~ $version_pattern ]]; then
    echo "::error::Could not read the current $label release, got '$latest'."
    status=1
    return
  fi
  if is_behind "$pin" "$latest"; then
    echo "::error file=$pins_file::$label client version $pin is behind the current release $latest. Set $constant to \"$latest\" in $pins_file."
    status=1
    return
  fi
  echo "$label client version $pin is current."
}

codex_latest="$(curl -fsS --max-time 20 https://registry.npmjs.org/@openai/codex/latest |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["version"])')" || codex_latest=""
grok_latest="$(curl -fsS --max-time 20 https://x.ai/cli/stable | tr -d '[:space:]')" || grok_latest=""

check "Codex" codex_client_version "$codex_latest"
check "Grok" grok_client_version "$grok_latest"
exit "$status"
