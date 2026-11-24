#!/bin/sh
# Model-check the empty-reply nudge, the malformed tool call feedback, and the
# response language guard in the agent step loop (src/core/agent/runtime/orchestrator.zig
# and response_language.zig) with TLC and require each config's expected verdict.
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
# (RequestedLanguageAccepted). response-language-second-cut.cfg is the second
# fix, whose contraction rule took "Can'a" for English and whose clause
# splitter knew only ASCII spaces (RequestedLanguageAccepted). The third fix
# is the mutation break-hides below: only LF ended a clause.
# response-language-limit.cfg adds requests that run into the English with no
# punctuation, have only clauses of fewer than three words, have a stray
# backtick, or share only "the", "that", or a capital "I" with it, which the
# guard still misreads (RequestedLanguageAccepted). Each
# response-language-mutation-*.cfg plants one defect, and the rule it names
# must catch it:
#
#   accent-only       only an accented letter makes the guard abstain       RequestedLanguageAccepted
#   cut-hides         the letter scan stops at a cut-short lead byte        RequestedLanguageAccepted
#   marks-ignored     a combining accent is not an accent                   RequestedLanguageAccepted
#   shared-hides      the word list has words other languages use           RequestedLanguageAccepted
#   stem-hides        a contraction stem counts before any ending           RequestedLanguageAccepted
#   space-hides       only ASCII spaces split words                         RequestedLanguageAccepted
#   break-hides       a line break other than LF ends no clause             RequestedLanguageAccepted
#   abstain-all       the guard never expects a script                      EnglishGuardKept
#   retry-twice       no cap on corrections                                 OneCorrection
#   tools-reject      a reply with tool calls is replaced                   CallsKept
#
# EmptyReplyTrace.tla and ResponseLanguageTrace.tla check turns of the built fx
# binary against the models; tests/tla/drivers/agent_runtime/driver.ts and
# tests/tla/drivers/agent_runtime/response_language.ts run them.
#
# malformed-tool-call.cfg and malformed-tool-call-deep.cfg are the design of
# the feedback after a reply that ends with MALFORMED_FUNCTION_CALL and must
# pass. malformed-tool-call-today.cfg is fx before it, which waited and resent
# such a reply as a server failure (EveryStallGetsFeedback). Each
# malformed-tool-call-mutation-*.cfg plants one defect, and the rule it names
# must catch it:
#
#   no-cap            a third feedback in one step                          EndsAfterThird
#   backoff           feedback waits the backoff                            FeedbackRightAway
#   tools-off         feedback goes with tools off                          FeedbackKeepsTools
#   no-reset          the malformed count survives a step                   EveryStallGetsFeedback
#   run-call          a malformed reply's call runs                         MalformedNeverRuns
#   reconcile-loop    a malformed reply with tools off is resent            ReconcileMalformedStops
#   search-reconcile  a failed search start turns tools off                 SearchKeepsTools
#
# MalformedToolCallTrace.tla checks turns of the built fx binary against that
# model; tests/tla/drivers/agent_runtime/malformed.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh empty-reply empty-reply-mutation-no-reset
#   ./check.sh malformed-tool-call malformed-tool-call-mutation-no-cap
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
MalformedToolCall malformed-tool-call -
MalformedToolCall malformed-tool-call-deep -
MalformedToolCall malformed-tool-call-today EveryStallGetsFeedback
MalformedToolCall malformed-tool-call-mutation-no-cap EndsAfterThird
MalformedToolCall malformed-tool-call-mutation-backoff FeedbackRightAway
MalformedToolCall malformed-tool-call-mutation-tools-off FeedbackKeepsTools
MalformedToolCall malformed-tool-call-mutation-no-reset EveryStallGetsFeedback
MalformedToolCall malformed-tool-call-mutation-run-call MalformedNeverRuns
MalformedToolCall malformed-tool-call-mutation-reconcile-loop ReconcileMalformedStops
MalformedToolCall malformed-tool-call-mutation-search-reconcile SearchKeepsTools
ResponseLanguage response-language -
ResponseLanguage response-language-today RequestedLanguageAccepted
ResponseLanguage response-language-first-cut RequestedLanguageAccepted
ResponseLanguage response-language-second-cut RequestedLanguageAccepted
ResponseLanguage response-language-limit RequestedLanguageAccepted
ResponseLanguage response-language-mutation-accent-only RequestedLanguageAccepted
ResponseLanguage response-language-mutation-cut-hides RequestedLanguageAccepted
ResponseLanguage response-language-mutation-marks-ignored RequestedLanguageAccepted
ResponseLanguage response-language-mutation-shared-hides RequestedLanguageAccepted
ResponseLanguage response-language-mutation-stem-hides RequestedLanguageAccepted
ResponseLanguage response-language-mutation-space-hides RequestedLanguageAccepted
ResponseLanguage response-language-mutation-break-hides RequestedLanguageAccepted
ResponseLanguage response-language-mutation-abstain-all EnglishGuardKept
ResponseLanguage response-language-mutation-retry-twice OneCorrection
ResponseLanguage response-language-mutation-tools-reject CallsKept
VERDICTS
