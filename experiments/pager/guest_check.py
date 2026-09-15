#!/usr/bin/env python3
"""Run only inside a VirtualMac guest and capture bounded process results."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--timeout', type=float, default=30)
    p.add_argument('--repeat', type=int, default=1)
    p.add_argument('binary', type=Path)
    p.add_argument('args', nargs='*')
    a = p.parse_args()
    if a.repeat < 1 or a.timeout <= 0:
        p.error("repeat and timeout must be positive")
    model = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], text=True).strip()
    if not model.startswith('VirtualMac'):
        sys.exit('refusing to execute pager checks on a physical host')
    exe = a.binary.resolve()
    if not exe.is_file():
        sys.exit('binary does not exist')
    results = []
    for _ in range(a.repeat):
        t = time.monotonic()
        try:
            r = subprocess.run([str(exe), *a.args], capture_output=True, timeout=a.timeout)
            result = dict(returncode=r.returncode, stdout=r.stdout.decode(errors='replace'), stderr=r.stderr.decode(errors='replace'))
        except subprocess.TimeoutExpired as e:
            result = dict(returncode=124, stdout=(e.stdout or b'').decode(errors='replace'), stderr=(e.stderr or b'').decode(errors='replace'))
        result['seconds'] = time.monotonic()-t
        results.append(result)
        if result['returncode'] != 0:
            break
    print(json.dumps(dict(model=model, os=subprocess.check_output(['sw_vers'], text=True), results=results), indent=2))
    return 0 if all(r['returncode'] == 0 for r in results) else 1


if __name__ == '__main__':
    sys.exit(main())
