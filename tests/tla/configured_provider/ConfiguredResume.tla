--------------------------- MODULE ConfiguredResume ---------------------------
(***************************************************************************)
(* Resuming a saved session whose custom connection the person edited in   *)
(* settings since (src/core/config/model_provider.zig `bind`,              *)
(* src/core/auth/credentials.zig `resolveForProvider`).                    *)
(*                                                                         *)
(* A session saves its connection's binding: the protocol, base_url, and   *)
(* auth (src/core/config/configured_provider.zig `binding_identity`). Its  *)
(* history may go only to that binding, so a resume on a changed binding   *)
(* sends nothing and says what changed and what to do. Edits outside the   *)
(* binding, such as timeouts, effort levels, and headers, do not stop a     *)
(* resume. A connection removed from settings is reported as unknown.      *)
(*                                                                         *)
(* Bug selects a planted defect for the mutation configs; \"none\" is the  *)
(* design and \"today\" is fx before the change, which reported a changed  *)
(* binding as a credential that was temporarily unavailable.               *)
(***************************************************************************)
EXTENDS FiniteSets

CONSTANTS Protocols, Urls, Auths, Bug

Bindings == [protocol: Protocols, url: Urls, auth: Auths]
\* Markers shaped unlike a binding, so TLC can compare them with one.
Removed == [removed |-> TRUE]
Nothing == [nothing |-> TRUE]
Outcomes == {"pending", "sent", "changed", "unknown", "temporary"}

ASSUME Bug \in {"none", "today", "sends", "strict"}

VARIABLES saved, current, other_edited, phase, outcome, sent_to
vars == <<saved, current, other_edited, phase, outcome, sent_to>>

TypeOK ==
    /\ saved \in Bindings
    /\ current \in Bindings \cup {Removed}
    /\ other_edited \in BOOLEAN
    /\ phase \in {"editing", "resumed"}
    /\ outcome \in Outcomes
    /\ sent_to \in Bindings \cup {Nothing}

InitWith(b) ==
    /\ saved = b
    /\ current = b
    /\ other_edited = FALSE
    /\ phase = "editing"
    /\ outcome = "pending"
    /\ sent_to = Nothing

Init == \E b \in Bindings : InitWith(b)

\* The person changes the connection's binding, removes the connection, or
\* changes a field outside the binding.
EditBinding(b) ==
    /\ phase = "editing"
    /\ current' = b
    /\ UNCHANGED <<saved, other_edited, phase, outcome, sent_to>>

RemoveConnection ==
    /\ phase = "editing"
    /\ current' = Removed
    /\ UNCHANGED <<saved, other_edited, phase, outcome, sent_to>>

EditOther ==
    /\ phase = "editing"
    /\ other_edited' = TRUE
    /\ UNCHANGED <<saved, current, phase, outcome, sent_to>>

\* fx resumes the session: what it sends and what it says.
Resume ==
    /\ phase = "editing"
    /\ phase' = "resumed"
    /\ IF current = Removed
          THEN /\ outcome' = "unknown" /\ sent_to' = Nothing
       ELSE IF current = saved /\ ~(Bug = "strict" /\ other_edited)
          THEN /\ outcome' = "sent" /\ sent_to' = current
       ELSE IF Bug = "sends"
          THEN /\ outcome' = "sent" /\ sent_to' = current
       ELSE IF Bug = "today"
          THEN /\ outcome' = "temporary" /\ sent_to' = Nothing
       ELSE /\ outcome' = "changed" /\ sent_to' = Nothing
    /\ UNCHANGED <<saved, current, other_edited>>

Next ==
    \/ \E b \in Bindings : EditBinding(b)
    \/ RemoveConnection
    \/ EditOther
    \/ Resume

Spec == Init /\ [][Next]_vars

\* The session's history goes only to the binding it was saved with.
HistoryStaysOnItsBinding == sent_to \in {saved, Nothing}

\* A changed binding is refused with what changed, never as a temporary
\* credential failure the person could wait out.
ChangedBindingSaysSo ==
    (phase = "resumed" /\ current \notin {saved, Removed}) => outcome = "changed"

\* An unchanged binding resumes, whatever else the person edited.
UnchangedBindingResumes ==
    (phase = "resumed" /\ current = saved) => outcome = "sent"

\* A connection that is gone keeps fx's unknown-connection message.
RemovedConnectionIsUnknown ==
    (phase = "resumed" /\ current = Removed) => outcome = "unknown"
=============================================================================
