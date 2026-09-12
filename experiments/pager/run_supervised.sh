#!/usr/bin/env bash
# Guest-only timeout wrapper. It cannot contain a kernel panic.
set -euo pipefail
MODEL=$(sysctl -n hw.model)
case "$MODEL" in
  VirtualMac*) ;;
  *) echo 'Refusing host execution: run pager experiments inside a macOS VM.' >&2; exit 85 ;;
esac
if [[ $# -lt 1 ]]; then
  echo 'usage: run_supervised.sh <binary> [args...]' >&2
  exit 64
fi
# Python runs only inside the guest. Always collect both streams and status.
exec python3 - "$@" <<'PY'
import subprocess,sys
try:
    result = subprocess.run(sys.argv[1:], timeout=30)
except subprocess.TimeoutExpired:
    print('pager guest watchdog expired', file=sys.stderr)
    sys.exit(124)
sys.exit(result.returncode if result.returncode >= 0 else 128-result.returncode)
PY
