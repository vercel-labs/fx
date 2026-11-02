# shellcheck shell=sh
# Shared TLC helpers for the check.sh scripts under tests/tla/. Source it:
#
#   . "$(dirname "$0")/../lib/tlc.sh"
#
# tlc_find sets $tlc_java and $tlc_jar, or exits 2 with a message. It uses
# TLA2TOOLS_JAR, or ~/.local/share/tla/tla2tools.jar, and the first working
# Java in JAVA_HOME, Homebrew's OpenJDK, and PATH. ../README.md lists the
# requirements.
#
# tlc_verdicts reads one check per line from standard input and runs each with
# TLC from the current directory:
#
#   <Spec> <config> <expect> [extra TLC flags...]
#
# <config> names <config>.cfg. <expect> is "-" when the config must pass, the
# name of an invariant or action property that must be violated, "temporal"
# when a temporal property must be violated, "deadlock" when TLC must reach
# a deadlock, or "simulate" when a random simulation (-simulate in the flags)
# must finish without an error. Blank lines and lines starting with # are skipped. Pass config
# names as arguments to run only those checks. It prints one ok or FAIL line
# per check and returns 1 when any check misses its verdict, or when an
# argument names no config. Logs go to $tlc_work, a new private folder that
# mktemp -d makes under TMPDIR for each run, so another user cannot plant a
# file or link where a log will be written.

tlc_find() {
    tlc_jar="${TLA2TOOLS_JAR:-$HOME/.local/share/tla/tla2tools.jar}"
    if [ ! -f "$tlc_jar" ]; then
        echo "tla2tools.jar not found at $tlc_jar (set TLA2TOOLS_JAR)" >&2
        exit 2
    fi
    tlc_java=""
    # /usr/bin/java on macOS is a stub that fails -version without a runtime.
    for candidate in \
        "${JAVA_HOME:+$JAVA_HOME/bin/java}" \
        /opt/homebrew/opt/openjdk/bin/java \
        /usr/local/opt/openjdk/bin/java \
        "$(command -v java 2>/dev/null || true)"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" -version >/dev/null 2>&1; then
            tlc_java="$candidate"
            break
        fi
    done
    if [ -z "$tlc_java" ]; then
        echo "no working Java runtime (set JAVA_HOME or brew install openjdk)" >&2
        exit 2
    fi
}

tlc_verdicts() {
    tlc_find
    tlc_work="$(mktemp -d "${TMPDIR:-/tmp}/fx-tla-$(basename "$(pwd)").XXXXXX")" || {
        echo "cannot create a private folder under ${TMPDIR:-/tmp}" >&2
        exit 2
    }
    echo "logs: $tlc_work"
    tlc_status=0
    tlc_ran=""
    while read -r spec config expect flags; do
        case "$spec" in '' | '#'*) continue ;; esac
        if [ "$#" -gt 0 ]; then
            case " $* " in *" $config "*) ;; *) continue ;; esac
        fi
        tlc_ran="$tlc_ran $config"
        log="$tlc_work/$config.log"
        mkdir -p "$tlc_work/$config.tmp"
        # $flags is split on purpose: it holds zero or more TLC flags.
        # shellcheck disable=SC2086
        # A private java.io.tmpdir per run: TLC unpacks its standard modules
        # there, and concurrent runs sharing one folder can lose them.
        if "$tlc_java" -XX:+UseParallelGC -Xss4m "-Djava.io.tmpdir=$tlc_work/$config.tmp" -cp "$tlc_jar" tlc2.TLC \
            -workers auto -cleanup -metadir "$tlc_work/$config.states" \
            $flags -config "$config.cfg" "$spec.tla" >"$log" 2>&1; then
            code=0
        else
            code=$?
        fi
        case "$expect" in
        -)
            if [ "$code" -eq 0 ] && grep -q "No error has been found" "$log"; then
                echo "ok    $config: no error"
                continue
            fi
            ;;
        temporal)
            if grep -q "Temporal properties were violated" "$log"; then
                echo "ok    $config: temporal property violated, as required"
                continue
            fi
            ;;
        simulate)
            if [ "$code" -eq 0 ] && ! grep -q "^Error:" "$log"; then
                echo "ok    $config: simulation found no error"
                continue
            fi
            ;;
        deadlock)
            if grep -q "Deadlock reached" "$log"; then
                echo "ok    $config: deadlock reached, as required"
                continue
            fi
            ;;
        *)
            if grep -q -E "(Invariant|Action property) $expect is violated" "$log"; then
                echo "ok    $config: $expect violated, as required"
                continue
            fi
            ;;
        esac
        echo "FAIL  $config: expected $expect, TLC exited $code (see $log)"
        tlc_status=1
    done
    for wanted in "$@"; do
        case "$tlc_ran " in *" $wanted "*) ;; *)
            echo "FAIL  $wanted: no such config"
            tlc_status=1
            ;;
        esac
    done
    return "$tlc_status"
}
