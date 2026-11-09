#!/bin/sh
# Model-check PromptCache with TLC and require each config's expected verdict.
#
# PromptCache: how fx lays out a model request
# (src/core/agent/runtime/prompt_context.zig, orchestrator.zig
# appendStablePromptContext) and how an explicit-caching provider reuses it
# through AI Gateway with caching "auto". proposed.cfg is fx: the two stable
# markers and workspace-relative paths in the skill catalog and project rules;
# it and current-holds.cfg must pass. Each current-*.cfg shows a reuse fx missed
# before the markers. gap-history.cfg shows reuse the markers cannot give: the
# turn context sits ahead of the history. Each mutant-*.cfg plants a known-bad
# design that its property must catch; mutant-absolute-paths.cfg is the
# absolute paths fx sent before, which no worktree of the same repository reuses.
#
# p6-remind.cfg and p6-openai-remind.cfg add the reminder a later turn puts on a
# tool result that reaches a folder again; p6-mutant-remind-old-result.cfg puts it
# on the result that carried the rules instead, which PreviousFullyReused catches.
#
# p6-resume.cfg and p6-openai-resume.cfg add the notice a resumed turn carries when
# fx restarted with shell handles in the history; p6-mutant-stale-in-instructions.cfg
# puts it in the instructions, as fx did, which MidSessionKeepsHistory catches.
# p6-overlay.cfg and p6-openai-overlay.cfg add outside changes: the turn context and
# runtime block stay as the session started and a change rides on the message where fx
# noticed it. p6-mutant-overlay-rebuilt.cfg follows the current values on every request,
# as fx did, and p6-mutant-overlay-not-saved.cfg recaptures them when fx restarts;
# MidSessionKeepsHistory catches both. p6-implicit-context.cfg checks that
# with a change carried on a message, even a family fx sends no markers to
# reads the stable instructions after it, which openai-current-context.cfg
# shows fx did not before.
#
# The openai-*.cfg configs check the same designs under OpenAI GPT-5.6 and later
# rules (Family = "openai"). openai-mutant-explicit-only.cfg is the agent request
# in explicit-only cache mode, which drops in-session reuse.
#
# Run the real binary and have TLC replay its requests:
#   bun test ../drivers/prompt_context/
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOT'
MCPromptCache proposed - -deadlock
MCPromptCache current-holds - -deadlock
MCPromptCache current-cross-repo CrossRepoReuse -deadlock
MCPromptCache current-same-worktree SameWorktreeReuse -deadlock
MCPromptCache current-context ContextChangeKeepsStable -deadlock
MCPromptCache gap-history ContextChangeKeepsHistory -deadlock
MCPromptCache mutant-every-system Budget -deadlock
MCPromptCache mutant-fence-after-context SameWorktreeReuse -deadlock
MCPromptCache mutant-no-auto SessionReuse -deadlock
MCPromptCache mutant-absolute-paths WorktreeReuse -deadlock
MCPromptCache openai-proposed - -deadlock
MCPromptCache openai-current-holds - -deadlock
MCPromptCache openai-current-cross-repo CrossRepoReuse -deadlock
MCPromptCache openai-current-same-worktree SameWorktreeReuse -deadlock
MCPromptCache openai-current-context ContextChangeKeepsStable -deadlock
MCPromptCache openai-mutant-every-system Budget -deadlock
MCPromptCache openai-mutant-fence-after-context SameWorktreeReuse -deadlock
MCPromptCache openai-mutant-explicit-only SessionReuse -deadlock
MCPromptCache p6-proposed - -deadlock
MCPromptCache p6-proposed-sessions - -deadlock
MCPromptCache p6-openai-proposed - -deadlock
MCPromptCache p6-openai-proposed-sessions - -deadlock
MCPromptCache p6-current-switch MidSessionKeepsHistory -deadlock
MCPromptCache p6-current-deliver MidSessionKeepsHistory -deadlock
MCPromptCache p6-current-skill MidSessionKeepsHistory -deadlock
MCPromptCache p6-openai-current-deliver MidSessionKeepsHistory -deadlock
MCPromptCache p6-mutant-note-not-saved MidSessionKeepsHistory -deadlock
MCPromptCache p6-mutant-contract-late ContextChangeKeepsStable -deadlock
MCPromptCache p6-note-claude MidSessionKeepsHistory -deadlock
MCPromptCache p6-note-openai PreviousFullyReused -deadlock
MCPromptCache p6-implicit-proposed - -deadlock
MCPromptCache p6-implicit-context - -deadlock
MCPromptCache p6-implicit-current-deliver MidSessionKeepsHistory -deadlock
MCPromptCache p6-remind - -deadlock
MCPromptCache p6-openai-remind - -deadlock
MCPromptCache p6-mutant-remind-old-result PreviousFullyReused -deadlock
MCPromptCache p6-resume - -deadlock
MCPromptCache p6-openai-resume - -deadlock
MCPromptCache p6-mutant-stale-in-instructions MidSessionKeepsHistory -deadlock
MCPromptCache p6-overlay - -deadlock
MCPromptCache p6-openai-overlay - -deadlock
MCPromptCache p6-mutant-overlay-rebuilt MidSessionKeepsHistory -deadlock
MCPromptCache p6-mutant-overlay-not-saved MidSessionKeepsHistory -deadlock
EOT
