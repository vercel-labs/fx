---------------------------- MODULE WebSearchSlots ----------------------------
(***************************************************************************)
(* Web search slots: src/core/tooling/web_search_slots.zig and the         *)
(* refusal branch of the step loop in                                      *)
(* src/core/agent/runtime/orchestrator.zig. The driver in                  *)
(* tests/tla/drivers/web_search/ walks the real slot state along it.       *)
(*                                                                         *)
(* Every Gateway request carries the first slot in Order that is not       *)
(* blocked for the request's team. When the Gateway refuses the slot's     *)
(* tool for the team, the agent records the block in one shared set and    *)
(* resends at once. The last slot, no search, is never refused.            *)
(*                                                                         *)
(* Two agents (the main agent and a subagent) share the set, and the       *)
(* team can change once. The design keys the set by a team generation      *)
(* and updates it with one compare-and-swap. Three switches remove one     *)
(* mechanism each, so a mutation config can plant the defect:              *)
(*   Advance      FALSE: a refusal waits for the user, who resends as is   *)
(*   KeyByTeam    FALSE: a block learned on one team applies to the next   *)
(*   AtomicBlock  FALSE: the block reads the set, then writes it later     *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Agents, RefusedByInit, RefusedByOther, MaxGen, MaxRequests,
          Advance, KeyByTeam, AtomicBlock

VARIABLES gen, teamOf, blocked, blockedGen, pc, sentSlot, sentGen, sends,
          requests, snap, recorded, notices, violStale, violRepeat

vars == <<gen, teamOf, blocked, blockedGen, pc, sentSlot, sentGen, sends,
          requests, snap, recorded, notices, violStale, violRepeat>>

\* The default slot order; the last slot sends no search tool.
Order == <<"exa", "native", "parallel", "none">>
InitTeam == "first_team"
OtherTeam == "second_team"
Refuses == [t \in {InitTeam, OtherTeam} |->
               IF t = InitTeam THEN RefusedByInit ELSE RefusedByOther]

Idx == 1..Len(Order)
Slots == {Order[i] : i \in Idx}
NoSearch == Order[Len(Order)]
Gens == 0..MaxGen
SendBound == Len(Order) * (MaxGen + 1)

ASSUME NoSearch \notin Refuses[InitTeam] \cup Refuses[OtherTeam]

\* The blocked slots a request built in generation g sees.
Eff(g) == IF KeyByTeam
            THEN (IF blockedGen = g THEN blocked ELSE {})
            ELSE blocked

FirstFree(B) == CHOOSE i \in Idx : Order[i] \notin B /\ \A j \in 1..(i - 1) : Order[j] \in B

Resolve(g) == Order[FirstFree(Eff(g))]

IndexOf(s) == CHOOSE k \in Idx : Order[k] = s

Init ==
    /\ gen = 0
    /\ teamOf = [g \in Gens |-> InitTeam]
    /\ blocked = {}
    /\ blockedGen = 0
    /\ pc = [a \in Agents |-> "idle"]
    /\ sentSlot = [a \in Agents |-> NoSearch]
    /\ sentGen = [a \in Agents |-> 0]
    /\ sends = [a \in Agents |-> 0]
    /\ requests = [a \in Agents |-> 1]
    /\ snap = [a \in Agents |-> {}]
    \* Ghost: every <<generation, slot>> refusal fx has processed.
    /\ recorded = {}
    /\ notices = [p \in Gens \X Slots |-> 0]
    /\ violStale = FALSE
    /\ violRepeat = FALSE

\* Build and send one request with the resolver's slot.
Send(a) ==
    /\ pc[a] = "idle"
    /\ LET s == Resolve(gen)
       IN /\ sentSlot' = [sentSlot EXCEPT ![a] = s]
          /\ sentGen' = [sentGen EXCEPT ![a] = gen]
          /\ sends' = [sends EXCEPT ![a] = @ + 1]
          /\ pc' = [pc EXCEPT ![a] = "sent"]
          \* A skipped slot that this team does not refuse is a stale skip.
          /\ violStale' = (violStale \/
                 \E j \in 1..(IndexOf(s) - 1) : Order[j] \notin Refuses[teamOf[gen]])
          \* Sending a slot whose refusal fx already processed for this team.
          /\ violRepeat' = (violRepeat \/ <<gen, s>> \in recorded)
    /\ UNCHANGED <<gen, teamOf, blocked, blockedGen, requests, snap, recorded, notices>>

Refused(a) == sentSlot[a] \in Refuses[teamOf[sentGen[a]]]

ReplyOk(a) ==
    /\ pc[a] = "sent"
    /\ ~Refused(a)
    /\ pc' = [pc EXCEPT ![a] = "done"]
    /\ UNCHANGED <<gen, teamOf, blocked, blockedGen, sentSlot, sentGen, sends,
                   requests, snap, recorded, notices, violStale, violRepeat>>

