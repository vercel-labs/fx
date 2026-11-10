#!/bin/sh
# Model-check how fx gives memory that held a secret back to libc
# (SecretWipe.tla; secret.Wiping in src/core/auth/secret.zig, its callers in
# src/core/auth/, and the API key copy in src/napi_core_main.zig) with TLC,
# and require each config's expected verdict.
#
# secret-wipe.cfg and secret-wipe-deep.cfg are the design and must pass.
# secret-wipe-witness.cfg must find a block that held a secret going back
# to libc, so the design passes with secrets in play. secret-wipe-head.cfg
# is the design before the Keychain read joined it: the reply buffer of
# std.process.run keeps the caller's allocator, so a realloc that moves it
# gives the old block back unwiped, and NoSecretMoved must catch that.
# secret-wipe-today.cfg is fx before
# secret.Wiping, whose std.json arenas, request bodies, saved sessions,
# Keychain replies, and API key copy reach libc unwiped. Each
# secret-wipe-mutation-*.cfg plants one defect, and NoSecretReleased must
# catch it:
#
#   free-no-wipe       Wiping.free gives a block back unwiped
#   remap-moves        Wiping.remap lets libc's realloc move a block
#   shrink-keeps-tail  Wiping.resize lets a block shrink in place, keeping the bytes past the slice
#   parse-unwrapped    a parse keeps the caller's allocator
#   writer-unwrapped   a request body or session writer keeps the caller's allocator
#   reply-plain-free   a Keychain reply is wrapped, but the answer it returns is released with a plain free
#   napi-plain-free    the libfx API key copy is released with a plain free
#
# SecretWipeTrace.tla checks runs of the built fx binary against the model;
# tests/tla/drivers/secret/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh secret-wipe secret-wipe-today
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
SecretWipe secret-wipe -
SecretWipe secret-wipe-deep -
SecretWipe secret-wipe-witness NoSecretEverHeld
SecretWipe secret-wipe-head NoSecretMoved
SecretWipe secret-wipe-today NoSecretReleased
SecretWipe secret-wipe-mutation-free-no-wipe NoSecretReleased
SecretWipe secret-wipe-mutation-remap-moves NoSecretReleased
SecretWipe secret-wipe-mutation-shrink-keeps-tail NoSecretReleased
SecretWipe secret-wipe-mutation-parse-unwrapped NoSecretReleased
SecretWipe secret-wipe-mutation-writer-unwrapped NoSecretReleased
SecretWipe secret-wipe-mutation-reply-plain-free NoSecretReleased
SecretWipe secret-wipe-mutation-napi-plain-free NoSecretReleased
VERDICTS
