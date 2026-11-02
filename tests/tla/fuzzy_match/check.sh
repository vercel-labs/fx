#!/usr/bin/env bash
# Checks the fuzzy match engine: TLC on every config in spec/, every planted
# bug, the edge table, the oracle, the built binary's menus, the engine
# against the model, the stress budgets, and design/GOAL.md traceability.
# `bun run verify` in this folder is the gate; this script is the
# tests/tla/<area>/check.sh entry point that runs it.
set -euo pipefail
cd "$(dirname "$0")"
exec bun run verify
