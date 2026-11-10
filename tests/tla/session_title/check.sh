#!/bin/sh
# Model-check session title generation and the model list under a shared
# sign-in (src/core/session/session_title_generation.zig,
# src/core/app/model_cache_runtime.zig) with TLC and require each config's
# expected verdict.
#
# session-title.cfg (fx login or a subscription) and session-title-static.cfg
# (a static key) are the design and must pass. Each session-title-today-*.cfg
# checks fx before the change against one rule it broke:
#
#   today-stale-title   the title sent the in-memory token      TitleFirstSendUsesStore
#   today-gives-up      the title gave up after one 401         TitleGivesUpOnlyWhenUnrecoverable
#   today-second-title  an interrupting prompt titled again     AtMostOneTitleRequest
#   today-catalog       the model list fell back after one 401  CatalogFallsBackOnlyWhenUnrecoverable
#
# Each session-title-mutation-*.cfg plants one defect, and the rule it names
# must catch it:
#
#   no-reload          the title sends the in-memory token     TitleFirstSendUsesStore
#   no-replay          the title gives up after one 401         TitleGivesUpOnlyWhenUnrecoverable
#   double-replay      the title sends a third time             TitleAtMostOneReplay
#   force-no-recheck   a 401 forces a refresh at once           NoNeedlessRefresh
#   replay-static-key  a static key is refreshed and resent     StaticKeyNeverReplays
#   history-gate       the gate reads only the history          AtMostOneTitleRequest
#   catalog-no-reload  the model list sends the in-memory token CatalogFirstSendUsesStore
#   catalog-no-replay  the model list falls back after one 401  CatalogFallsBackOnlyWhenUnrecoverable
#
# SessionTitleTrace.tla checks runs of the built fx binary against the model;
# tests/tla/drivers/session_title/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh session-title session-title-mutation-no-reload
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
SessionTitle session-title -
SessionTitle session-title-static -
SessionTitle session-title-today-stale-title TitleFirstSendUsesStore
SessionTitle session-title-today-gives-up TitleGivesUpOnlyWhenUnrecoverable
SessionTitle session-title-today-second-title AtMostOneTitleRequest
SessionTitle session-title-today-catalog CatalogFallsBackOnlyWhenUnrecoverable
SessionTitle session-title-mutation-no-reload TitleFirstSendUsesStore
SessionTitle session-title-mutation-no-replay TitleGivesUpOnlyWhenUnrecoverable
SessionTitle session-title-mutation-double-replay TitleAtMostOneReplay
SessionTitle session-title-mutation-force-no-recheck NoNeedlessRefresh
SessionTitle session-title-mutation-replay-static-key StaticKeyNeverReplays
SessionTitle session-title-mutation-history-gate AtMostOneTitleRequest
SessionTitle session-title-mutation-catalog-no-reload CatalogFirstSendUsesStore
SessionTitle session-title-mutation-catalog-no-replay CatalogFallsBackOnlyWhenUnrecoverable
VERDICTS
