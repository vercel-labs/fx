--------------------------- MODULE ConfiguredRequest ---------------------------
(***************************************************************************)
(* What fx sends to a custom model connection                              *)
(* (src/core/config/configured_provider.zig, src/gateway/) over one live   *)
(* session: which effort level and which request fields reach the wire,    *)
(* the notice for a configured effort the model does not offer, and the    *)
(* request after a reply that ran out of output tokens with nothing        *)
(* usable, which carries fx's note to take a smaller step                  *)
(* (src/core/agent/runtime/orchestrator.zig,                               *)
(* src/core/agent/runtime/output_limit.zig). Two notes in a row are the    *)
(* most: the third cut reply in a row ends the turn. The first cut of a    *)
(* turn raises an output limit fx chose itself for the rest of the turn,   *)
(* and a note's request reasons at `low` when the request that was cut did *)
(* not already.                                                            *)
(*                                                                         *)
(* A model's metadata may declare:                                         *)
(*   declared  its effort levels, in the order the settings list them      *)
(*   levels    for each level, the request fields it sets                  *)
(*   request   request fields sent with every request                     *)
(*   limit     whether it names an output limit (max_output_tokens)        *)
(*   field     the request field that carries the limit                    *)
(* A set of field names stands for a JSON fragment. "model" stands for     *)
(* every field fx owns; the other two are fields a server may accept.      *)
(*                                                                         *)
(* A reply is one of:                                                      *)
(*   "answer"  a final answer, which ends the turn                         *)
(*   "tool"    tool calls, which start the turn's next step                *)
(*   "cut"     the output limit ran out before any text or usable call     *)
(*                                                                         *)
(* Bug plants one defect; check.sh names the rule that must catch each.    *)
(* "today" is fx before the change, where a level is never sent.           *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Levels, MaxRequests, Bug

Keys == {"model", "temperature", "reasoning_effort"}
Owned == {"model"}
RequestFragments == {{}, {"temperature"}, {"temperature", "reasoning_effort"}, {"model"}}
LevelFragments == {{"reasoning_effort"}, {"reasoning_effort", "temperature"}, {"model"}}
Efforts == Levels \cup {"auto"}
Fields == {"max_tokens", "max_completion_tokens"}
Kinds == {"answer", "tool", "cut"}

Range(s) == {s[i] : i \in DOMAIN s}
Position(s, x) == IF x \in Range(s) THEN CHOOSE i \in DOMAIN s : s[i] = x ELSE 0

\* Every list of distinct levels: the settings give the order.
Orders ==
    {s \in UNION {[1..n -> Levels] : n \in 0..Cardinality(Levels)} :
        \A i, j \in DOMAIN s : i # j => s[i] # s[j]}

Definitions ==
    [declared : Orders, request : RequestFragments, levels : [Levels -> LevelFragments],
     limit : BOOLEAN, field : Fields]

VARIABLES
    def,         \* the selected model's metadata
    configured,  \* the effort the person set, or "auto"
    loaded,      \* "ok", or "rejected" when the settings failed to load
    phase,       \* "idle" between turns, "waiting" for a reply
    sent,        \* every request of the session, in order
    notices,     \* ignored-effort notices shown in the session
    raised,      \* this turn raised fx's own output limit after a cut
    resent,      \* the request being answered carries a note after a cut
    lowered,     \* the request being answered reasons at `low` after a cut
    cuts         \* cut replies in a row in this turn

vars == <<def, configured, loaded, phase, sent, notices, raised, resent, lowered, cuts>>

\* output_limit.max_notes_in_a_row
MaxNotes == 2

\* A fragment names a field fx owns.
NamesOwned(d) ==
    \/ d.request \cap Owned # {}
    \/ \E l \in Range(d.declared) : d.levels[l] \cap Owned # {}

InitWith(d, c) ==
    /\ def = d
    /\ configured = c
    /\ loaded = IF Bug # "owned_key" /\ NamesOwned(d) THEN "rejected" ELSE "ok"
    /\ phase = "idle"
    /\ sent = <<>>
    /\ notices = 0
    /\ raised = FALSE
    /\ resent = FALSE
    /\ lowered = FALSE
    /\ cuts = 0

Init == \E d \in Definitions, c \in Efforts : InitWith(d, c)

\* A fresh session, for trace validation of several sessions in a row.
Reset(d, c) ==
    /\ def' = d
    /\ configured' = c
    /\ loaded' = IF Bug # "owned_key" /\ NamesOwned(d) THEN "rejected" ELSE "ok"
    /\ phase' = "idle"
    /\ sent' = <<>>
    /\ notices' = 0
    /\ raised' = FALSE
    /\ resent' = FALSE
    /\ lowered' = FALSE
    /\ cuts' = 0

\* The levels fx offers for the model.
Offered == IF Bug = "today" THEN {} ELSE Range(def.declared)

\* The level a request carries for the effort `e`, or "none".
Wire(e) ==
    IF e \in Offered THEN e
    ELSE IF Bug = "undeclared_effort" /\ e # "auto" THEN e
    ELSE "none"

LevelKeys(w) ==
    IF w = "none" THEN {}
    ELSE IF w \in Range(def.declared) THEN def.levels[w]
    ELSE {"reasoning_effort"}

\* Where each field of the request body comes from. A field both fragments
\* set is sent once, with the level's value.
Body(w) ==
    [k \in Keys |->
        LET from_level == k \in LevelKeys(w)
            from_request == k \in def.request
        IN IF from_level /\ (~from_request \/ Bug # "request_beats_level") THEN "level"
           ELSE IF from_request THEN "request"
           ELSE IF k \in Owned THEN "fx"
           ELSE "absent"]

\* The output limit a request names: the model's own, fx's after a resend
\* raised it, or none.
Limit(r) == IF def.limit THEN "model" ELSE IF r THEN "raised" ELSE "none"

Field(l) ==
    IF l = "none" THEN "none"
    ELSE IF Bug = "wrong_limit_field" THEN "max_tokens"
    ELSE def.field

Request(e, r, again) ==
    [effort |-> Wire(e), body |-> Body(Wire(e)), limit |-> Limit(r),
     field |-> Field(Limit(r)), resend |-> again]

\* The person set an effort the model does not declare.
Ignored == configured # "auto" /\ configured \notin Range(def.declared)

Noticed(again) ==
    IF again \/ Bug \in {"silent_drop", "today"} THEN notices
    ELSE IF Ignored /\ (notices = 0 \/ Bug = "notice_repeats") THEN notices + 1
    ELSE IF Bug = "notice_always" /\ configured # "auto" /\ notices = 0 THEN 1
    ELSE notices

Send(e, r, again) ==
    /\ sent' = Append(sent, Request(e, r, again))
    /\ notices' = Noticed(again)
    /\ raised' = r
    /\ resent' = again
    /\ lowered' = (again /\ e = "low" /\ Wire(configured) # "low")
    /\ phase' = "waiting"

Ends ==
    /\ phase' = "idle"
    /\ UNCHANGED <<sent, notices, raised, resent, lowered>>

StartTurn ==
    /\ loaded = "ok"
    /\ phase = "idle"
    /\ cuts' = 0
    /\ Send(configured, FALSE, FALSE)
    /\ UNCHANGED <<def, configured, loaded>>

\* `low` is offered and reasons less than the effort `e` the request used.
LowReasonsLess(e) ==
    /\ "low" \in Offered
    /\ e \notin Offered \/ Position(def.declared, "low") < Position(def.declared, e)

\* A cut reply: up to two in a row get a note; the third ends the turn.
\* no_cap: every cut gets one. resend_again: a request already at `low`
\* after a cut is lowered again.
Cut ==
    LET raise == ~raised /\ ~def.limit
        lower == (~lowered \/ Bug = "resend_again") /\ LowReasonsLess(configured)
    IN /\ cuts' = cuts + 1
       /\ IF cuts < MaxNotes \/ Bug = "no_cap"
             THEN Send(IF lower THEN "low" ELSE configured, raised \/ raise, TRUE)
             ELSE Ends

Reply(kind) ==
    /\ phase = "waiting"
    /\ UNCHANGED <<def, configured, loaded>>
    /\ CASE kind = "answer" -> Ends /\ UNCHANGED cuts
         [] kind = "tool" -> Send(configured, raised, FALSE) /\ cuts' = 0
         [] kind = "cut" -> Cut

Next == StartTurn \/ \E kind \in Kinds : Reply(kind)

Spec == Init /\ [][Next]_vars

Bounded == Len(sent) <= MaxRequests

-----------------------------------------------------------------------------

Requests ==
    [effort : Levels \cup {"none"}, body : [Keys -> {"fx", "request", "level", "absent"}],
     limit : {"none", "model", "raised"}, field : Fields \cup {"none"}, resend : BOOLEAN]

TypeOK ==
    /\ def \in Definitions
    /\ configured \in Efforts
    /\ loaded \in {"ok", "rejected"}
    /\ phase \in {"idle", "waiting"}
    /\ sent \in Seq(Requests)
    /\ notices \in Nat
    /\ raised \in BOOLEAN
    /\ resent \in BOOLEAN
    /\ lowered \in BOOLEAN
    /\ cuts \in Nat

\* Settings whose fragment names a field fx owns never send a request.
NothingSentWhenRejected == loaded = "rejected" => sent = <<>>

\* A fragment never replaces a field fx owns.
OwnedKeysKeepFxValue ==
    \A i \in DOMAIN sent : \A k \in Owned : sent[i].body[k] = "fx"

\* A request carries a level only when the model declares it.
EffortOnlyWhenDeclared ==
    \A i \in DOMAIN sent : sent[i].effort # "none" => sent[i].effort \in Range(def.declared)

\* A request with no level carries no level's fields.
NoLevelFieldsWithoutEffort ==
    \A i \in DOMAIN sent : sent[i].effort = "none" => \A k \in Keys : sent[i].body[k] # "level"

\* A field the level sets is sent with the level's value, whatever the
\* model's own request fields say.
LevelBeatsRequest ==
    \A i \in DOMAIN sent : \A k \in Keys :
        (sent[i].effort \in Range(def.declared) /\ k \in def.levels[sent[i].effort])
            => sent[i].body[k] = "level"

\* An effort the model declares is sent with every request that is not a
\* resend.
ConfiguredEffortSent ==
    \A i \in DOMAIN sent :
        (~sent[i].resend /\ configured \in Range(def.declared)) => sent[i].effort = configured

\* An effort the model does not declare is reported once it is ignored.
IgnoredEffortNoticed == (Ignored /\ sent # <<>>) => notices >= 1

NoticeOncePerSession == notices <= 1

NoticeOnlyWhenIgnored == notices > 0 => Ignored

\* The output limit travels in the field the model's metadata names.
LimitInConfiguredField ==
    \A i \in DOMAIN sent :
        sent[i].field = (IF sent[i].limit = "none" THEN "none" ELSE def.field)

\* Two notes in a row are the most: the third cut reply in a row ends the
\* turn.
AtMostTwoNotesInARow ==
    \A i \in DOMAIN sent :
        (i > 2 /\ sent[i].resend /\ sent[i - 1].resend) => ~sent[i - 2].resend

\* A request that reasons at `low` after a cut is never followed by another:
\* the next note goes back to the configured effort.
NeverLowTwiceInARow ==
    \A i \in DOMAIN sent :
        (i > 1 /\ sent[i].resend /\ sent[i - 1].resend /\ sent[i - 1].effort = "low" /\ Wire(configured) # "low")
            => sent[i].effort = Wire(configured)

\* A note's request changes the effort only to `low`.
ResendLowersOnlyToLow ==
    \A i \in DOMAIN sent :
        sent[i].resend => sent[i].effort \in {Wire(configured), "low"}
=============================================================================
