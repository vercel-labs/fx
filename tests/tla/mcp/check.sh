#!/bin/sh
# Model-check the MCP engine models (src/mcp/) with TLC.
#
# run.py reads catalog.json: each model's smoke config must pass, and each
# planted bug in <Module>.mutants.json must be caught by its named property.
# Pass run.py's selection flags through, for example:
#   ./check.sh --model Engine Request
#   ./check.sh --unit U12
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
# it holds. Request.scoped.cfg has two normal requests and no more, for the scope of a refused
# line (ScopedGrantsOnlyItsCall), and must pass. Each verdict is required (../lib/tlc.sh). Other pull requests add findings blocks to this file too: when two land,
# merge them into one tlc_verdicts block.
. ../lib/tlc.sh
tlc_verdicts <<'EOF_FINDINGS'
Request Request.scoped -
Request Request.findings SoonAfterRefusal
EOF_FINDINGS
