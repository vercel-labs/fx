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
# one session see of each other's prompts, approvals, cancels, presence, and the
# list of connected clients,
# likewise not landed. AcpSubagents: child sessions in the shape of ACP's
# Subagent Sessions, likewise not landed. AcpForkRewind: forking a session
# before a prompt and rewinding one, likewise not landed. Their Before configs show fx before
# the fixes, their Today configs show fx now, and each must fail on the rule it
# names. The other configs must pass. AcpConfigTurn: session/set_config_option
# while a turn runs: answered at once, and the running turn keeps its own
# settings.
# AcpTakeover: a session after its holder dies: the next holder repairs the turn,
# removes the dead holder's folder (not built yet; `today` is the code now), and
# restores nothing. AcpDisconnect: a client that disconnects: a client that lists
# sh.fx/keepTurnOnDisconnect keeps its turns, any other's running turn stops,
# and fx never waits for the gone client.
# AcpLeader: the lock of a session names its holder and the holder's leader
# socket, so another fx acp can find the holder. A process whose socket cannot
# start still takes the lock and empties the record a dead holder left. Its
# Today config shows fx acp before the record.
#
# AcpJoin: a second connection joins a session another connection of the same
# process has open. Its load replays the saved turns, the running copy, a notice
# when the copy dropped part of the turn, and the answer; a resume gives the
# answer and the updates after it; a follower changes nothing. Its Today config
# shows fx before the join, where a second connection's load is refused.
# AcpSessionReaders: the two readers of one session, the owner's and a follower's:
# a start claims the prompt slot and waits while a taken turn is joined, a reap
# takes a finished turn out and joins it, and a close refuses new starts, unregisters,
# waits for the uses, and frees. Its Today config shows
# fx today, where two starts can both see an empty slot. The design (Rules TRUE)
# is not landed yet, and the model says so at its top.
# AcpSharedInput: two clients on one session, the owner and a follower, and the
# input each one sends: prompts with delivery none, steer or queue, cancels,
# and a follower's load, close, and disconnect. One order serves all clients,
# each answer goes to its sender at most once, a prompt's chunk goes to the
# other clients, a leaving follower's waiting input is withdrawn, and a running
# turn keeps the system prompt it started with, a new turn uses the current one,
# and no cancel from a client that may send one is ignored. Its Today config shows fx before
# the follower's input, where a follower only watches, and it must violate
# FollowerPromptRuns.
# AcpJoinTrace: the real fx acp, with followers on its leader socket, run through
# six plans and checked against AcpJoin. Its driver's --ci run requires every plan
# ACCEPTED on the built binary; --model today is the control, REJECTED throughout.
#
# AcpSessionStaysOpen: one session with three clients, O (the stdio connection
# and the opener) and two leader-socket followers, through join, close, input
# end, prompts, cancel, permission requests, mode changes, a crash, and the
# process exit. Design A hands the owner pointer to the oldest follower, and
# design B keeps process-owned members in join order. The current config is the
# code at 3710141de6, where the owner's leave closes the session for every
# client. Each current-* config breaks one rule, each mutant-* config plants one
# bug that its named invariant must catch, and the simulate-* configs run random
# behaviors. Ideal has no crash and no input end.
#
# AcpApprovals: approvals across the clients of one session. A turn's permission
# question goes to every client that has the session open. The first valid answer
# decides, and the other clients are told. Only the client that sent the turn's
# prompt may choose "allow for this session". A leaving client's question is not
# asked again, and it is denied when no client is left. A joiner gets the open
# question after its replay. Design A gives each client its own request id, and
# design B gives the session one id space, shared with host tool requests. The
# current-* configs are today's code, which sends the question to the main client
# only and asks it again when the main leaves. Each mutant-* config plants one bug
# that its named invariant or property must catch, and the simulate-* configs run
# random behaviors. The witness-* configs must reach a state that a rule forbids,
# so the model is not vacuous. Time and the cost of a stuck client are not modelled.
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
#   bun ../drivers/acp/follow/driver.ts   # one connection: replayed message ids
#   bun ../drivers/acp/config_turn/check-spec.ts
#   bun ../drivers/acp/config_turn/driver.ts   # set_config_option during a turn
#   bun ../drivers/acp/disconnect/check-spec.ts
#   bun ../drivers/acp/disconnect/driver.ts   # a client that disconnects
#   bun ../drivers/acp/leader/check-spec.ts
#   bun ../drivers/acp/leader/driver.ts   # the real fx acp against AcpLeader
#   bun ../drivers/acp/takeover/check-spec.ts   # AcpTakeover: the design, today, planted bugs, witnesses
#   bun ../drivers/acp/join/check-spec.ts
#   bun ../drivers/acp/join/driver.ts   # the real fx acp with followers, against AcpJoinTrace
#   bun ../drivers/acp/session_state/check-spec.ts
#   bun ../drivers/acp/session_state/driver.ts   # today's fx acp; --model rules fails until the rules land
#   bun ../drivers/acp/shared_session/check-spec.ts
#   bun ../drivers/acp/subagents/check-spec.ts
#   bun ../drivers/acp/fork_rewind/check-spec.ts
#   bun ../drivers/acp/session_readers/check-spec.ts
#   bun ../drivers/acp/shared_input/check-spec.ts
#   bun ../drivers/acp/shared_input/driver.ts   # the real fx acp with a follower's input, against AcpSharedInputTrace
#   bun ../drivers/acp/approvals/check-spec.ts
#   bun ../drivers/acp/approvals/driver.ts   # the real fx acp with a follower's permission question, against AcpApprovalsTrace
#   bun ../drivers/acp/shared_session/driver.ts   # the real fx acp with the clients of one session, against AcpSharedSessionTrace
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
MCAcpSharedSession AcpSharedSessionOptIn -
MCAcpSharedSession AcpSharedSessionWitness-optin NoUnlistedOpen
MCAcpSharedSession AcpSharedSessionWitness-steer NoSteerSent
MCAcpSharedSession AcpSharedSessionToday-joiner JoinerListedBeforeAnswer
MCAcpSharedSession AcpSharedSessionToday-sender ChunkSenderGate
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
MCAcpLeader MCAcpLeader -
MCAcpLeader AcpLeaderToday temporal
AcpTakeover AcpTakeover -
AcpTakeover AcpTakeover-today temporal
AcpTakeover AcpTakeover-today-rest -
AcpTakeover AcpTakeover-remove-live NoLiveFolderRemoved
AcpTakeover AcpTakeover-remove-no-lock FolderRemovedByHolder
AcpTakeover AcpTakeover-remove-on-timeout NoRemovalAfterTimeout
AcpTakeover AcpTakeover-two-holders AtMostOneHolder
AcpTakeover AcpTakeover-restore-grant GrantOwnedByHolder
AcpTakeover AcpTakeover-restore-queue QueueOwnedByHolder
AcpTakeover AcpTakeover-restore-question QuestionOwnedByHolder
AcpTakeover AcpTakeover-continue-turn CallsAreAsked
AcpTakeover AcpTakeover-line-by-other LineWrittenByHolder
AcpTakeover AcpTakeover-witness-busy NoBusyLoad
AcpTakeover AcpTakeover-witness-repair NoRepairedTurn
AcpTakeover AcpTakeover-witness-cleanup NoDeadFolderRemoved
AcpTakeover AcpTakeover-witness-reconnect NoFollowerConnected
MCAcpJoin MCAcpJoin -
MCAcpJoin AcpJoinToday temporal
MCAcpSessionReaders MCAcpSessionReaders -
MCAcpSessionReaders AcpSessionReadersToday AtMostOneWorker
MCAcpSharedInput MCAcpSharedInput -
MCAcpSharedInput AcpSharedInputToday temporal
AcpSessionStaysOpen current-stays-open StaysOpenWhileMember
AcpSessionStaysOpen current-one-main OneMainInJoinOrder
AcpSessionStaysOpen current-denied DeniedOnlyWhenNoMember
AcpSessionStaysOpen design-a -
AcpSessionStaysOpen design-b -
AcpSessionStaysOpen mutant-a-captured NoDanglingClient
AcpSessionStaysOpen mutant-a-newest OneMainInJoinOrder
AcpSessionStaysOpen mutant-a-free NoDanglingClient
AcpSessionStaysOpen mutant-a-close-cancels-others LeaveAffectsOnlyOwnInput
AcpSessionStaysOpen mutant-b-free NoDanglingClient
AcpSessionStaysOpen mutant-b-free-freed SessionFreedWhenIdle
AcpSessionStaysOpen mutant-b-exit-early NoExitWhileServing
AcpSessionStaysOpen mutant-b-join-withdraws LastKeepQueueRuns
AcpSessionStaysOpen mutant-close-cancels-others LeaveAffectsOnlyOwnInput
AcpSessionStaysOpen mutant-leave-keeps-queue LeftInputNeverRuns
AcpSessionStaysOpen mutant-mode-any MainChangesModeOnly
AcpSessionStaysOpen mutant-last-no-cancel LastLeaverRule
AcpSessionStaysOpen simulate-ideal-a simulate -simulate num=20000 -depth 20 -seed 1
AcpSessionStaysOpen simulate-nonideal-a simulate -simulate num=20000 -depth 20 -seed 1
AcpSessionStaysOpen simulate-ideal-b simulate -simulate num=20000 -depth 20 -seed 1
AcpSessionStaysOpen simulate-nonideal-b simulate -simulate num=20000 -depth 20 -seed 1
AcpApprovals approvals-design-a -
AcpApprovals approvals-design-b -
AcpApprovals approvals-current-fanout EveryClientGetsQuestion
AcpApprovals approvals-current-reask NoReAsk
AcpApprovals approvals-current-sender-always OnlySenderAlways
AcpApprovals approvals-mutant-a-always-anyone OnlySenderAlways
AcpApprovals approvals-mutant-a-second-answer DecisionStable
AcpApprovals approvals-mutant-a-no-cancel OthersTold
AcpApprovals approvals-mutant-a-reask NoReAsk
AcpApprovals approvals-mutant-a-joiner-misses EveryClientGetsQuestion
AcpApprovals approvals-mutant-a-no-deny-last DeniedWhenNoClient
AcpApprovals approvals-mutant-a-foreign-id WinnerHadRequest
AcpApprovals approvals-mutant-a-write-after OthersTold
AcpApprovals approvals-mutant-a-follower-dropped ValidAnswerNotRefused
AcpApprovals approvals-mutant-b-host-collide IdsDistinct
AcpApprovals approvals-simulate-ideal-a simulate -simulate num=20000 -depth 20 -seed 1
AcpApprovals approvals-simulate-nonideal-a simulate -simulate num=20000 -depth 20 -seed 1
AcpApprovals approvals-simulate-ideal-b simulate -simulate num=20000 -depth 20 -seed 1
AcpApprovals approvals-simulate-nonideal-b simulate -simulate num=20000 -depth 20 -seed 1
AcpApprovals approvals-witness-follower NoFollowerWin
AcpApprovals approvals-witness-always NoAlwaysWin
AcpApprovals approvals-single-a -
AcpApprovals approvals-single-b -
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
