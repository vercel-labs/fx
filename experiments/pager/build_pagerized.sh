#!/usr/bin/env bash
# Static-only build. Execute the output exclusively in a macOS guest.
set -euo pipefail
PAGER_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$PAGER_DIR/build_pagerized.py" "$@"