\* Today: the refusal is a plain 400 that waits for the user.
ReplyRefusedWaits(a) ==
    /\ pc[a] = "sent"
    /\ Refused(a)
    /\ ~Advance
    /\ pc' = [pc EXCEPT ![a] = "user"]
    /\ UNCHANGED <<gen, teamOf, blocked, blockedGen, sentSlot, sentGen, sends,
                   requests, snap, recorded, notices, violStale, violRepeat>>

\* Enter resends the request unchanged.
UserResend(a) ==
    /\ pc[a] = "user"
    /\ pc' = [pc EXCEPT ![a] = "idle"]
    /\ UNCHANGED <<gen, teamOf, blocked, blockedGen, sentSlot, sentGen, sends,
                   requests, snap, recorded, notices, violStale, violRepeat>>

\* The design: one compare-and-swap records the block, then the agent resends.
BlockAtomic(a) ==
    /\ pc[a] = "sent"
    /\ Refused(a)
    /\ Advance
    /\ AtomicBlock
    /\ LET s == sentSlot[a]
           g == sentGen[a]
           applies == ~KeyByTeam \/ g = gen
       IN /\ IF ~KeyByTeam
               THEN /\ blocked' = blocked \cup {s}
                    /\ UNCHANGED blockedGen
               ELSE IF g # gen
                    THEN UNCHANGED <<blocked, blockedGen>>
                    ELSE IF blockedGen = gen
                         THEN /\ blocked' = blocked \cup {s}
                              /\ UNCHANGED blockedGen
                         ELSE /\ blocked' = {s}
                              /\ blockedGen' = gen
          /\ notices' = IF applies /\ s \notin Eff(g)
                          THEN [notices EXCEPT ![<<g, s>>] = @ + 1]
                          ELSE notices
          /\ recorded' = recorded \cup {<<g, s>>}
          /\ pc' = [pc EXCEPT ![a] = "idle"]
    /\ UNCHANGED <<gen, teamOf, sentSlot, sentGen, sends, requests, snap,
                   violStale, violRepeat>>

\* Mutation: read the set now and write it in a later step.
BlockRead(a) ==
    /\ pc[a] = "sent"
    /\ Refused(a)
    /\ Advance
    /\ ~AtomicBlock
    /\ snap' = [snap EXCEPT ![a] = Eff(sentGen[a])]
    /\ pc' = [pc EXCEPT ![a] = "writing"]
    /\ UNCHANGED <<gen, teamOf, blocked, blockedGen, sentSlot, sentGen, sends,
                   requests, recorded, notices, violStale, violRepeat>>

BlockWrite(a) ==
    /\ pc[a] = "writing"
    /\ LET s == sentSlot[a]
           g == sentGen[a]
       IN /\ IF KeyByTeam /\ g # gen
               THEN UNCHANGED <<blocked, blockedGen>>
               ELSE /\ blocked' = snap[a] \cup {s}
                    /\ blockedGen' = IF KeyByTeam THEN gen ELSE blockedGen
          /\ notices' = IF s \notin snap[a]
                          THEN [notices EXCEPT ![<<g, s>>] = @ + 1]
                          ELSE notices
          /\ recorded' = recorded \cup {<<g, s>>}
          /\ pc' = [pc EXCEPT ![a] = "idle"]
    /\ UNCHANGED <<gen, teamOf, sentSlot, sentGen, sends, requests, snap,
                   violStale, violRepeat>>

NextRequest(a) ==
    /\ pc[a] = "done"
    /\ requests[a] < MaxRequests
    /\ pc' = [pc EXCEPT ![a] = "idle"]
    /\ requests' = [requests EXCEPT ![a] = @ + 1]
    /\ sends' = [sends EXCEPT ![a] = 0]
    /\ UNCHANGED <<gen, teamOf, blocked, blockedGen, sentSlot, sentGen, snap,
                   recorded, notices, violStale, violRepeat>>

\* fx teams, or a sign-in to another team.
SwitchTeam ==
    /\ gen < MaxGen
    /\ gen' = gen + 1
    /\ teamOf' = [teamOf EXCEPT ![gen + 1] = OtherTeam]
    /\ UNCHANGED <<blocked, blockedGen, pc, sentSlot, sentGen, sends, requests,
                   snap, recorded, notices, violStale, violRepeat>>

Next ==
    \/ SwitchTeam
    \/ \E a \in Agents :
          \/ Send(a)
          \/ ReplyOk(a)
          \/ ReplyRefusedWaits(a)
          \/ UserResend(a)
          \/ BlockAtomic(a)
          \/ BlockRead(a)
          \/ BlockWrite(a)
          \/ NextRequest(a)

Spec == Init /\ [][Next]_vars

\* One request sends each slot at most once per team generation.
BoundedSends == \A a \in Agents : sends[a] <= SendBound

\* A slot is skipped only when the request's own team refused it.
NoStaleSkip == ~violStale

\* A refusal fx processed is never sent again for the same team.
NoRepeatRefusal == ~violRepeat

\* The user sees one notice per blocked slot per team.
OneNotice == \A p \in Gens \X Slots : notices[p] <= 1

\* Keeps the mutation without a slot move finite.
StateBound == \A a \in Agents : sends[a] <= SendBound + 1
=============================================================================
