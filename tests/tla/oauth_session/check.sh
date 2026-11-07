#!/bin/sh
# Model-check the fx login's refresh lock across fx profiles
# (src/core/auth/oauth_session.zig lockMutation) with TLC and require each
# config's expected verdict.
#
# keychain-lock.cfg and keychain-lock-deep.cfg are the design and must pass:
# with the Keychain, every profile takes ~/.fx/auth.lock. keychain-lock-file.cfg
# is the profile-file backend, which keeps its lock in the profile, and must
# pass. keychain-lock-runtime.cfg shows a per-user folder outside ~/.fx would
# hold too while no older fx runs.
#
# These must fail on the rule named:
#
#   today               each profile locks its own folder (fx before)       NoValidLoginDeleted
#   today-overlap       the same, seen as two holders of one login's lock   OneRefresher
#   runtime-old         a per-user folder outside ~/.fx, with an older fx
#                       in the default profile still locking ~/.fx          OneRefresher
#   mutation-load-early the login loaded before the lock is taken           NoReuse
#   mutation-file-shares the profile-file backend takes the ~/.fx lock      FileLockStaysInProfile
#
# And two findings, which the change leaves as they were:
#
#   fallback   HOME not absolute, or ~/.fx unusable: the profile's lock     NoValidLoginDeleted
#   old-moved  an older fx in a profile FX_HOME moved locks that profile    NoValidLoginDeleted
#
# KeychainLockTrace.tla checks runs of the real code against these rules;
# tests/tla/drivers/oauth_session/driver.ts runs them.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh keychain-lock keychain-lock-today
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
KeychainLock keychain-lock -
KeychainLock keychain-lock-deep -
KeychainLock keychain-lock-file -
KeychainLock keychain-lock-runtime -
KeychainLock keychain-lock-today NoValidLoginDeleted
KeychainLock keychain-lock-today-overlap OneRefresher
KeychainLock keychain-lock-runtime-old OneRefresher
KeychainLock keychain-lock-mutation-load-early NoReuse
KeychainLock keychain-lock-mutation-file-shares FileLockStaysInProfile
KeychainLock keychain-lock-fallback NoValidLoginDeleted
KeychainLock keychain-lock-old-moved NoValidLoginDeleted
VERDICTS
