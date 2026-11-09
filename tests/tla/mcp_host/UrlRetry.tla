---- MODULE UrlRetry ----
\* How fx holds an MCP tool call that a 2025 server answered with
\* URLElicitationRequiredError (-32042), for one server and one call that
\* can ask.
\*
\* Code:
\*   - src/mcp/server.zig legacyDelivered: the URL elicitations a -32042
\*     answer lists reach the host first, as `.elicit` with required = TRUE,
\*     each in a free slot, then the call's `.called` failure.
\*   - src/mcp/core/elicitation.zig Table.step: a completion while the host
\*     shows the URL is kept (early) and told when the host accepts; one
\*     while it waits is told and frees the slot; decline and cancel free
\*     it; a session's end withdraws the shown ones and frees the rest
\*     without a word, so a later question may take the slot.
\*   - src/core/mcp_host/runtime.zig: `.elicit` required is kept for the
\*     call; `.called` failure holds the call and offers one consent question
\*     for all its URLs; `.answer` .url_consent accepts each
\*     (engine.answerElicitation) and offers the waiting question with the
\*     call's signal (a completion that came first is told just after the
\*     accept, and the model takes both in one step);
\*     `.elicitation_complete` counts a URL by its slot and completes the
\*     signal when every URL has come; a new question in a slot, or its
\*     withdrawal, drops the URL that slot held; `.answer` .url_wait calls
\*     again or ends the call with the error. It reads the signal first, so
\*     a Cancel chosen as the last completion came calls again: of the two
\*     steps the model allows then, AutoRetry is the one the code takes.
\*   - src/core/mcp/elicitation_interaction.zig answerLegacyUrlCompletion:
\*     the waiting question ends at the signal, the user's choice, or the
\*     question deadline, which is Cancel.
\*
\* Guard = TRUE is that code. Guard = FALSE is the code before it, which
\* ended the call at the error, so no URL could be opened and called again.
EXTENDS Naturals, FiniteSets

CONSTANTS
    Urls,       \* URLs the error lists
    Slots,      \* the engine's elicitation slots
    MaxCalls,   \* tools/call sends; the last one is answered
    Guard       \* BOOLEAN

Js == 1..Urls
SlotIds == 0..(Slots - 1)
NoSlot == Slots

VARIABLES
    calls,      \* tools/call sent
    phase,      \* "calling", "consent", "waiting", "done"
    slotOf,     \* the call's record: URL j's slot, NoSlot once dropped
    seen,       \* the call counted URL j's completion
    eng,        \* the engine's slot s: "free", "shown", "early", "waiting"
    ownCall,    \* the call send whose URL slot s holds; 0: another question
    ownUrl,     \* which of its URLs
    truly,      \* ghost: the server completed this round's URL j
    signal,     \* the waiting question's signal: "pending", "completed"
    consented,  \* ghost: the user opened this round's URLs
    said,       \* ghost: the user's last waiting choice
    retriedBy,  \* ghost: what the last call again rested on
    proof,      \* ghost: the state that call again saw
    ended       \* how the call ended

vars == <<calls, phase, slotOf, seen, eng, ownCall, ownUrl, truly, signal, consented, said, retriedBy, proof, ended>>

Mine == {s \in SlotIds : ownCall[s] = calls /\ eng[s] \in {"shown", "early"} /\ \E j \in Js : slotOf[j] = s}

TypeOK ==
    /\ calls \in 1..MaxCalls
    /\ phase \in {"calling", "consent", "waiting", "done"}
    /\ slotOf \in [Js -> 0..Slots]
    /\ seen \in [Js -> BOOLEAN]
    /\ eng \in [SlotIds -> {"free", "shown", "early", "waiting"}]
    /\ ownCall \in [SlotIds -> 0..MaxCalls]
    /\ ownUrl \in [SlotIds -> 0..Urls]
    /\ truly \in [Js -> BOOLEAN]
    /\ signal \in {"pending", "completed"}
    /\ consented \in BOOLEAN
    /\ said \in {"none", "retry", "cancel"}
    /\ retriedBy \in {"none", "completions", "manual"}
    /\ proof \in [consented : BOOLEAN, said : {"none", "retry", "cancel"}, all : BOOLEAN]
    /\ ended \in {"none", "result", "declined", "cancelled", "fx"}

Init ==
    /\ calls = 1
    /\ phase = "calling"
    /\ slotOf = [j \in Js |-> NoSlot]
    /\ seen = [j \in Js |-> FALSE]
    /\ eng = [s \in SlotIds |-> "free"]
    /\ ownCall = [s \in SlotIds |-> 0]
    /\ ownUrl = [s \in SlotIds |-> 0]
    /\ truly = [j \in Js |-> FALSE]
    /\ signal = "pending"
    /\ consented = FALSE
    /\ said = "none"
    /\ retriedBy = "none"
    /\ proof = [consented |-> FALSE, said |-> "none", all |-> FALSE]
    /\ ended = "none"

