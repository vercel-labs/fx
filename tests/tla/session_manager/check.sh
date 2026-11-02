#!/bin/sh
# Model-check every session-manager spec with TLC.
#
# Needs Java 11+ and tla2tools.jar:
#   brew install openjdk
#   mkdir -p ~/.local/share/tla
#   curl -fL -o ~/.local/share/tla/tla2tools.jar \
#     https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
#
# Usage:
#   ./check.sh                     # every spec
#   ./check.sh SessionLog Fork     # selected specs
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"

jar="${TLA2TOOLS_JAR:-$HOME/.local/share/tla/tla2tools.jar}"
if [ ! -f "$jar" ]; then
    echo "tla2tools.jar not found at $jar (set TLA2TOOLS_JAR)" >&2
    exit 2
fi
# Prefer JAVA_HOME, then Homebrew's keg-only openjdk, then java on PATH.
java=""
for candidate in \
    "${JAVA_HOME:+$JAVA_HOME/bin/java}" \
    /opt/homebrew/opt/openjdk/bin/java \
    /usr/local/opt/openjdk/bin/java \
    "$(command -v java 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" -version >/dev/null 2>&1; then
        java="$candidate"
        break
    fi
done
if [ -z "$java" ]; then
    echo "no working Java runtime (set JAVA_HOME or brew install openjdk)" >&2
    exit 2
fi

all="SessionLog TurnLifecycle WriterLock ResumeSnapshot Fork Subagents Catalog Lifecycle Wiring MoveSideFiles V1Conversion PromptImages"
specs="${*:-$all}"
# A new private folder per run for TLC state, so nothing planted in the temp
# folder can redirect it. TLC prints to the terminal, so it is removed.
work="$(mktemp -d "${TMPDIR:-/tmp}/session-manager-tlc.XXXXXX")"
trap 'rm -rf "$work"' EXIT

status=0
for spec in $specs; do
    echo "== $spec"
    # -deadlock: do not report states with no enabled action. Every spec is
    # bounded (MaxLen, MaxLines, finite id sets), so terminal states are
    # expected at the bound.
    if ! "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC \
        -deadlock -workers auto -cleanup \
        -metadir "$work/$spec" \
        -config "$spec.cfg" "$spec.tla"; then
        status=1
    fi
done
exit "$status"
