#!/bin/sh
# Model-check the shell snapshot and terminal lifecycle designs with TLC and
# require each config's expected verdict.
#
# ShellSnapshot: the in-memory owner of a captured shell environment
# (src/core/terminal/shell_snapshot.zig), shared by the root agent and every
# subagent: single-flight capture, leases, refresh, and approval epochs.
# TerminalLifecycle: hosted terminal processes across fx exits and crashes, the
# steps of the exit close (record the tree, hang up, kill, bounded drain) and
# what holds the PTY meanwhile, and a start whose caller has not indexed the
# terminal yet, which the other calls of its process must not see.
# CI runs only the design config TerminalLifecycle.cfg, which has one terminal
# (about 8,000 states, a few seconds). TerminalLifecycle-full.cfg has two
# (about 486,000 states, a few minutes) and runs here, with the planted
# mutants, which keep two terminals and are rejected with one as well.
# ShellSnapshotCapture: what one capture keeps (`_` helpers, not completion
# functions or fx's own names) and which startup-file edits make it stale,
# ZDOTDIR moves included (src/core/terminal/shell_resolver.zig and
# shell_snapshot.zig). A capture takes time, and an edit can land inside it.
# Its runs are bounded, so its checks skip deadlock checking. old_filter is fx
# before it kept `_` helpers; old_watch and old_restore are fx before the
# ZDOTDIR change; old_stamp is fx before the capture-start rule for the moved
# folder; old_failed is fx before the failed state compared like with like;
# old_unbounded is fx before the bound on the captures one command starts;
# zero_bound is a bound that never captures; full_witness is not a rule: it
# shows a command does run with the full startup once the bound is reached;
# tests/tla/drivers/terminal/capture.ts runs the built binary along it.
#
# Each design config must pass every invariant and liveness property with
# deadlock checking on. Each <Model>-<mutation>.cfg enables one broken rule,
# checks safety only, and must be rejected by the named invariant.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
ShellSnapshot ShellSnapshot -
ShellSnapshot ShellSnapshot-one_session -
TerminalLifecycle TerminalLifecycle -
TerminalLifecycle TerminalLifecycle-full -
ShellSnapshot ShellSnapshot-reload_per_command DotfilesPaidOnce -deadlock
ShellSnapshot ShellSnapshot-no_single_flight SingleFlight -deadlock
ShellSnapshot ShellSnapshot-free_while_leased NoUseAfterFree -deadlock
ShellSnapshot ShellSnapshot-use_partial RunsCompleteSnapshot -deadlock
ShellSnapshot ShellSnapshot-stale_grant GrantMatchesEpoch -deadlock
ShellSnapshot ShellSnapshot-recheck_restamps ApprovalMatchesAnswer -deadlock
ShellSnapshot ShellSnapshot-stamp_at_answer ApprovalMatchesAnswer -deadlock
ShellSnapshot ShellSnapshot-store_stamps_current StoredGrantMatchesAnswer -deadlock
ShellSnapshot ShellSnapshot-shared_command_epoch AdmissionUsesCurrentEpoch -deadlock
ShellSnapshot ShellSnapshot-notice_repeat NoticeOncePerEpisode -deadlock
ShellSnapshot ShellSnapshot-clear_dirty_late FreshWhenClean -deadlock
ShellSnapshot ShellSnapshot-keep_broken NoReuseOfBroken -deadlock
ShellSnapshot ShellSnapshot-one_session-reload_per_command DotfilesPaidOnce -deadlock
ShellSnapshot ShellSnapshot-one_session-no_single_flight SingleFlight -deadlock
ShellSnapshot ShellSnapshot-one_session-free_while_leased NoUseAfterFree -deadlock
ShellSnapshot ShellSnapshot-one_session-use_partial RunsCompleteSnapshot -deadlock
ShellSnapshot ShellSnapshot-one_session-stale_grant GrantMatchesEpoch -deadlock
ShellSnapshot ShellSnapshot-one_session-recheck_restamps ApprovalMatchesAnswer -deadlock
ShellSnapshot ShellSnapshot-one_session-store_stamps_current StoredGrantMatchesAnswer -deadlock
ShellSnapshot ShellSnapshot-one_session-notice_repeat NoticeOncePerEpisode -deadlock
ShellSnapshot ShellSnapshot-one_session-clear_dirty_late FreshWhenClean -deadlock
ShellSnapshot ShellSnapshot-one_session-keep_broken NoReuseOfBroken -deadlock
TerminalLifecycle TerminalLifecycle-daemon_survives OrphansOnlyAfterCrash -deadlock
TerminalLifecycle TerminalLifecycle-exit_skips_close OrphansOnlyAfterCrash -deadlock
TerminalLifecycle TerminalLifecycle-profile_wide_recover NoWrongEnd -deadlock
TerminalLifecycle TerminalLifecycle-reattach NoBadInteract -deadlock
TerminalLifecycle TerminalLifecycle-list_in_flight NoIndexBeforeStartReturns -deadlock
TerminalLifecycle TerminalLifecycle-end_at_return NoIndexBeforeStartReturns -deadlock
TerminalLifecycle TerminalLifecycle-record_once NoHolderAfterCleanExit -deadlock
TerminalLifecycle TerminalLifecycle-launcher_wait NoHolderAfterCleanExit -deadlock
TerminalLifecycle TerminalLifecycle-early_reap NoHolderAfterCleanExit -deadlock
ShellSnapshotCapture ShellSnapshotCapture - -deadlock
ShellSnapshotCapture ShellSnapshotCapture-old_filter HelpersCallable -deadlock
ShellSnapshotCapture ShellSnapshotCapture-old_watch FreshAfterEdit -deadlock
ShellSnapshotCapture ShellSnapshotCapture-old_restore ZdotdirAsLogin -deadlock
ShellSnapshotCapture ShellSnapshotCapture-old_stamp CurrentIsFresh -deadlock
ShellSnapshotCapture ShellSnapshotCapture-old_failed FailedChangeIsReal -deadlock
ShellSnapshotCapture ShellSnapshotCapture-keep_completion CompletionStaysOut -deadlock
ShellSnapshotCapture ShellSnapshotCapture-keep_private FxPrivateOut -deadlock
ShellSnapshotCapture ShellSnapshotCapture-no_restore ZdotdirAsLogin -deadlock
ShellSnapshotCapture ShellSnapshotCapture-restore_exported ZdotdirAsLogin -deadlock
ShellSnapshotCapture ShellSnapshotCapture-old_unbounded CapturesBounded -deadlock
ShellSnapshotCapture ShellSnapshotCapture-zero_bound FullOnlyAfterRecapture -deadlock
ShellSnapshotCapture ShellSnapshotCapture-full_witness NoFullRun -deadlock
EOF