\* The server answers the call with -32042, listing Urls URL elicitations.
ServerRequires ==
    /\ phase = "calling"
    /\ calls < MaxCalls
    /\ \E f \in [Js -> SlotIds] :
        /\ \A j \in Js : eng[f[j]] = "free"
        /\ \A j, k \in Js : j # k => f[j] # f[k]
        /\ eng' = [s \in SlotIds |-> IF \E j \in Js : f[j] = s THEN "shown" ELSE eng[s]]
        /\ ownCall' = [s \in SlotIds |-> IF \E j \in Js : f[j] = s THEN calls ELSE ownCall[s]]
        /\ ownUrl' = [s \in SlotIds |-> IF \E j \in Js : f[j] = s THEN CHOOSE j \in Js : f[j] = s ELSE ownUrl[s]]
        /\ slotOf' = f
    /\ seen' = [j \in Js |-> FALSE]
    /\ truly' = [j \in Js |-> FALSE]
    /\ consented' = FALSE
    /\ signal' = "pending"
    /\ IF Guard
       THEN /\ phase' = "consent"
            /\ ended' = ended
       ELSE /\ phase' = "done"
            /\ ended' = "fx"
    /\ UNCHANGED <<calls, said, retriedBy, proof>>

ServerAnswers ==
    /\ phase = "calling"
    /\ phase' = "done"
    /\ ended' = "result"
    /\ UNCHANGED <<calls, slotOf, seen, eng, ownCall, ownUrl, truly, signal, consented, said, retriedBy, proof>>

\* The server completes the URL elicitation slot s holds.
ServerCompletes(s) ==
    /\ eng[s] \in {"shown", "waiting"}
    /\ truly' = IF ownCall[s] = calls THEN [truly EXCEPT ![ownUrl[s]] = TRUE] ELSE truly
    /\ IF eng[s] = "shown"
       THEN /\ eng' = [eng EXCEPT ![s] = "early"]
            /\ UNCHANGED <<ownCall, ownUrl, seen, signal>>
       ELSE /\ eng' = [eng EXCEPT ![s] = "free"]
            /\ ownCall' = [ownCall EXCEPT ![s] = 0]
            /\ ownUrl' = [ownUrl EXCEPT ![s] = 0]
            \* The host hears `.elicitation_complete` for slot s.
            /\ seen' = [j \in Js |-> seen[j] \/ slotOf[j] = s]
            /\ signal' = IF phase = "waiting" /\ \A j \in Js : seen'[j] THEN "completed" ELSE signal
    /\ UNCHANGED <<calls, phase, slotOf, consented, said, retriedBy, proof, ended>>

\* Another question takes a free slot: another call's, or the server's own.
OtherAsks(s) ==
    /\ eng[s] = "free"
    /\ eng' = [eng EXCEPT ![s] = "shown"]
    /\ slotOf' = IF Guard THEN [j \in Js |-> IF slotOf[j] = s THEN NoSlot ELSE slotOf[j]] ELSE slotOf
    /\ UNCHANGED <<calls, phase, seen, ownCall, ownUrl, truly, signal, consented, said, retriedBy, proof, ended>>

OtherAccepted(s) ==
    /\ ownCall[s] = 0
    /\ eng[s] = "shown"
    /\ eng' = [eng EXCEPT ![s] = "waiting"]
    /\ UNCHANGED <<calls, phase, slotOf, seen, ownCall, ownUrl, truly, signal, consented, said, retriedBy, proof, ended>>

OtherEnds(s) ==
    /\ ownCall[s] = 0
    /\ eng[s] # "free"
    /\ eng' = [eng EXCEPT ![s] = "free"]
    /\ UNCHANGED <<calls, phase, slotOf, seen, ownCall, ownUrl, truly, signal, consented, said, retriedBy, proof, ended>>

\* The session ends: shown URLs are withdrawn, and the host drops them;
\* the ones waiting are freed without a word.
SessionEnds ==
    /\ \E s \in SlotIds : eng[s] # "free"
    /\ eng' = [s \in SlotIds |-> "free"]
    /\ ownCall' = [s \in SlotIds |-> 0]
    /\ ownUrl' = [s \in SlotIds |-> 0]
    /\ slotOf' = [j \in Js |-> IF slotOf[j] # NoSlot /\ eng[slotOf[j]] \in {"shown", "early"} THEN NoSlot ELSE slotOf[j]]
    /\ UNCHANGED <<calls, phase, seen, truly, signal, consented, said, retriedBy, proof, ended>>

