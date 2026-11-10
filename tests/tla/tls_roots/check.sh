#!/bin/sh
# Model-check how fx loads trusted roots for an HTTPS client
# (src/core/shared/tls_roots.zig) with TLC and require each config's expected
# verdict.
#
# tls-roots.cfg is the design and must pass. tls-roots-today.cfg is fx before
# it, where a sandbox that denies the System keychain failed every request
# although /etc/ssl/cert.pem was readable (NoFailureWhileRootsReadable). Each
# tls-roots-mutation-*.cfg plants one defect, and the rule it names must catch
# it:
#
#   keep-partial   the public bundle is added to a partial scan    OneSource
#   any-error      any scan error falls back, not only a denial    FallbackOnlyOnDenial
#   any-os         the fallback runs on systems other than macOS   FallbackOnlyOnDenial
#   accept-empty   a public bundle with no roots is installed      InstalledNotEmpty
#   clock-first    the clock is set before the bundle is swapped   HandshakeHasRoots
#   skip-site      the MCP client keeps std's own scan             NoFailureWhileRootsReadable
#   skip-job       the open job's own client keeps std's own scan  NoFailureWhileRootsReadable
#
# TlsRootsTrace.tla checks runs of the built fx binary against the model;
# tests/tla/drivers/tls_roots/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh tls-roots tls-roots-mutation-keep-partial
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
TlsRoots tls-roots -
TlsRoots tls-roots-today NoFailureWhileRootsReadable
TlsRoots tls-roots-mutation-keep-partial OneSource
TlsRoots tls-roots-mutation-any-error FallbackOnlyOnDenial
TlsRoots tls-roots-mutation-any-os FallbackOnlyOnDenial
TlsRoots tls-roots-mutation-accept-empty InstalledNotEmpty
TlsRoots tls-roots-mutation-clock-first HandshakeHasRoots
TlsRoots tls-roots-mutation-skip-site NoFailureWhileRootsReadable
TlsRoots tls-roots-mutation-skip-job NoFailureWhileRootsReadable
VERDICTS
