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

# A property the model of today's code is known to break must stay broken until the code is
# repaired: Request.findings.cfg states that a request in flight at a refused line that names
# no request, and silent, ends within the grace, which fails while there is no grace and the
# request waits for its own deadline (5 minutes by default). Each verdict is required
# (../lib/tlc.sh). Other pull requests add findings blocks to this file too: when two land,
# merge them into one tlc_verdicts block.
. ../lib/tlc.sh
tlc_verdicts <<'EOF_FINDINGS'
Request Request.findings SoonAfterRefusal
EOF_FINDINGS
