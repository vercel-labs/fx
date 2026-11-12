---------------------------- MODULE AcpSessions ----------------------------
(***************************************************************************)
(* How one fx acp connection holds many sessions (src/acp/server.zig,     *)
(* src/acp/sessions.zig, src/acp/prompt.zig), following ACP v1's session  *)
(* setup: "one Agent can run several independent sessions", and a        *)
(* session's cwd "MUST be used for the session".                          *)
(*                                                                         *)
(*  - session/new opens a session and leaves every other one open.        *)
(*  - Each open session runs its own turn, so two turns can run at once.  *)
(*    A prompt to a session whose turn runs fails with -32600, as before. *)
(*  - A cancel, close, load, resume, or prompt for one session never      *)
(*    changes another session.                                            *)
(*  - A turn's updates carry its own sessionId, and its tools act in its  *)
(*    own session's workspace.                                            *)
(*  - session/load or session/resume of a session that is already open   *)
(*    reuses it: its turn keeps running, and load replays its history     *)
(*    again (Q108). The open session keeps its workspace, so a request    *)
(*    that names another one fails and changes nothing.                   *)
(*  - fx saves a session as its first turn starts, so a later load can    *)
(*    open it even when that turn never ended.                            *)
(*  - session/close of a running session stops its turn and answers its  *)
(*    prompt.                                                             *)
(*                                                                         *)
(* `Rules` set to FALSE gives fx before these rules (#1786 at 13bb8f7a4): *)
(* one session is open, and session/new, load, or resume of any session   *)
(* stops the running turn and replaces the open session. The              *)
(* AcpSessionsToday-*.cfg configs show which rule fails then.             *)
(*                                                                         *)
(* The client opens at most two sessions, A and B, in that order, each    *)
(* with a workspace from Ws. A prompt is a key <<s, n>>: the n-th prompt  *)
(* the client sends to session s. `bound` is the one workspace the        *)
(* process used before these rules: the cwd of the latest session it      *)
(* opened.                                                                *)
(*                                                                         *)
(* tests/tla/drivers/acp/sessions/driver.ts runs the real fx acp through  *)
(* plans of these steps and has TLC check each run against this model     *)
(* through AcpSessionsTrace.tla.                                          *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Rules,       \* TRUE: many sessions; FALSE: fx before S8c
          MaxPrompts,  \* prompts the client sends to each session
          MaxLoads     \* load and resume requests in a run

ASSUME /\ Rules \in BOOLEAN
       /\ MaxPrompts \in Nat \ {0}
       /\ MaxLoads \in Nat

IdSeq == <<"A", "B">>
Sids == {"A", "B"}
Ws == {"W1", "W2"}
Keys == Sids \X (1..MaxPrompts)
None == "none"

\* What a prompt's request answers. "pending" until fx answers it.
Answers == {"pending", "end_turn", "cancelled", "busy", "notfound"}

VARIABLES open,      \* the sessions open on the connection
          saved,     \* the sessions fx saved, which a later load can open
          nextNew,   \* the index in IdSeq of the next session/new
          ws,        \* the workspace each session was opened with
          bound,     \* the process workspace before these rules
          turn,      \* "idle" or "running", per session
          cur,       \* the number of the prompt each session's turn runs, or 0
          sent,      \* how many prompts the client sent to each session
          answer,    \* the answer to each prompt
          tags,      \* <<prompt, sessionId>> for each update a turn sent
          writes,    \* what each tool write used and should have used
          replays,   \* how often load replayed each session's history
          loads,     \* load and resume requests so far
          last       \* the latest step: its op, the session it named, and
                     \* whether it worked
vars == <<open, saved, nextNew, ws, bound, turn, cur, sent, answer, tags, writes, replays, loads, last>>

Init ==
    /\ open = {}
    /\ saved = {}
    /\ nextNew = 1
    /\ ws = [s \in Sids |-> None]
    /\ bound = None
    /\ turn = [s \in Sids |-> "idle"]
    /\ cur = [s \in Sids |-> 0]
    /\ sent = [s \in Sids |-> 0]
    /\ answer = [k \in Keys |-> "pending"]
    /\ tags = {}
    /\ writes = {}
    /\ replays = [s \in Sids |-> 0]
    /\ loads = 0
    /\ last = [op |-> "init", sid |-> None, ok |-> TRUE]

\* The key of the prompt session s's turn runs.
Run(s) == <<s, cur[s]>>

\* Before these rules, opening a session stops the running turn of every
\* other open session and closes it.
Replaced(s) == {t \in open : t # s}
StopOthers(s) ==
    /\ turn' = [t \in Sids |-> IF t \in Replaced(s) THEN "idle" ELSE turn[t]]
    /\ cur' = [t \in Sids |-> IF t \in Replaced(s) THEN 0 ELSE cur[t]]
    /\ answer' = [k \in Keys |->
                    IF \E t \in Replaced(s) : turn[t] = "running" /\ Run(t) = k
                    THEN "cancelled" ELSE answer[k]]

NewSession(w) ==
    /\ nextNew <= Len(IdSeq)
    /\ LET s == IdSeq[nextNew] IN
           /\ IF Rules
              THEN /\ open' = open \cup {s}
                   /\ UNCHANGED <<turn, cur, answer>>
              ELSE /\ open' = {s}
                   /\ StopOthers(s)
           /\ ws' = [ws EXCEPT ![s] = w]
           /\ last' = [op |-> "new", sid |-> s, ok |-> TRUE]
    /\ bound' = w
    /\ nextNew' = nextNew + 1
    /\ UNCHANGED <<saved, sent, tags, writes, replays, loads>>

Prompt(s) ==
    /\ sent[s] < MaxPrompts
    /\ LET k == <<s, sent[s] + 1>> IN
           CASE s \notin open ->
                    /\ answer' = [answer EXCEPT ![k] = "notfound"]
                    /\ UNCHANGED <<turn, cur>>
             [] turn[s] = "running" ->
                    /\ answer' = [answer EXCEPT ![k] = "busy"]
                    /\ UNCHANGED <<turn, cur>>
             [] OTHER ->
                    /\ turn' = [turn EXCEPT ![s] = "running"]
                    /\ cur' = [cur EXCEPT ![s] = k[2]]
                    /\ UNCHANGED answer
    \* The turn opens on disk before the model is asked.
    /\ saved' = IF s \in open /\ turn[s] = "idle" THEN saved \cup {s} ELSE saved
    /\ sent' = [sent EXCEPT ![s] = sent[s] + 1]
    /\ last' = [op |-> "prompt", sid |-> s, ok |-> TRUE]
    /\ UNCHANGED <<open, nextNew, ws, bound, tags, writes, replays, loads>>

\* The session id an update of session s's turn carries.
Tag(s) == s

\* A running turn streams an update to the client.
Stream(s) ==
    /\ turn[s] = "running"
    /\ ~\E t \in tags : t[1] = Run(s)
    /\ tags' = tags \cup {<<Run(s), Tag(s)>>}
    /\ last' = [op |-> "stream", sid |-> s, ok |-> TRUE]
    /\ UNCHANGED <<open, saved, nextNew, ws, bound, turn, cur, sent, answer, writes, replays, loads>>

\* The workspace a tool of session s's turn acts in.
Used(s) == IF Rules THEN ws[s] ELSE bound

\* A running turn's tool writes a file in its workspace.
ToolWrite(s) ==
    /\ turn[s] = "running"
    /\ ~\E w \in writes : w.key = Run(s)
    /\ writes' = writes \cup {[key |-> Run(s), used |-> Used(s), own |-> ws[s]]}
    /\ last' = [op |-> "write", sid |-> s, ok |-> TRUE]
    /\ UNCHANGED <<open, saved, nextNew, ws, bound, turn, cur, sent, answer, tags, replays, loads>>

Finish(s) ==
    /\ turn[s] = "running"
    /\ turn' = [turn EXCEPT ![s] = "idle"]
    /\ cur' = [cur EXCEPT ![s] = 0]
    /\ answer' = [answer EXCEPT ![Run(s)] = "end_turn"]
    /\ last' = [op |-> "finish", sid |-> s, ok |-> TRUE]
    /\ UNCHANGED <<open, saved, nextNew, ws, bound, sent, tags, writes, replays, loads>>

\* session/cancel of session s. It is a notification, so it has no answer.
Cancel(s) ==
    /\ IF s \in open /\ turn[s] = "running"
       THEN /\ turn' = [turn EXCEPT ![s] = "idle"]
            /\ cur' = [cur EXCEPT ![s] = 0]
            /\ answer' = [answer EXCEPT ![Run(s)] = "cancelled"]
       ELSE UNCHANGED <<turn, cur, answer>>
    /\ last' = [op |-> "cancel", sid |-> s, ok |-> TRUE]
    /\ UNCHANGED <<open, saved, nextNew, ws, bound, sent, tags, writes, replays, loads>>

\* session/close of session s. Closing a session that isn't open succeeds
\* and changes nothing.
Close(s) ==
    /\ IF s \in open
       THEN /\ open' = open \ {s}
            /\ IF turn[s] = "running"
               THEN /\ turn' = [turn EXCEPT ![s] = "idle"]
                    /\ cur' = [cur EXCEPT ![s] = 0]
                    /\ answer' = [answer EXCEPT ![Run(s)] = "cancelled"]
               ELSE UNCHANGED <<turn, cur, answer>>
       ELSE UNCHANGED <<open, turn, cur, answer>>
    /\ last' = [op |-> "close", sid |-> s, ok |-> TRUE]
    /\ UNCHANGED <<saved, nextNew, ws, bound, sent, tags, writes, replays, loads>>

\* session/load (op "load") or session/resume (op "resume") of a saved
\* session s, naming workspace w.
Restore(op, s, w) ==
    /\ loads < MaxLoads
    /\ s \in saved
    /\ IF Rules
       THEN IF s \in open
            THEN IF w = ws[s]
                 THEN \* Reuse: the session keeps its turn and its workspace.
                      /\ replays' = IF op = "load" THEN [replays EXCEPT ![s] = replays[s] + 1] ELSE replays
                      /\ UNCHANGED <<open, ws, bound, turn, cur, answer>>
                 ELSE \* Another workspace: the request fails.
                      UNCHANGED <<open, ws, bound, turn, cur, answer, replays>>
            ELSE /\ open' = open \cup {s}
                 /\ ws' = [ws EXCEPT ![s] = w]
                 /\ bound' = w
                 /\ replays' = IF op = "load" THEN [replays EXCEPT ![s] = replays[s] + 1] ELSE replays
                 /\ UNCHANGED <<turn, cur, answer>>
       ELSE \* Before: every running turn stops, this one's too, and s
            \* becomes the one open session.
            /\ open' = {s}
            /\ turn' = [t \in Sids |-> "idle"]
            /\ cur' = [t \in Sids |-> 0]
            /\ answer' = [k \in Keys |->
                            IF \E t \in open : turn[t] = "running" /\ Run(t) = k
                            THEN "cancelled" ELSE answer[k]]
            /\ ws' = [ws EXCEPT ![s] = w]
            /\ bound' = w
            /\ replays' = IF op = "load" THEN [replays EXCEPT ![s] = replays[s] + 1] ELSE replays
    /\ loads' = loads + 1
    /\ last' = [op |-> op, sid |-> s, ok |-> ~(Rules /\ s \in open /\ w # ws[s])]
    /\ UNCHANGED <<saved, nextNew, sent, tags, writes>>

Next ==
    \/ \E w \in Ws : NewSession(w)
    \/ \E s \in Sids :
          \/ Prompt(s)
          \/ Stream(s)
          \/ ToolWrite(s)
          \/ Finish(s)
          \/ Cancel(s)
          \/ Close(s)
          \/ \E op \in {"load", "resume"}, w \in Ws : Restore(op, s, w)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Safety properties. *)

TypeOK ==
    /\ open \subseteq Sids
    /\ saved \subseteq Sids
    /\ nextNew \in 1..(Len(IdSeq) + 1)
    /\ ws \in [Sids -> Ws \cup {None}]
    /\ bound \in Ws \cup {None}
    /\ turn \in [Sids -> {"idle", "running"}]
    /\ cur \in [Sids -> 0..MaxPrompts]
    /\ sent \in [Sids -> 0..MaxPrompts]
    /\ answer \in [Keys -> Answers]
    /\ tags \subseteq Keys \X Sids
    /\ \A w \in writes : w.key \in Keys /\ w.used \in Ws \cup {None} /\ w.own \in Ws \cup {None}
    /\ replays \in [Sids -> 0..MaxLoads]
    /\ loads \in 0..MaxLoads

\* Only an open session runs a turn, and it runs the prompt it holds.
RunningIsOpen ==
    \A s \in Sids : turn[s] = "running" => /\ s \in open
                                            /\ cur[s] >= 1
                                            /\ answer[Run(s)] = "pending"

\* Every update a turn sends carries the id of the session it belongs to.
RoutedUpdates == \A t \in tags : t[2] = t[1][1]

\* A turn's tools act in their own session's workspace.
OwnWorkspace == \A w \in writes : w.used = w.own

\* Every prompt the client sent is answered, unless its turn still runs.
NothingLost ==
    \A k \in Keys :
        (k[2] <= sent[k[1]] /\ answer[k] = "pending") =>
            /\ turn[k[1]] = "running"
            /\ cur[k[1]] = k[2]

\* Shows that two turns can run at once: TLC finds a violation under the
\* rules (MCAcpSessionsOverlap.cfg), and none before them.
AtMostOneRunning == Cardinality({s \in Sids : turn[s] = "running"}) <= 1

\* A prompt's answer never changes once fx gave it.
AnsweredOnce == [][\A k \in Keys : answer[k] # "pending" => answer'[k] = answer[k]]_vars

\* A step that names session s leaves every other session as it was: still
\* open or still closed, with the same turn. session/new names the session
\* it opens.
OthersUntouched ==
    [][\A t \in Sids :
         t # last'.sid =>
            /\ (t \in open') = (t \in open)
            /\ turn'[t] = turn[t]
            /\ cur'[t] = cur[t]]_vars

\* session/load or session/resume of a session that is open keeps its turn
\* running and its prompt waiting.
ReuseKeepsTurn ==
    [][(last'.op \in {"load", "resume"} /\ last'.sid \in open) =>
         /\ last'.sid \in open'
         /\ turn'[last'.sid] = turn[last'.sid]
         /\ cur'[last'.sid] = cur[last'.sid]]_vars

=============================================================================
