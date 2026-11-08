#!/bin/sh
# Model-check the agent step loop's models with TLC and require each config's
# expected verdict.
#
# EmptyReply.tla is the empty-reply nudge (src/core/agent/runtime/orchestrator.zig).
# empty-reply.cfg and empty-reply-deep.cfg are the design and must pass.
# empty-reply-today.cfg is fx before it, which ended an empty reply that
# stopped for `other` with "Done." (EverySeparateEmptyNudged). Each
# empty-reply-mutation-*.cfg plants one defect, and the rule it names must
# catch it:
#
#   no-reset          a nudge flag that survives a step that made progress  EverySeparateEmptyNudged
#   double-nudge      a nudge sent again for the reply to a nudge           NoDoubleNudge
#   ignore-limit      a nudge sent with no step left                        StepsBounded
#   placeholder       a second empty reply ends with "Done."                NoPlaceholder
#   nudge-text        a reply with text that stops for other is nudged      NudgeOnlyAfterEmptyOther
#   summarize-first   "Summarize what you just did." sent instead           EverySeparateEmptyNudged
#
# ResponseLanguage.tla is the response language guard
# (src/core/agent/runtime/response_language.zig). response-language.cfg is the
# design and must pass. response-language-today.cfg is fx before the fix of
# #809, which rejected the reply to a non-English request that quoted English
# (RequestedLanguageAccepted). response-language-first-cut.cfg is the first fix
# of #809, whose letter scan stopped at a cut-short lead byte and ignored
# combining accents, and whose word list held words that other languages use
# (RequestedLanguageAccepted). response-language-limit.cfg adds requests that
# run into the English with no punctuation, or share only "the" or "that" with
# it, which the guard still misreads (RequestedLanguageAccepted). Each
# response-language-mutation-*.cfg plants one defect, and the rule it names
# must catch it:
#
#   accent-only       only an accented letter makes the guard abstain       RequestedLanguageAccepted
#   cut-hides         the letter scan stops at a cut-short lead byte        RequestedLanguageAccepted
#   marks-ignored     a combining accent is not an accent                   RequestedLanguageAccepted
#   shared-hides      the word list has words other languages use           RequestedLanguageAccepted
#   abstain-all       the guard never expects a script                      EnglishGuardKept
#   retry-twice       no cap on corrections                                 OneCorrection
#   tools-reject      a reply with tool calls is replaced                   CallsKept
#
# EmptyReplyTrace.tla and ResponseLanguageTrace.tla check turns of the built fx
# binary against the models; tests/tla/drivers/agent_runtime/driver.ts and
# tests/tla/drivers/agent_runtime/response_language.ts run them.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh empty-reply empty-reply-mutation-no-reset
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
EmptyReply empty-reply -
EmptyReply empty-reply-deep -
EmptyReply empty-reply-today EverySeparateEmptyNudged
EmptyReply empty-reply-mutation-no-reset EverySeparateEmptyNudged
EmptyReply empty-reply-mutation-double-nudge NoDoubleNudge
EmptyReply empty-reply-mutation-ignore-limit StepsBounded
EmptyReply empty-reply-mutation-placeholder NoPlaceholder
EmptyReply empty-reply-mutation-nudge-text NudgeOnlyAfterEmptyOther
EmptyReply empty-reply-mutation-summarize-first EverySeparateEmptyNudged
ResponseLanguage response-language -
ResponseLanguage response-language-today RequestedLanguageAccepted
ResponseLanguage response-language-first-cut RequestedLanguageAccepted
ResponseLanguage response-language-limit RequestedLanguageAccepted
ResponseLanguage response-language-mutation-accent-only RequestedLanguageAccepted
ResponseLanguage response-language-mutation-cut-hides RequestedLanguageAccepted
ResponseLanguage response-language-mutation-marks-ignored RequestedLanguageAccepted
ResponseLanguage response-language-mutation-shared-hides RequestedLanguageAccepted
ResponseLanguage response-language-mutation-abstain-all EnglishGuardKept
ResponseLanguage response-language-mutation-retry-twice OneCorrection
ResponseLanguage response-language-mutation-tools-reject CallsKept
VERDICTS