\* fx calls the tool again; `choice` is what the user chose last.
Again(why, choice) ==
    /\ calls' = calls + 1
    /\ phase' = "calling"
    /\ retriedBy' = why
    /\ proof' = [consented |-> consented, said |-> choice, all |-> \A j \in Js : seen[j]]
    /\ slotOf' = [j \in Js |-> NoSlot]
    /\ seen' = [j \in Js |-> FALSE]
    /\ signal' = "pending"

\* Consent: Open URL for every URL. A completion that came first is told now.
UserAccepts ==
    /\ phase = "consent"
    /\ LET early == {s \in Mine : eng[s] = "early"}
           seen1 == [j \in Js |-> seen[j] \/ slotOf[j] \in early]
       IN /\ eng' = [s \in SlotIds |-> IF s \in early THEN "free" ELSE IF s \in Mine THEN "waiting" ELSE eng[s]]
          /\ ownCall' = [s \in SlotIds |-> IF s \in early THEN 0 ELSE ownCall[s]]
          /\ ownUrl' = [s \in SlotIds |-> IF s \in early THEN 0 ELSE ownUrl[s]]
          /\ seen' = seen1
          /\ signal' = IF \A j \in Js : seen1[j] THEN "completed" ELSE "pending"
    /\ phase' = "waiting"
    /\ consented' = TRUE
    /\ UNCHANGED <<calls, slotOf, truly, said, retriedBy, proof, ended>>

\* Consent: Decline, or Cancel (the question's deadline too).
UserRefuses(how) ==
    /\ phase = "consent"
    /\ eng' = [s \in SlotIds |-> IF s \in Mine THEN "free" ELSE eng[s]]
    /\ ownCall' = [s \in SlotIds |-> IF s \in Mine THEN 0 ELSE ownCall[s]]
    /\ ownUrl' = [s \in SlotIds |-> IF s \in Mine THEN 0 ELSE ownUrl[s]]
    /\ phase' = "done"
    /\ ended' = how
    /\ UNCHANGED <<calls, slotOf, seen, truly, signal, consented, said, retriedBy, proof>>

\* The signal closed the waiting question: fx calls again on its own.
AutoRetry ==
    /\ phase = "waiting"
    /\ signal = "completed"
    /\ Again("completions", said)
    /\ UNCHANGED <<eng, ownCall, ownUrl, truly, consented, said, ended>>

\* "I completed it / Retry".
UserRetries ==
    /\ phase = "waiting"
    /\ said' = "retry"
    /\ Again("manual", "retry")
    /\ UNCHANGED <<eng, ownCall, ownUrl, truly, consented, ended>>

\* "Cancel", or the question's deadline.
UserCancels ==
    /\ phase = "waiting"
    /\ said' = "cancel"
    /\ phase' = "done"
    /\ ended' = "cancelled"
    /\ UNCHANGED <<calls, slotOf, seen, eng, ownCall, ownUrl, truly, signal, consented, retriedBy, proof>>

Next ==
    \/ ServerRequires
    \/ ServerAnswers
    \/ \E s \in SlotIds : ServerCompletes(s) \/ OtherAsks(s) \/ OtherAccepted(s) \/ OtherEnds(s)
    \/ SessionEnds
    \/ UserAccepts
    \/ \E how \in {"declined", "cancelled"} : UserRefuses(how)
    \/ AutoRetry
    \/ UserRetries
    \/ UserCancels

\* Every question ends by its deadline at the latest; the server answers.
Fairness ==
    /\ WF_vars(AutoRetry)
    /\ WF_vars(UserCancels)
    /\ WF_vars(UserRefuses("cancelled"))
    /\ WF_vars(ServerRequires \/ ServerAnswers)

Spec == Init /\ [][Next]_vars /\ Fairness

\* The call counts only the server's completion of its own URLs, even when
\* a later question takes a slot one of them held.
CountsOwnCompletions == \A j \in Js : seen[j] => truly[j]

\* While it waits, every URL the server completed is counted.
SeenWhenDone == phase = "waiting" => \A j \in Js : (truly[j] /\ slotOf[j] # NoSlot) => seen[j]

\* The signal completes only once every URL has come.
SignalTruth == signal = "completed" => \A j \in Js : seen[j]

\* fx calls again only after the user opened the URLs, and then only when
\* every completion came or the user chose Retry.
RetryOnlyAfterProof ==
    retriedBy # "none" =>
        /\ proof.consented
        /\ proof.said # "cancel"
        /\ retriedBy = "manual" => proof.said = "retry"
        /\ retriedBy = "completions" => proof.all

\* Stated for users: a call the server needs a URL for ends by the user's
\* choice or the server's answer, never by fx alone.
EndsByUserOrServer == ended # "fx"

\* A held call ends: it calls again or it is over.
HeldCallEnds == (phase \in {"consent", "waiting"}) ~> (phase \in {"calling", "done"})
====
