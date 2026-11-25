#!/bin/sh
# Model-check one shell call through a sandbox provider with TLC, and
# require each config's expected verdict.
#
# sandbox-provider.cfg is the design and must pass. grace-today.cfg is fx's
# stop today, whose 700 ms grace is shorter than one remote kill, and it must
# fail. Each mutation-*.cfg plants one defect, and the rule it names must
# catch it:
#
#   local-fallback       a placed call whose provider cannot be used runs here   NoLocalFallback
#   grant-any-placement  any grant for the command admits any placement          GrantPerPlacement
#   tty-placed           a terminal call goes to the provider                    TtyNeverPlaced
#   isolated-keys        an isolated run gets the configured env                 IsolatedNoKeys
#   overwrite-local      a changed file comes back over a local edit             NoLostLocalEdit
#   trust-missing        a missing report reads as did not run                   HonestResult
#   no-timeout           the remote command has no timeout                       OrphanBounded
#   skip-cleanup         an isolated create skips the cleanup of a crashed run   IsolatedCleanedUp
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh sandbox-provider mutation-no-timeout
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
SandboxProvider sandbox-provider -
SandboxProvider sandbox-isolated -
SandboxProvider grace-today NoOrphanAfterStop
SandboxProvider mutation-local-fallback NoLocalFallback
SandboxProvider mutation-grant-any-placement GrantPerPlacement
SandboxProvider mutation-tty-placed TtyNeverPlaced
SandboxProvider mutation-isolated-keys IsolatedNoKeys
SandboxProvider mutation-overwrite-local NoLostLocalEdit
SandboxProvider mutation-trust-missing HonestResult
SandboxProvider mutation-no-timeout OrphanBounded
SandboxProvider mutation-skip-cleanup IsolatedCleanedUp
VERDICTS
