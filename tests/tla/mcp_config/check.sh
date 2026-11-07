#!/bin/sh
# Model-check how fx reads a profile mcp.json on each surface, and which MCP
# server URLs it takes (src/core/mcp/http_config.zig, project_config.zig,
# src/builtins/mcp.zig, src/acp/sessions.zig), with TLC, and require each
# config's expected verdict.
#
# ProfileLoad.cfg and ProfileLoad.deep.cfg are the fix and must pass. The
# before-* configs are fx before it, and each must break the rule named:
#
#   before-port         plain HTTP needs a port, so http://localhost/mcp is skipped   LoopbackHttpNeverSkipped
#   before-acp          one bad entry fails ACP's whole profile                       OneBadEntrySkipsOnlyItself
#
# Each mutation-*.cfg plants one defect, and the rule it names must catch it:
#
#   any-host            plain HTTP with no port passes for any host                   PlainHttpOnlyToLoopback
#   stop                reading stops at the first bad entry                          OneBadEntrySkipsOnlyItself
#   silent              ACP leaves an entry out without a trace line                  EverySkipNoted
#
# ProfileLoadTrace.tla checks runs of the built fx binary against the model;
# tests/tla/drivers/mcp_config/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh ProfileLoad ProfileLoad.mutation-stop
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
ProfileLoad ProfileLoad -
ProfileLoad ProfileLoad.deep -
ProfileLoad ProfileLoad.before-port LoopbackHttpNeverSkipped
ProfileLoad ProfileLoad.before-acp OneBadEntrySkipsOnlyItself
ProfileLoad ProfileLoad.mutation-any-host PlainHttpOnlyToLoopback
ProfileLoad ProfileLoad.mutation-stop OneBadEntrySkipsOnlyItself
ProfileLoad ProfileLoad.mutation-silent EverySkipNoted
VERDICTS
