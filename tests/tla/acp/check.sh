#!/bin/sh
# Model-check the ACP models with TLC and require each config's expected
# verdict.
#
# AcpPermissionModes: the ACP permission-mode contract, which matches the CLI's
# /permissions. AcpSpeed: the per-session Standard, Fast, and Ultrafast speed
# contract. AcpSessionTarget: how a request that names a session is answered,
# under ACP v1's error rules, in fx acp and in libfx's minimal kernel (the
# SDK's _sh.fx/* methods). AcpSystemPrompt: the client's systemPrompt on session/new,
# session/load and session/resume, and the prompt each turn sends.
# AcpPromptDelivery: steering and queued prompts as the sh.fx spec
# defines them. AcpSessions: one connection holding many sessions, each with
# its own turn and workspace. AcpTurnEvents: what a client hears of a
# running turn: the sh.fx turn events it lists, a shell call's
# sh.fx/commandResult, and ACP v1's compaction updates. AcpToolDiffs: the diff an edit's tool call shows, before
# approval and once it is committed. AcpFollow: following a session on several
# connections and catching up by log position, which hasn't landed in
# src/acp/ yet. AcpSessionState: session state, session/status, and list
# change hints, likewise not landed. AcpSharedSession: what the clients of
# one session see of each other's prompts, approvals, cancels, and presence,
# likewise not landed. AcpSubagents: child sessions in the shape of ACP's
# Subagent Sessions, likewise not landed. AcpForkRewind: forking a session
# before a prompt and rewinding one, likewise not landed. Their Before configs show fx before
# the fixes, their Today configs show fx now, and each must fail on the rule it
# names. The other configs must pass. AcpConfigTurn: session/set_config_option
# while a turn runs: answered at once, and the running turn keeps its own
# settings.
# AcpDisconnect: a client that disconnects: a client that lists
# sh.fx/keepTurnOnDisconnect keeps its turns, any other's running turn stops,
# and fx never waits for the gone client.
#
# The planted bugs and the runs of the real `fx acp` binary are in
# ../drivers/acp/:
#   bun ../drivers/acp/permission_modes/check-spec.ts
#   bun ../drivers/acp/permission_modes/driver.ts
#   bun ../drivers/acp/speed/check-spec.ts
#   bun ../drivers/acp/speed/driver.ts
#   bun ../drivers/acp/session_target/check-spec.ts
#   bun ../drivers/acp/session_target/driver.ts   # kernel plans need the native addon
#   bun ../drivers/acp/sessions/check-spec.ts
#   bun ../drivers/acp/sessions/driver.ts
#   bun ../drivers/acp/system_prompt/check-spec.ts
#   bun ../drivers/acp/system_prompt/driver.ts
#   bun ../drivers/acp/prompt_delivery/check-spec.ts
#   bun ../drivers/acp/prompt_delivery/driver.ts   # the sh.fx rules; --model today is fx acp before them
#   bun ../drivers/acp/follow/check-spec.ts
#   bun ../drivers/acp/follow/driver.ts   # one connection: replayed message ids (F6)
#   bun ../drivers/acp/config_turn/check-spec.ts
#   bun ../drivers/acp/config_turn/driver.ts   # set_config_option during a turn
#   bun ../drivers/acp/disconnect/check-spec.ts
#   bun ../drivers/acp/disconnect/driver.ts   # a client that disconnects
#   bun ../drivers/acp/session_state/check-spec.ts
#   bun ../drivers/acp/session_state/driver.ts   # today's fx acp; --model rules fails until the rules land
#   bun ../drivers/acp/shared_session/check-spec.ts
#   bun ../drivers/acp/subagents/check-spec.ts
#   bun ../drivers/acp/fork_rewind/check-spec.ts
#
# With --ci it also runs every ../drivers/acp/*/driver.ts against
# zig-out/bin/fx, as CI does; the planted bugs stay local, since they measure
# the checks, not the code. Name configs to check only those.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes, and Bun and a
# built fx for --ci.
set -eu

ci=false
if [ "${1:-}" = "--ci" ]; then
    ci=true
    shift
fi

cd "$(dirname "$0")"
# shellcheck source-path=SCRIPTDIR source=../lib/tlc.sh
. ../lib/tlc.sh

