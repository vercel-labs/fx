#!/bin/sh
# Model-check the agent list (spec/AgentsMenu.tla; AgentsMenu, openMenu,
# moveMenu, submitMenu, backMenu, closeMenu, searchChanged, pressCloseKey, and
# switchList in src/core/app/app_agents_runtime.zig) with TLC and require each
# config's expected verdict.
#
# agents-menu.cfg and agents-menu-three.cfg (with the environment and
# searches) and agents-menu-drive.cfg (the world spec-to-binary.ts drives) are
# the design and must pass. Each agents-menu-mutation-*.cfg plants one bug,
# and the rule it names must catch it:
#
#   move-only      a move changes only the highlight (fx before)    PreviewOnMove
#   search-stays   a search edit moves the highlight unseen          PreviewOnSearch
#   up-stays       Up on the first row stays there                   UpOnTopCloses
#   close-parent   a close of the shown agent shows its instance     CloseShowsRowAbove
#   back-stays     Esc keeps the agent shown                         BackToOrigin
#   paste-back     a paste goes back to the agent the list opened on ScreenOnlyOnKeys
#   stale-origin   a closed agent stays the one Esc goes back to     OriginListed
#   enter-noop     Enter closes the list without showing the row     EnterShowsSelection
#   open-first     the list opens on its first row                   OpensOnScreen
#   row            the highlight stays on its row, not its agent     SelectionKept
#   stale-sel      the highlight stays on an agent that closed       SelListed
#   run-closes     a run of a close key that edited the search goes
#                  on to arm and close a row (fx before the run)     RunNeverCloses
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
#   ./check.sh agents-menu agents-menu-mutation-move-only
set -eu
cd "$(dirname "$0")/spec"
. ../../lib/tlc.sh
tlc_verdicts "$@" <<'VERDICTS'
MCAgentsMenu agents-menu -
MCAgentsMenu agents-menu-three -
MCAgentsMenu agents-menu-drive -
MCAgentsMenu agents-menu-mutation-move-only PreviewOnMove
MCAgentsMenu agents-menu-mutation-search-stays PreviewOnSearch
MCAgentsMenu agents-menu-mutation-up-stays UpOnTopCloses
MCAgentsMenu agents-menu-mutation-close-parent CloseShowsRowAbove
MCAgentsMenu agents-menu-mutation-back-stays BackToOrigin
MCAgentsMenu agents-menu-mutation-paste-back ScreenOnlyOnKeys
MCAgentsMenu agents-menu-mutation-stale-origin OriginListed
MCAgentsMenu agents-menu-mutation-enter-noop EnterShowsSelection
MCAgentsMenu agents-menu-mutation-open-first OpensOnScreen
MCAgentsMenu agents-menu-mutation-row SelectionKept
MCAgentsMenu agents-menu-mutation-stale-sel SelListed
MCAgentsMenu agents-menu-mutation-run-closes RunNeverCloses
VERDICTS
