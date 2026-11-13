#!/bin/sh
# Model-check the MCP engine models (src/mcp/) with TLC.
#
# run.py reads catalog.json: each model's smoke config must pass, and each
# planted bug in <Module>.mutants.json must be caught by its named property.
# Pass run.py's selection flags through, for example:
#   ./check.sh --model Engine Request
#   ./check.sh --unit U12
#
# A findings config states a rule the code was known to break. It must fail,
# and the rule it names must be the one that fails. They run after the models
# whatever the selection, and are listed at the end of this script:
#
#   FieldRead.findings          comparing a member's name as written reads a
#                               name with an escape as absent, while std.json
#                               reads it once                   AgreeOrRefused
#   FieldRead.findings.isError  the same, seen as a tool result the server
#                               marked isError, shown as a success
#                                                              ReportedAsSaid
#
# The trace bridge and the scenarios that run the real code are in
# ../drivers/mcp/:
#   bun test ../drivers/mcp/bridge.test.ts
#   bun ../drivers/mcp/driver.ts --list
#
# Needs Java 11+, python3, and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
python3 run.py check "$@"
python3 run.py mutate "$@"

# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts <<'VERDICTS'
FieldRead FieldRead.findings AgreeOrRefused
FieldRead FieldRead.findings.isError ReportedAsSaid
VERDICTS
