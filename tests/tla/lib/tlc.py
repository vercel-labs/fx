"""Java and tla2tools.jar for the Python checkers.

`toolchain()` asks `tlc_find` in tlc.sh, so a Python checker looks in the
same places as every shell checker: TLA2TOOLS_JAR or
~/.local/share/tla/tla2tools.jar, and Java in JAVA_HOME, Homebrew's OpenJDK,
or PATH.
"""

import functools
import os
import pwd
import subprocess
import sys
from pathlib import Path

_TLC_SH = Path(__file__).resolve().with_name("tlc.sh")


@functools.cache
def toolchain():
    """Return (java, jar). Exits with status 2 and tlc_find's message when
    either is missing, as the shell checkers do."""
    # The account's home, not $HOME: drivers run fx under a disposable HOME,
    # and the default jar lives in the real one.
    env = {**os.environ, "HOME": pwd.getpwuid(os.getuid()).pw_dir}
    found = subprocess.run(
        ["sh", "-c", '. "$1" && tlc_find && printf "%s\\n%s\\n" "$tlc_java" "$tlc_jar"', "sh", str(_TLC_SH)],
        env=env, capture_output=True, text=True,
    )
    if found.returncode != 0:
        sys.stderr.write(found.stderr)
        raise SystemExit(2)
    java, jar = found.stdout.splitlines()
    return java, jar
