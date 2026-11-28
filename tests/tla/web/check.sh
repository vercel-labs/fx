#!/bin/sh
# Model-check which addresses one web_fetch hop may dial (FetchAdmission.tla;
# fetch in src/tools/web/http_fetch.zig and isPublicAddress in
# src/tools/web/url_policy.zig) with TLC and require each config's expected
# verdict.
#
# fetch-admission.cfg is the design and must pass: a 64:ff9b::/96 address is
# judged by the IPv4 address in its last 32 bits. fetch-admission-today.cfg is
# fx before it, which refused every NAT64 address and so every fetch on a
# DNS64 network (issue #1184, PublicHostAdmitted). Each
# fetch-admission-mutation-*.cfg plants one defect, and the rule it names must
# catch it:
#
#   no-embedded-check  every 64:ff9b::/96 address admitted               NoUnsafeDial
#   loose-prefix       64:ff9b::/32 matched, so 64:ff9b:1::/48 admitted  NoUnsafeDial
#   compat             IPv4-compatible and IPv4-mapped judged by tail    AdmittedForms
#   any-answer         a hop admitted when one answer is public          EveryAnswerSafe
#
# FetchAdmissionTrace.tla checks hops of the real code against the model;
# tests/tla/drivers/web/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh fetch-admission fetch-admission-mutation-loose-prefix
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
FetchAdmission fetch-admission -
FetchAdmission fetch-admission-today PublicHostAdmitted
FetchAdmission fetch-admission-mutation-no-embedded-check NoUnsafeDial
FetchAdmission fetch-admission-mutation-loose-prefix NoUnsafeDial
FetchAdmission fetch-admission-mutation-compat AdmittedForms
FetchAdmission fetch-admission-mutation-any-answer EveryAnswerSafe
VERDICTS
