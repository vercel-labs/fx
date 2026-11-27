#!/bin/sh
# Model-check TerminalCancel: the terminal client's cancel path for the code
# before the one-hold change (current), the code now (design_a), and the
# planted mutant that splits design_a's hold again (mutant_a). Each expected
# violation prints its last steps. The simulate configs run random behaviors
# of design_a in ideal and nonideal conditions; SIM_RUNS sets how many
# (default 20000).
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
status=0
tlc_verdicts "$@" <<EOF || status=$?
TerminalCancel current-gap CancelIsSeen
TerminalCancel current-home AlwaysFindable
TerminalCancel design-a -
TerminalCancel mutant-a CancelIsSeen
TerminalCancel simulate-ideal simulate $sim
TerminalCancel simulate-nonideal simulate $sim
EOF

# Print the last steps of one TLC error trace: the step label and the
# variables that matter for the cancel path.
show_trace() {
    echo "trace of $1 (last steps):"
    grep -E "is violated|Temporal properties were violated" "$tlc_work/$1.log" || true
    awk -v keep=6 '
        /^State [0-9]+:/ {
            n++
            label[n] = $0
            sub(/^State [0-9]+: <?/, "", label[n])
            sub(/ line .*/, "", label[n])
            sub(/>$/, "", label[n])
            row[n] = ""
            next
        }
        /^\/\\ (wpc|inQueue|held|active|flag|pushed|kind|cancelSent|cancelRet) = / {
            row[n] = row[n] " " $2 "=" $4
        }
        END {
            from = n - keep + 1
            if (from < 1) from = 1
            for (i = from; i <= n; i++) printf "  step %d %s:%s\n", i, label[i], row[i]
        }
    ' "$tlc_work/$1.log"
}

for config in current-gap current-home mutant-a; do
    if [ -f "$tlc_work/$config.log" ] && grep -q -E "is violated|Temporal properties were violated" "$tlc_work/$config.log"; then
        show_trace "$config"
    fi
done

exit "$status"
