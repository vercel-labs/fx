#!/bin/sh
# Model-check custom model connections (src/core/config/configured_provider.zig
# and the adapters in src/gateway/) with TLC and require each config's expected
# verdict.
#
# ConfiguredRequest.tla: which effort level and request fields reach the wire,
# the notice for an effort the model does not offer, and the one resend of a
# reply that ran out of output tokens. configured-request.cfg and
# configured-request-deep.cfg are the design and must pass.
# configured-request-today.cfg is fx before the change, where a level a custom
# model declares was never sent (ConfiguredEffortSent). Each
# configured-request-mutation-*.cfg plants one defect, and the rule it names
# must catch it:
#
#   owned-key            a fragment replaces a field fx owns          OwnedKeysKeepFxValue
#   undeclared-effort    a level the model does not declare is sent   EffortOnlyWhenDeclared
#   request-beats-level  the model's own field wins over the level's  LevelBeatsRequest
#   silent-drop          an ignored effort is dropped without a word  IgnoredEffortNoticed
#   notice-repeats       the notice shows on every turn               NoticeOncePerSession
#   notice-always        the notice shows for an effort that is sent  NoticeOnlyWhenIgnored
#   wrong-limit-field    the limit always travels as max_tokens       LimitInConfiguredField
#   resend-same          a resend repeats the request                 ResendDiffers
#   resend-again         a resend's own reply is resent               NoResendOfResend
#
# ConfiguredCatalog.tla: the model list, with the server's own list fetched
# only when the connection's settings ask for it. configured-catalog.cfg is the
# design. configured-catalog-today.cfg is fx before the change, which never
# asked the server (FetchOnAsks).
#
#   probe-when-off      a connection that did not ask is probed         NoRequestWhenOff
#   wrong-token         a token goes to another connection              TokenStaysWithItsConnection
#   stale-reply         a reply for a connection the person left lands  ShownBelongsToSelected
#   drop-declared       the server's list replaces the declared models  DeclaredAlwaysShown
#   failure-keeps-list  a failed refresh keeps the server's old list  FallbackIsDeclared
#   silent-failure      a failure shows no line                         FailureSaysSo
#   no-deadline         a request waits forever on a silent server      RequestSettles
#
# ConfiguredDeadlines.tla: how long one request waits to connect, for the first
# response, and for the next bytes. configured-deadlines.cfg is the design.
# The two today configs are fx before the change: its built-in bounds wait too
# long for a connection that asked for less (NeverPastConfigured), and give up
# on a local model that needs longer (NeverBeforeConfigured).
#
#   early                        a wait ends one tick early            NeverBeforeConfigured
#   stall-counts-whole-response  the stall bound times the whole reply NeverBeforeConfigured
#   no-stall-bound               a silent response is never given up   NeverPastConfigured
#   unnamed-failure              a timeout does not say which wait     FailureNamesItsWait
#
# tests/tla/drivers/configured_provider/driver.ts runs the built fx along
# these models.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh configured-request configured-catalog-mutation-stale-reply
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu
cd "$(dirname "$0")"
. ../lib/tlc.sh
tlc_verdicts "$@" <<'VERDICTS'
ConfiguredRequest configured-request -
ConfiguredRequest configured-request-deep -
ConfiguredRequest configured-request-today ConfiguredEffortSent
ConfiguredRequest configured-request-mutation-owned-key OwnedKeysKeepFxValue
ConfiguredRequest configured-request-mutation-undeclared-effort EffortOnlyWhenDeclared
ConfiguredRequest configured-request-mutation-request-beats-level LevelBeatsRequest
ConfiguredRequest configured-request-mutation-silent-drop IgnoredEffortNoticed
ConfiguredRequest configured-request-mutation-notice-repeats NoticeOncePerSession
ConfiguredRequest configured-request-mutation-notice-always NoticeOnlyWhenIgnored
ConfiguredRequest configured-request-mutation-wrong-limit-field LimitInConfiguredField
ConfiguredRequest configured-request-mutation-resend-same ResendDiffers
ConfiguredRequest configured-request-mutation-resend-again NoResendOfResend

ConfiguredCatalog configured-catalog -
ConfiguredCatalog configured-catalog-today FetchOnAsks
ConfiguredCatalog configured-catalog-mutation-probe-when-off NoRequestWhenOff
ConfiguredCatalog configured-catalog-mutation-wrong-token TokenStaysWithItsConnection
ConfiguredCatalog configured-catalog-mutation-stale-reply ShownBelongsToSelected
ConfiguredCatalog configured-catalog-mutation-drop-declared DeclaredAlwaysShown
ConfiguredCatalog configured-catalog-mutation-failure-keeps-list FallbackIsDeclared
ConfiguredCatalog configured-catalog-mutation-silent-failure FailureSaysSo
ConfiguredCatalog configured-catalog-mutation-no-deadline temporal

ConfiguredDeadlines configured-deadlines -
ConfiguredDeadlines configured-deadlines-today NeverPastConfigured
ConfiguredDeadlines configured-deadlines-today-slow-server NeverBeforeConfigured
ConfiguredDeadlines configured-deadlines-mutation-early NeverBeforeConfigured
ConfiguredDeadlines configured-deadlines-mutation-stall-counts-whole-response NeverBeforeConfigured
ConfiguredDeadlines configured-deadlines-mutation-no-stall-bound NeverPastConfigured
ConfiguredDeadlines configured-deadlines-mutation-unnamed-failure FailureNamesItsWait
VERDICTS
