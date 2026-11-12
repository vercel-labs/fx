-------------------------- MODULE AcpSessionTarget --------------------------
(***************************************************************************)
(* How fx's ACP server answers a request that names a session, following  *)
(* ACP v1's error rules (src/acp/server.zig, src/acp/sessions.zig,        *)
(* src/acp/jsonrpc.zig).                                                  *)
(*                                                                         *)
(*  - A request that names an open session works. A prompt that ends     *)
(*    saves the session, as fx saves a chat at its first turn.            *)
(*  - With `Many`, as on fx acp, session/new, load, and resume leave every *)
(*    other open session open (`AcpSessions.tla` models their turns).     *)
(*    Without it, as on libfx's minimal kernel, the session they open is   *)
(*    the only one open.                                                  *)
(*  - A request that names a session that doesn't exist or isn't open    *)
(*    fails with -32002, "Resource not found", and `data.sessionId` set   *)
(*    to the id it named. For session/load and session/resume, a session  *)
(*    exists once it is saved.                                            *)
(*  - A request with no sessionId, or one that isn't a string, fails      *)
(*    with -32602, "Invalid params".                                      *)
(*  - session/close of an open session closes it. Closing a session      *)
(*    that isn't open succeeds with {} and changes nothing.               *)
(*  - A request frame over the 8 MiB limit fails with -32600, and the     *)
(*    connection goes on.                                                 *)
(*  - fx never answers -32000, which ACP v1 assigns to "Authentication    *)
(*    required".                                                          *)
(*  - The SDK's _sh.fx/* methods follow the same rules. Only libfx's      *)
(*    minimal kernel, in the native addon, serves them. For the open      *)
(*    session, _sh.fx/session/steer with no turn running fails with       *)
(*    -32600, and the driver sends _sh.fx/session/restore an empty        *)
(*    checkpoint, which fails with -32602.                                *)
(*  - A request that fails changes nothing.                               *)
(*                                                                         *)
(* `Fixed` set to FALSE gives fx before these rules (origin/main at       *)
(* 15dab7bb4): -32602 with no data for a session that isn't open, an      *)
(* error for closing one, and -32000 for an oversized frame. The          *)
(* AcpSessionTargetBefore-*.cfg configs show each rule failing then, and   *)
(* AcpSessionTargetBefore-many.cfg shows one open session at a time,      *)
(* fx acp before many sessions (#1786 at 13bb8f7a4).                      *)
(*                                                                         *)
(* `last` is what the client observes for the latest step. A test client  *)
(* creates at most two sessions, A and B, in that order; X names a        *)
(* session that never exists, "none" a request with no sessionId, and     *)
(* "bad" one whose sessionId is a number. One fx acp process runs at a    *)
(* time; Restart starts a new one, which has no session open.             *)
(*                                                                         *)
(* tests/tla/drivers/acp/session_target/driver.ts runs the real fx acp    *)
(* through plans of these steps and has TLC check each run against this   *)
(* model through AcpSessionTargetTrace.tla.                                *)
(***************************************************************************)
EXTENDS Integers, Sequences

CONSTANTS Fixed,  \* TRUE: ACP v1's rules; FALSE: fx before them
          Many    \* TRUE: many sessions open at once; FALSE: one

ASSUME Fixed \in BOOLEAN /\ Many \in BOOLEAN

IdSeq == <<"A", "B">>
Ids == {IdSeq[k] : k \in 1..Len(IdSeq)}
Unknown == "X"
Missing == {"none", "bad"}
Targets == Ids \cup {Unknown} \cup Missing

\* Requests that act on the open session, and what each answers when it works.
LibfxOps == {"snapshot", "checkpoint", "handoff", "withdraw", "followup", "steer", "restore"}
TargetOps == {"prompt", "mode", "config", "cancel"} \cup LibfxOps
RestoreOps == {"load", "resume"}
NamingOps == TargetOps \cup RestoreOps \cup {"close"}
Answer(op) ==
    CASE op = "prompt" -> "end_turn"
      [] op = "mode"   -> "null"
      [] op = "config" -> "object"
      [] op = "cancel" -> "null"
      [] op = "snapshot" -> "object"
      [] op = "checkpoint" -> "object"
      [] op = "handoff" -> "null"
      [] op = "withdraw" -> "object"
      [] op = "followup" -> "null"

VARIABLES open,     \* the sessions open in the running process
          created,  \* the sessions the client created
          saved,    \* the sessions fx saved, which a later load can open
          nextNew,  \* the index in IdSeq of the next session/new
          last      \* what the client observed for the latest step
vars == <<open, created, saved, nextNew, last>>
state == <<open, created, saved, nextNew>>

Obs(op, arg, ok, code, dataSid, result) ==
    [op |-> op, arg |-> arg, ok |-> ok, code |-> code, dataSid |-> dataSid, result |-> result]

\* The answer for a session that doesn't exist or isn't open.
NotFound(op, t) ==
    IF Fixed THEN Obs(op, t, FALSE, -32002, TRUE, "none")
    ELSE Obs(op, t, FALSE, -32602, FALSE, "none")

InvalidParams(op, t) == Obs(op, t, FALSE, -32602, FALSE, "none")

\* The two requests that fail for the open session in the driver's runs.
OpenFails == {"steer", "restore"}
OpenFailure(op, t) ==
    IF op = "steer" THEN Obs(op, t, FALSE, -32600, FALSE, "none")
    ELSE Obs(op, t, FALSE, -32602, FALSE, "none")

\* The sessions open once `id` opens.
Opened(id) == IF Many THEN open \cup {id} ELSE {id}

Init ==
    /\ open = {}
    /\ created = {}
    /\ saved = {}
    /\ nextNew = 1
    /\ last = Obs("restart", "none", TRUE, 0, FALSE, "none")

NewSession ==
    /\ nextNew <= Len(IdSeq)
    /\ LET id == IdSeq[nextNew] IN
           /\ open' = Opened(id)
           /\ created' = created \cup {id}
           /\ last' = Obs("new", id, TRUE, 0, FALSE, "object")
    /\ nextNew' = nextNew + 1
    /\ UNCHANGED saved

\* A new fx acp process: nothing is open, and saved sessions stay saved.
Restart ==
    /\ open' = {}
    /\ last' = Obs("restart", "none", TRUE, 0, FALSE, "none")
    /\ UNCHANGED <<created, saved, nextNew>>

Target(op, t) ==
    CASE t \in Missing ->
             /\ last' = InvalidParams(op, t)
             /\ UNCHANGED state
      [] t \in open /\ op \in OpenFails ->
             /\ last' = OpenFailure(op, t)
             /\ UNCHANGED state
      [] t \in open ->
             /\ last' = Obs(op, t, TRUE, 0, FALSE, Answer(op))
             /\ saved' = IF op = "prompt" THEN saved \cup {t} ELSE saved
             /\ UNCHANGED <<open, created, nextNew>>
      [] OTHER ->
             /\ last' = NotFound(op, t)
             /\ UNCHANGED state

Close(t) ==
    CASE t \in Missing ->
             /\ last' = InvalidParams("close", t)
             /\ UNCHANGED state
      [] t \in open ->
             /\ last' = Obs("close", t, TRUE, 0, FALSE, "empty")
             /\ open' = open \ {t}
             /\ UNCHANGED <<created, saved, nextNew>>
      [] OTHER ->
             /\ last' = IF Fixed THEN Obs("close", t, TRUE, 0, FALSE, "empty")
                        ELSE Obs("close", t, FALSE, -32602, FALSE, "none")
             /\ UNCHANGED state

\* session/load and session/resume open a saved session, or reuse an open
\* one.
Restore(op, t) ==
    CASE t \in Missing ->
             /\ last' = InvalidParams(op, t)
             /\ UNCHANGED state
      [] t \in saved \/ t \in open ->
             /\ last' = Obs(op, t, TRUE, 0, FALSE, "object")
             /\ open' = Opened(t)
             /\ UNCHANGED <<created, saved, nextNew>>
      [] OTHER ->
             /\ last' = NotFound(op, t)
             /\ UNCHANGED state

\* A request frame over the 8 MiB limit. fx answers with a null id.
Oversize ==
    /\ last' = Obs("oversize", "none", FALSE, IF Fixed THEN -32600 ELSE -32000, FALSE, "none")
    /\ UNCHANGED state

Next ==
    \/ NewSession
    \/ Restart
    \/ Oversize
    \/ \E op \in TargetOps, t \in Targets : Target(op, t)
    \/ \E t \in Targets : Close(t)
    \/ \E op \in RestoreOps, t \in Targets : Restore(op, t)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Safety properties. *)

TypeOK ==
    /\ open \subseteq Ids
    /\ created \subseteq Ids
    /\ saved \subseteq created
    /\ nextNew \in 1..(Len(IdSeq) + 1)
    /\ last.op \in NamingOps \cup {"new", "restart", "oversize"}

\* -32000 means "Authentication required" in ACP v1, and fx asks for none.
NeverAuthCode == last.code # -32000

OversizeIs32600 == last.op = "oversize" => /\ ~last.ok
                                          /\ last.code = -32600

MissingIdIs32602 ==
    (last.op \in NamingOps /\ last.arg \in Missing) =>
        /\ ~last.ok
        /\ last.code = -32602
        /\ ~last.dataSid

\* A session that doesn't exist or isn't open, named by a request.
Absent(op, t) ==
    /\ t \notin Missing
    /\ t \notin open
    /\ op \in RestoreOps => t \notin saved

UnknownSessionAnswer ==
    [][(last'.op \in TargetOps \cup RestoreOps /\ Absent(last'.op, last'.arg)) =>
           /\ ~last'.ok
           /\ last'.code = -32002
           /\ last'.dataSid]_vars

CloseIdempotent ==
    [][(last'.op = "close" /\ last'.arg \notin Missing /\ last'.arg \notin open) =>
           /\ last'.ok
           /\ last'.result = "empty"
           /\ open' = open]_vars

CloseClosesOpen ==
    [][(last'.op = "close" /\ last'.arg \in open) =>
           /\ last'.ok
           /\ last'.result = "empty"
           /\ open' = open \ {last'.arg}]_vars

OpenSessionAnswers ==
    [][(last'.op \in TargetOps \ OpenFails /\ last'.arg \in open) =>
           /\ last'.ok
           /\ last'.result = Answer(last'.op)]_vars

SavedSessionOpens ==
    [][(last'.op \in RestoreOps /\ last'.arg \in saved) =>
           /\ last'.ok
           /\ last'.arg \in open']_vars

\* Opening or restoring a session leaves every other open session open.
OthersStayOpen ==
    [][(last'.op \in {"new"} \cup RestoreOps /\ last'.ok) => open \subseteq open']_vars

ErrorChangesNothing == [][~last'.ok => UNCHANGED state]_vars
=============================================================================
