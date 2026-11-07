#!/bin/sh
# Model-check what fx's input loop and terminal cleanup do when the terminal
# behind stdin goes away, and under job control (TerminalRevoke.tla;
# src/ui/event_loop.zig and src/ui/shell_runtime.zig pollInput, inputGone, and
# disableRawMode, which restores through tcsetattrBestEffort in
# src/core/shared/io.zig) with TLC and require each config's expected verdict.
#
# terminal-revoke.cfg is the design and must pass. The terminal-revoke-today*
# configs are fx before the change: a revoked terminal polls as POLLNVAL,
# which the loop dropped, so it polled again at once (NoBusyLoop) and never
# ended (GoneEndsLoop), and the restore of a closed descriptor reached
# std.posix.tcsetattr's unreachable (CleanupNeverCrashes). Where a revoked
# terminal fails reads with EIO, as macOS 15 answered, the loop reported the
# read error (terminal-revoke-today-eio, ReadErrorOnlyWhenLive). Each
# terminal-revoke-mutation-*.cfg plants one defect, and the rule it names must
# catch it:
#
#   nval-ignored       POLLNVAL is not counted as closed input        NoBusyLoop
#   badf-unreachable   EBADF from the restore aborts fx                CleanupNeverCrashes
#   enoent-unexpected  ENOENT from a revoked terminal is an error      GoneQuietly
#   no-eintr-retry     a restore that EINTR interrupts is not retried  RestoredWhenLive
#   eio-always-eof     every EIO read ends input, without the check    InputClosedOnlyWhenGone
#   eio-poll-only      the check asks poll and not tcgetattr           ReadErrorOnlyWhenLive
#
# TerminalRevokeTrace.tla checks runs of the built fx binary against the
# model; tests/tla/drivers/shell_runtime/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh terminal-revoke terminal-revoke-mutation-nval-ignored
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
TerminalRevoke terminal-revoke -
TerminalRevoke terminal-revoke-today NoBusyLoop
TerminalRevoke terminal-revoke-today-cleanup CleanupNeverCrashes
TerminalRevoke terminal-revoke-today-liveness temporal
TerminalRevoke terminal-revoke-today-eio ReadErrorOnlyWhenLive
TerminalRevoke terminal-revoke-mutation-nval-ignored NoBusyLoop
TerminalRevoke terminal-revoke-mutation-badf-unreachable CleanupNeverCrashes
TerminalRevoke terminal-revoke-mutation-enoent-unexpected GoneQuietly
TerminalRevoke terminal-revoke-mutation-no-eintr-retry RestoredWhenLive
TerminalRevoke terminal-revoke-mutation-eio-always-eof InputClosedOnlyWhenGone
TerminalRevoke terminal-revoke-mutation-eio-poll-only ReadErrorOnlyWhenLive
VERDICTS
