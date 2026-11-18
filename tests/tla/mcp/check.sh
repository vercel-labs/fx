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
#   Elicitation.findings   matching a form's names by their bytes refuses an
#                          answer that fits the form (the engine before it
#                          matched decoded strings)                  FitAccepted
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

# A property that the model of the code before the grace breaks must stay broken: Request.findings.cfg
# models that code (GraceOn = FALSE) and states that a request in flight at a refused line that
# names no request, and silent, ends within the grace. It fails there, because the request waits
# for its own deadline (5 minutes by default); Request.cfg models the code with the grace, where
# it holds. Each verdict is required (../lib/tlc.sh). Other pull requests add findings blocks to this
# file too: when two land, merge them into one tlc_verdicts block.
#
# Request.scoped.cfg (two normal requests and no more, for the scope of a refused line,
# ScopedGrantsOnlyItsCall) is not here: catalog.json lists it under "also", so `run.py check` runs it
# next to the smoke config, in CI too.
#
# WireDepth.findings.cfg models the code before the depth limit on a server's JSON (before this change)
# and states that every writer can write whatever an entry point accepts, which fails while there is no
# limit but the engine's.
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh
tlc_verdicts <<'EOF_FINDINGS'
Request Request.findings SoonAfterRefusal
WireDepth WireDepth.findings NoWriterOverflow
FieldRead FieldRead.findings AgreeOrRefused
FieldRead FieldRead.findings.isError ReportedAsSaid
Elicitation Elicitation.findings FitAccepted
EOF_FINDINGS
