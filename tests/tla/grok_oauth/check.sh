#!/bin/sh
# Model-check which account a Grok sign-in saves and whether a refresh keeps
# it (src/core/auth/grok_oauth.zig: completeSignIn, fetchAccountId,
# refreshSession, refreshReplacement) with TLC, and require each config's
# expected verdict.
#
# grok-identity.cfg is the design and must pass. The grok-identity-today*.cfg
# configs are fx before the fix, and the grok-identity-mutation-*.cfg configs
# each plant one defect. The rule each names must catch it:
#
#   today                  every account is named from userinfo, which
#                          refuses a Team token                           UsableSignInCompletes
#   today-refresh          the refresh form sends no principal, so a Team
#                          login comes back as the personal account        RefreshKeepsAccount
#   mutation-unvalidated   a Team principal_id is saved unchecked          SavedAccountValid
#   mutation-fields-always every principal's fields go into the refresh    PersonalRefreshOmitsFields
#   mutation-user-claim    a personal account is named from its claim      PersonalUsesUserinfo
#
# GrokIdentityTrace.tla checks runs of the built fx binary against the
# model; tests/tla/drivers/grok_oauth/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh grok-identity grok-identity-today
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
GrokIdentity grok-identity -
GrokIdentity grok-identity-today UsableSignInCompletes
GrokIdentity grok-identity-today-refresh RefreshKeepsAccount
GrokIdentity grok-identity-mutation-unvalidated SavedAccountValid
GrokIdentity grok-identity-mutation-fields-always PersonalRefreshOmitsFields
GrokIdentity grok-identity-mutation-user-claim PersonalUsesUserinfo
VERDICTS
