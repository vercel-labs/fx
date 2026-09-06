#!/usr/bin/env python3
"""Reject Linux addons that require glibc newer than the release baseline."""

import re
import subprocess
import sys


def check_versions(report):
    versions = set(re.findall(r"\bGLIBC_([0-9]+(?:\.[0-9]+)+)\b", report))
    if not versions:
        raise ValueError("no glibc version requirements found")
    if "GLIBC_PRIVATE" in report:
        raise ValueError("addon requires private glibc symbols")
    newest = max(versions, key=lambda value: tuple(map(int, value.split("."))))
    if tuple(map(int, newest.split("."))) > (2, 34, 0):
        raise ValueError(f"addon requires GLIBC_{newest}; maximum supported is GLIBC_2.34")
    return newest


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: check-linux-abi.py addon.node")
    try:
        report = subprocess.run(
            ["readelf", "--version-info", sys.argv[1]],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        newest = check_versions(report)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        sys.exit(str(error))
    print(f"Linux addon requires at most GLIBC_{newest} (baseline: GLIBC_2.34)")
