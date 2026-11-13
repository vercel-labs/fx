#!/bin/sh
# Copies the crash reports macOS wrote for fx into a folder, so a PGSO job's
# evidence keeps them. A panic in the job's stripped fx prints no stack trace,
# but it ends in abort(), and macOS writes a report that lists each thread's
# frames as offsets into fx. The link maps in the seed's and the candidate's
# logs name the function at each offset (README.md, "Output and failure
# behavior").
set -eu

dest=${1:?usage: collect-crash-reports.sh <folder>}
reports="$HOME/Library/Logs/DiagnosticReports"
found=0
if [ -d "$reports" ]; then
  for report in "$reports"/fx-*.ips "$reports"/fx-*.crash; do
    [ -f "$report" ] || continue
    mkdir -p "$dest"
    cp -p "$report" "$dest/"
    found=$((found + 1))
  done
fi
echo "fx crash reports: $found"