status=0
tlc_verdicts "$@" <<'EOF' || status=1
MCAcpPermissionModes MCAcpPermissionModes -
MCAcpSpeed MCAcpSpeed -
MCAcpSessionTarget MCAcpSessionTarget -
MCAcpSessionTarget AcpSessionTargetBefore-unknown UnknownSessionAnswer
MCAcpSessionTarget AcpSessionTargetBefore-close CloseIdempotent
MCAcpSessionTarget AcpSessionTargetBefore-oversize NeverAuthCode
MCAcpSessionTarget MCAcpSessionTargetOne -
MCAcpSessionTarget AcpSessionTargetBefore-many OthersStayOpen
MCAcpSessions MCAcpSessions -
MCAcpSessions MCAcpSessionsOverlap AtMostOneRunning
MCAcpSessions AcpSessionsToday-others OthersUntouched
MCAcpSessions AcpSessionsToday-reuse ReuseKeepsTurn
MCAcpSessions AcpSessionsToday-overlap -
MCAcpTurnEvents MCAcpTurnEvents -
MCAcpTurnEvents MCAcpTurnEventsPlain -
MCAcpTurnEvents MCAcpTurnEventsSome -
MCAcpTurnEvents AcpTurnEventsToday Complete
MCAcpTurnEvents AcpTurnEventsRootField StandardOnly
MCAcpToolDiffs MCAcpToolDiffs -
MCAcpToolDiffs MCAcpToolDiffsAsk -
MCAcpToolDiffs AcpToolDiffsToday Complete
MCAcpSystemPrompt MCAcpSystemPrompt -
MCAcpSystemPrompt AcpSystemPromptBefore-v1-refused V1Accepted
MCAcpSystemPrompt AcpSystemPromptBefore-old-accepted OtherShapesRefused
MCAcpSystemPrompt AcpSystemPromptBefore-load-ignores LoadAppliesPrompt
MCAcpPromptDelivery MCAcpPromptDelivery -
MCAcpPromptDelivery MCAcpPromptDeliveryRefusals -
MCAcpPromptDelivery AcpPromptDeliveryToday-interrupt NoSteerWaitsOnReply
MCAcpPromptDelivery AcpPromptDeliveryToday-lost NothingLost
MCAcpPromptDelivery AcpPromptDeliveryToday-stopped StopKeepsSteers
MCAcpPromptDelivery AcpPromptDeliveryToday-late LateRunTogether
MCAcpFollow MCAcpFollow -
MCAcpFollow AcpFollowToday-busy JoinWorks
MCAcpFollow AcpFollowToday-ids StableIds
MCAcpFollow AcpFollowIds -
MCAcpFollow AcpFollowToday-position PositionCurrent
MCAcpFollow AcpFollowToday-replay ReplaySaid
MCAcpSessionState MCAcpSessionState -
MCAcpSessionState MCAcpSessionStateLists -
MCAcpSessionState AcpSessionStateToday-state StateCurrent
MCAcpSessionState AcpSessionStateToday-order UpdatesWhileRunning
MCAcpSessionState AcpSessionStateToday-list ListFresh
MCAcpSessionState AcpSessionStateToday-status StatusTruthful
MCAcpSharedSession MCAcpSharedSession -
MCAcpSharedSession MCAcpSharedSessionThree -
MCAcpSharedSession AcpSharedSessionToday-request RequestReachesAll
MCAcpSharedSession AcpSharedSessionToday-prompts EchoComplete
MCAcpSharedSession AcpSharedSessionToday-clients RosterCurrent
MCAcpSharedSession AcpSharedSessionToday-cancel CancelStops
MCAcpSubagents MCAcpSubagents -
MCAcpSubagents AcpSubagentsToday-ids ChildIdUsed
MCAcpSubagents AcpSubagentsToday-replay ReplayComplete
MCAcpForkRewind MCAcpForkRewind -
MCAcpForkRewind AcpForkRewindToday-fork ForkAvailable
MCAcpForkRewind AcpForkRewindToday-rewind RewindAvailable
MCAcpConfigTurn MCAcpConfigTurn -
MCAcpConfigTurn AcpConfigTurnToday AnswersDuringTurn
MCAcpDisconnect MCAcpDisconnect -
MCAcpDisconnect MCAcpDisconnectPlain -
MCAcpDisconnect AcpDisconnectToday-keep KeptTurnsComplete
MCAcpDisconnect AcpDisconnectToday-wait NeverWaitsForGoneClient
EOF

if [ "$ci" = true ]; then
    for driver in ../drivers/acp/*/driver.ts; do
        echo "driver ${driver#../drivers/acp/}"
        if ! bun "$driver"; then
            echo "FAIL  ${driver#../drivers/acp/}"
            status=1
        fi
    done
fi
exit "$status"
