#!/bin/sh
# Model-check the agent list (spec/AgentsMenu.tla; AgentsMenu, openMenu,
# moveMenu, submitMenu, backMenu, pressCloseKey, and switchList in
# src/core/app/app_agents_runtime.zig) with TLC and require each config's
# expected verdict.
#
# agents-menu.cfg, agents-menu-three.cfg, and agents-menu-drive.cfg (the world
# spec-to-binary.ts drives) are the design and must pass. Each
# agents-menu-mutation-*.cfg plants one bug, and the rule it names must catch
# it:
#
#   preview     a move shows the row it lands on (fx before)      ScreenOnlyOnEnter
#   enter-noop  Enter closes the list without showing the row     EnterShowsSelection
#   open-first  the list opens on its first row                   OpensOnScreen
#   pin         the highlight snaps back to the agent on screen   SelectionKept
#   stale-sel   the highlight stays on an agent that closed       SelListed
#
# spec/RowOrder.tla models how a subagent's row changes when its turn ends: its
# label comes from the worker and its place from the history the main loop
# applies later, and the two must come from the same applied update.
# row-order.cfg is the design and must pass. The planted bug below must be
# caught by the rule it names; the second config checks the place rule alone:
#
#   worker-flag       the label follows the worker flag alone, so a finished
#                     turn that is not applied shows idle at its old place
#                                                              IdleRowIsApplied
#   worker-flag-flip  the same bug, seen as a row that moves with no change
#                     of label                              PlaceChangesWithLabel
#
# tests/tla/drivers/agents_menu/ runs the built zig-out/bin/fx along the model:
# binary-to-spec.ts has TLC check seeded key sequences the binary ran
# (spec/TraceAgentsMenu.tla), spec-to-binary.ts replays model behaviors
# against the binary and compares every state, and row-order.ts has TLC check
# the frames of the list while subagents finish (spec/TraceRowOrder.tla).
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh agents-menu agents-menu-mutation-preview
set -eu
cd "$(dirname "$0")/spec"
. ../../lib/tlc.sh
tlc_verdicts "$@" <<'VERDICTS'
MCAgentsMenu agents-menu -
MCAgentsMenu agents-menu-three -
MCAgentsMenu agents-menu-drive -
MCAgentsMenu agents-menu-mutation-preview ScreenOnlyOnEnter
MCAgentsMenu agents-menu-mutation-enter-noop EnterShowsSelection
MCAgentsMenu agents-menu-mutation-open-first OpensOnScreen
MCAgentsMenu agents-menu-mutation-pin SelectionKept
MCAgentsMenu agents-menu-mutation-stale-sel SelListed
MCRowOrder row-order -
MCRowOrder row-order-mutation-worker-flag IdleRowIsApplied
MCRowOrder row-order-mutation-worker-flag-flip PlaceChangesWithLabel
VERDICTS
