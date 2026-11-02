------------------------- MODULE AcpPermissionModes -------------------------
(***************************************************************************)
(* fx's ACP permission-mode contract, matching the CLI's /permissions.     *)
(*                                                                         *)
(*  - ACP lists exactly the CLI's three modes, in this order: auto (the    *)
(*    default), ask, full-access, named Auto, Ask, Full access. Both the   *)
(*    `mode` config option and the older `modes` field list them and show  *)
(*    the same current mode.                                               *)
(*  - A session (new, resumed, or new in a fresh process) starts in the    *)
(*    profile's saved permission_mode as it is when the session starts;    *)
(*    an unset profile means auto. Another fx process saving a mode does   *)
(*    not change a session that is already open.                           *)
(*  - An accepted change, through session/set_config_option or the older  *)
(*    session/set_mode, switches the session and saves the mode as the     *)
(*    profile's default, as /permissions does in the CLI.                  *)
(*  - Any other value is rejected and changes nothing.                     *)
(*  - A prompt is enforced by the mode the client was shown: ask asks the  *)
(*    client, auto sends the action to fx's automatic reviewer, and full   *)
(*    access runs it without asking.                                       *)
(*  - Mode option values carry only ACP's fields (value, name,             *)
(*    description, _meta).                                                 *)
(*                                                                         *)
(* `last` is what the client observes for the latest step; `stored` is    *)
(* the profile's saved mode read back from settings.json after the step.  *)
(*                                                                         *)
(* Assumptions: one fx acp process at a time drives one active session;   *)
(* other fx processes may save a mode between steps (External); resume    *)
(* follows a prompt (fx saves a chat at its first turn).                   *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS Profiles,  \* saved modes a run may start from: Modes \cup {"unset"}
          Values     \* values a client may send: Modes plus unknown ones

ModeSeq == <<"auto", "ask", "full-access">>
Modes == {ModeSeq[k] : k \in 1..Len(ModeSeq)}
ModesCsv == "auto,ask,full-access"
NamesCsv == "Auto,Ask,Full access"
DefaultMode == "auto"

Eff(p) == IF p = "unset" THEN DefaultMode ELSE p

\* How the prompt probe (a shell call that writes a file) is handled. The
\* client declines permission requests and the reviewer clears the action.
Enforce(m) ==
    CASE m = "ask" -> "asked/no-run"
      [] m = "auto" -> "reviewed/ran"
      [] m = "full-access" -> "direct/ran"

VARIABLES profile, cur, saved, last
vars == <<profile, cur, saved, last>>

NoView == [current |-> "", legacy |-> "", listed |-> "", legacyListed |-> "",
           names |-> "", schemaOk |-> TRUE]

\* session/new and session/resume responses carry configOptions and modes.
SessionView(m) == [current |-> m, legacy |-> m, listed |-> ModesCsv,
                   legacyListed |-> ModesCsv, names |-> NamesCsv, schemaOk |-> TRUE]

\* set_config_option responses carry configOptions only.
ConfigView(m) == [SessionView(m) EXCEPT !.legacy = "n/a", !.legacyListed = "n/a"]

\* `fx status --json` lists the modes and the one a new session starts in.
StatusView(m) == ConfigView(m)

Obs(op, arg, ok, hasView, view, enforce, stored) ==
    [op |-> op, arg |-> arg, ok |-> ok, hasView |-> hasView, view |-> view,
     enforce |-> enforce, stored |-> stored]

Init ==
    /\ profile \in Profiles
    /\ cur = Eff(profile)
    /\ saved = FALSE
    /\ last = Obs("new", "none", TRUE, TRUE, SessionView(Eff(profile)), "none", profile)

SetConfig(v) ==
    IF v \in Modes
    THEN /\ cur' = v
         /\ profile' = v
         /\ last' = Obs("set", v, TRUE, TRUE, ConfigView(v), "none", v)
         /\ UNCHANGED saved
    ELSE /\ last' = Obs("set", v, FALSE, FALSE, NoView, "none", profile)
         /\ UNCHANGED <<profile, cur, saved>>

\* session/set_mode answers null, so the client sees no view.
SetLegacy(v) ==
    IF v \in Modes
    THEN /\ cur' = v
         /\ profile' = v
         /\ last' = Obs("legacy", v, TRUE, FALSE, NoView, "none", v)
         /\ UNCHANGED saved
    ELSE /\ last' = Obs("legacy", v, FALSE, FALSE, NoView, "none", profile)
         /\ UNCHANGED <<profile, cur, saved>>

Prompt ==
    /\ saved' = TRUE
    /\ last' = Obs("prompt", "none", TRUE, FALSE, NoView, Enforce(cur), profile)
    /\ UNCHANGED <<profile, cur>>

\* A new fx acp process resumes the session.
Resume ==
    /\ saved
    /\ LET resumed == Eff(profile) IN
           /\ cur' = resumed
           /\ last' = Obs("resume", "none", TRUE, TRUE, SessionView(resumed), "none", profile)
    /\ UNCHANGED <<profile, saved>>

\* A new fx acp process starts a new session.
Fresh ==
    /\ LET started == Eff(profile) IN
           /\ cur' = started
           /\ last' = Obs("fresh", "none", TRUE, TRUE, SessionView(started), "none", profile)
    /\ saved' = FALSE
    /\ UNCHANGED profile

\* session/new in the running process.
NewSession ==
    /\ LET opened == Eff(profile) IN
           /\ cur' = opened
           /\ last' = Obs("new", "none", TRUE, TRUE, SessionView(opened), "none", profile)
    /\ saved' = FALSE
    /\ UNCHANGED profile

\* Another fx process (the CLI's /permissions, or another ACP process)
\* saves a mode. The open session keeps its own, like a second CLI window.
External(v) ==
    /\ profile' = v
    /\ last' = Obs("other", v, TRUE, FALSE, NoView, "none", v)
    /\ UNCHANGED <<cur, saved>>

\* `fx status --json` in the workspace, run beside the ACP process.
Status ==
    /\ last' = Obs("status", "none", TRUE, TRUE, StatusView(Eff(profile)), "none", profile)
    /\ UNCHANGED <<profile, cur, saved>>

Next ==
    \/ \E v \in Values : SetConfig(v) \/ SetLegacy(v)
    \/ \E v \in Modes : External(v)
    \/ Prompt
    \/ Resume
    \/ Fresh
    \/ NewSession
    \/ Status

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Safety properties. EnforceTable restates the expected handling so a    *)
(* change to Enforce is caught.                                            *)

EnforceTable == [m \in Modes |->
                    IF m = "ask" THEN "asked/no-run"
                    ELSE IF m = "auto" THEN "reviewed/ran"
                    ELSE "direct/ran"]

SessionOps == {"new", "resume", "fresh"}
ChangeOps == {"set", "legacy"}

ListsExactlyCliModes ==
    last.hasView =>
        /\ last.view.listed = ModesCsv
        /\ last.view.names = NamesCsv
        /\ last.view.legacyListed \in {ModesCsv, "n/a"}

SchemaClean == last.hasView => last.view.schemaOk

ReportsEnforcedMode ==
    (last.hasView /\ last.op # "status") => /\ last.view.current = cur
                                            /\ last.view.legacy \in {cur, "n/a"}

\* Status describes the next session, which may differ from an open one.
StatusMatchesNextSession == last.op = "status" => last.view.current = Eff(profile)

SessionsStartFromProfile ==
    last.op \in SessionOps => /\ cur = Eff(profile)
                              /\ last.view.legacy = cur
                              /\ last.view.legacyListed = ModesCsv

DefaultIsAuto ==
    (last.op \in SessionOps /\ profile = "unset") => cur = "auto"

UnknownRejected == last.op \in ChangeOps => (last.ok <=> last.arg \in Modes)

ChangeIsSaved ==
    (last.op \in ChangeOps /\ last.ok) => /\ cur = last.arg
                                          /\ profile = last.arg

StoredIsProfile == last.stored = profile

PromptEnforcesMode == last.op = "prompt" => last.enforce = EnforceTable[cur]

TypeOK ==
    /\ profile \in Modes \cup {"unset"}
    /\ cur \in Modes
    /\ saved \in BOOLEAN

\* A rejected change leaves the session and the profile as they were.
RejectedChangesNothing ==
    [][(last'.op \in ChangeOps /\ ~last'.ok) => UNCHANGED <<profile, cur>>]_vars

\* Another process's choice never changes the open session.
OpenSessionKeepsMode == [][last'.op = "other" => cur' = cur]_vars

\* A session only enters full access when the user picks it, or when it
\* starts while full access is the saved mode.
FullAccessOnlyByChoice ==
    [][(cur' = "full-access" /\ cur # "full-access") =>
           \/ (last'.op \in ChangeOps /\ last'.arg = "full-access")
           \/ (last'.op \in SessionOps /\ profile' = "full-access")]_vars
=============================================================================
