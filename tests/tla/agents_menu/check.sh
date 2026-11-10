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
# tests/tla/drivers/agents_menu/ runs the built zig-out/bin/fx along the model:
# binary-to-spec.ts has TLC check seeded key sequences the binary ran
# (spec/TraceAgentsMenu.tla), and spec-to-binary.ts replays model behaviors
# against the binary and compares every state.
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
VERDICTS
