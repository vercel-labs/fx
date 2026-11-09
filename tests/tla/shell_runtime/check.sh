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
# read error (terminal-revoke-today-eio, ReadErrorOnlyWhenLive). The team
# picker and the masked key prompt restore the terminal on the way out too.
# The terminal-revoke-today-prompts* configs are fx with the shell's fix and
# without theirs, where those restores still went through the strict
# tcsetattr: a closed descriptor reached its unreachable
# (terminal-revoke-today-prompts, CleanupNeverCrashes), and ENOENT from a
# revoked terminal was an unexpected errno (terminal-revoke-today-prompts-errno,
# GoneQuietly). The terminal-revoke-today-picker* configs are fx with every
# restore fixed and the team picker still taking a read of 0, the end of input
# on a revoked terminal, as a key to ignore: it read again at once and never
# ended (terminal-revoke-today-picker, NoReadAfterEof, and
# terminal-revoke-today-picker-liveness, GoneEndsLoop). The sign-in wait of
# fx login vercel is the fourth site. Its wait for a key polls stdin in slices
# of 100 ms and used to return at once on a poll that answered POLLHUP,
# POLLERR, or POLLNVAL without POLLIN, so a terminal that macOS revoked while
# fx was in a request to the issuer, which leaves every later poll answering
# POLLNVAL alone, sent it round its loop at full CPU. The
# terminal-revoke-today-sign-in config is fx with every other fix and without
# that one (NoBusyLoop); the fixed wait sleeps out its slice and the sign-in
# goes on polling the issuer. The paste wait of fx mcp login --no-browser is
# the fifth site. A read of stdin that failed returned at once, so a terminal
# that polled readable and failed every read, as macOS 15 answers for a
# revoked one, sent the wait round its loop at full CPU until the login's own
# deadline. The terminal-revoke-today-mcp-login config is fx with every other
# fix and without that one (NoBusyLoop), and terminal-revoke-today-mcp-login-eof
# holds the same fx to the end-of-input law (GoneReadStopsLogin): a failed read
# on a terminal that is gone ends the wait with status 1. Each
# terminal-revoke-mutation-*.cfg plants one defect, and the rule it names must
# catch it:
#
#   nval-ignored           POLLNVAL is not counted as closed input          NoBusyLoop
#   badf-unreachable       EBADF from the restore aborts fx                 CleanupNeverCrashes
#   enoent-unexpected      ENOENT from a revoked terminal is an error       GoneQuietly
#   no-eintr-retry         a restore that EINTR interrupts is not retried   RestoredWhenLive
#   eio-always-eof         every EIO read ends input, without the check     InputClosedOnlyWhenGone
#   eio-poll-only          the check asks poll and not tcgetattr            ReadErrorOnlyWhenLive
#   sign-in-nval           the sign-in wait misses POLLNVAL alone           NoBusyLoop
#   mcp-login-ends-always  every failed read ends the paste wait            InputClosedOnlyWhenGone
#   mcp-login-sleeps       a failed read on a gone terminal only sleeps     GoneReadStopsLogin
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
TerminalRevoke terminal-revoke-today-prompts CleanupNeverCrashes
TerminalRevoke terminal-revoke-today-prompts-errno GoneQuietly
TerminalRevoke terminal-revoke-today-picker NoReadAfterEof
TerminalRevoke terminal-revoke-today-picker-liveness temporal
TerminalRevoke terminal-revoke-today-sign-in NoBusyLoop
TerminalRevoke terminal-revoke-today-mcp-login NoBusyLoop
TerminalRevoke terminal-revoke-today-mcp-login-eof GoneReadStopsLogin
TerminalRevoke terminal-revoke-mutation-nval-ignored NoBusyLoop
TerminalRevoke terminal-revoke-mutation-badf-unreachable CleanupNeverCrashes
TerminalRevoke terminal-revoke-mutation-enoent-unexpected GoneQuietly
TerminalRevoke terminal-revoke-mutation-no-eintr-retry RestoredWhenLive
TerminalRevoke terminal-revoke-mutation-eio-always-eof InputClosedOnlyWhenGone
TerminalRevoke terminal-revoke-mutation-eio-poll-only ReadErrorOnlyWhenLive
TerminalRevoke terminal-revoke-mutation-sign-in-nval NoBusyLoop
TerminalRevoke terminal-revoke-mutation-mcp-login-ends-always InputClosedOnlyWhenGone
TerminalRevoke terminal-revoke-mutation-mcp-login-sleeps GoneReadStopsLogin
VERDICTS
