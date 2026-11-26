----------------------------- MODULE RemoteRun -----------------------------
(***************************************************************************)
(* One run of fx's built-in remote runner: push, start the command, stream *)
(* it, bring changed files back, or stop it.                               *)
(*                                                                         *)
(* This models the code in src/core/runner/vercel/. Its                    *)
(* driver runs only with --next.                                           *)
(*                                                                         *)
(* One file stands for the repository. It is either tracked (pushed, and   *)
(* checked at bring back against its manifest record) or a `bring_back`    *)
(* output that git ignores (never pushed, and checked against its version  *)
(* at the start of this run or the version a bring back last wrote).       *)
(*                                                                         *)
(* The runner sends the start request once. When it is fully sent, the    *)
(* runner waits for the line that carries the command's id; no id is an    *)
(* unknown start, which ends with 255 and is never sent again. After a     *)
(* known start, Vercel may close a quiet stream while the command keeps    *)
(* running: the runner reattaches by reading, never by sending again, and  *)
(* exits 255 only if it loses contact. The command may change the file and *)
(* may never end on its own. The user may edit the Mac file at any time,   *)
(* and an overlapping run in the same repository may write its own         *)
(* version in the sandbox, with or without bringing it back; a file newer  *)
(* than this run's stamp comes back whichever run wrote it. A stop         *)
(* (SIGTERM to the runner) kills the remote command before the runner      *)
(* exits 143; before the id is known, it waits for the id or ends as an    *)
(* unknown start.                                                          *)
(*                                                                         *)
(* A tracked file the command deletes is gone from the sandbox. Its record *)
(* leaves at the bring back, so the next push sends this machine's copy (V9). *)
(*                                                                         *)
(* Before the start request, the sandbox session may end (410). A push     *)
(* answered that R is missing is repaired once (V5). A session call        *)
(* answered 404 or 410 resumes the session once, then the call runs again  *)
(* (V3). The start request itself answered 404 or 410 did not run: when    *)
(* the run's one recovery is unused, the session resumes and the request   *)
(* goes out once more; otherwise the run exits 125 and its record is       *)
(* marked, so the next run resumes first (V3). A record that says the      *)
(* session is dead is resumed before the first session call (ResumeFirst). *)
(* An isolated run never resumes (I3). PushMissing, PushGone, Send and     *)
(* ResumeFirst carry out the rows of src/core/runner/vercel/attempt.zig    *)
(* and sandbox.zig.                                                        *)
(*                                                                         *)
(* Exit codes: "cmd" the command's own, "125" did not run, "143" stopped,  *)
(* "255" result unknown.                                                   *)
(*                                                                         *)
(* Bug names one planted defect, or "none" for the design. check.sh lists  *)
(* each defect and the rule that must catch it.                            *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxMacEdits,  \* how often the user may edit the Mac file during one run
    MaxCloses,    \* how often Vercel may close a quiet stream during one run
    Bug

\* Versions of the file: 0 the start, 1 .. MaxMacEdits the user's edits on
\* the Mac, Changed this run's command output, Other an overlapping run's.
Changed == MaxMacEdits + 1
Other == MaxMacEdits + 2
Versions == 0..Other

Kinds    == {"tracked", "bring_back"}
Modes    == {"remote", "isolated"}
Phases   == {"start", "pushed", "awaiting", "streaming", "reattach", "unknown",
             "bringing", "done"}
Exits    == {"none", "cmd", "125", "143", "143u", "255"}
Commands == {"none", "running", "exited", "killed"}

VARIABLES
    kind,       \* what the file is
    phase,      \* the runner's step
    exit,       \* the runner's exit code, once done
    macV,       \* the Mac file's version
    startV,     \* the Mac file's version at run start (bring_back baseline)
    recordV,    \* tracked: the manifest's record (pushed or last written)
    broughtV,   \* bring_back: the version a bring back last wrote, or NoVersion
    remoteV,    \* the sandbox file's version
    cmdEdited,  \* this run's command changed the file
    otherWrote, \* an overlapping run wrote the file in the sandbox
    macEdits,   \* user edits so far
    userEdit,   \* the user edited the Mac file after its baseline point
    remoteCmd,  \* the remote command
    sends,      \* start requests that were fully sent
    stopReq,    \* SIGTERM reached the runner
    killSent,   \* the runner sent the remote kill
    overwrote,  \* bring back wrote over a user edit made after the baseline
    closes,     \* idle closes of the stream so far
    mode,       \* remote, or isolated (an isolated run never resumes)
    sessionEnded, \* the sandbox session ended and has not been resumed
    ends,       \* session ends so far, at most 3 in this model
    pushTries,  \* push requests sent so far, at most 4 in this model
    repaired,   \* the push's one V5 repair has been used
    resumed,    \* the one V3 resume of this run has been used
    resumeGets, \* recovery resume GETs sent so far
    posts,      \* start (exec) requests sent, fully or not
    marked,     \* the record says the session is dead and no resume has run yet (V3)
    sawGone     \* a session call of this run answered 404 or 410

vars == <<kind, phase, exit, macV, startV, recordV, broughtV, remoteV,
          cmdEdited, otherWrote, macEdits, userEdit, remoteCmd, sends, stopReq, killSent,
          overwrote, closes, mode, sessionEnded, ends, pushTries, repaired, resumed,
          resumeGets, posts, marked, sawGone>>

NoVersion == Other + 1

\* The sandbox file is gone: the command deleted it (V9). Only a tracked file takes this value.
Gone == NoVersion

Init ==
    /\ kind \in Kinds
    /\ mode \in Modes
    /\ phase = "start"
    /\ exit = "none"
    /\ macV = 0
    /\ startV = 0
    /\ recordV = 0
    /\ broughtV = NoVersion
    /\ remoteV = 0
    /\ cmdEdited = FALSE
    /\ otherWrote = FALSE
    /\ macEdits = 0
    /\ userEdit = FALSE
    /\ remoteCmd = "none"
    /\ sends = 0
    /\ stopReq = FALSE
    /\ killSent = FALSE
    /\ overwrote = FALSE
    /\ closes = 0
    /\ sessionEnded \in IF mode = "remote" THEN BOOLEAN ELSE {FALSE}
    /\ marked \in IF mode = "remote" THEN BOOLEAN ELSE {FALSE}
    /\ sawGone = FALSE
    /\ ends = 0
    /\ pushTries = 0
    /\ repaired = FALSE
    /\ resumed = FALSE
    /\ resumeGets = 0
    /\ posts = 0

Finish(code) == phase' = "done" /\ exit' = code

\* The sandbox session ends before the start request. At most 3 times per
\* run in this model.
SessionEnds ==
    /\ phase \in {"start", "pushed"}
    /\ ~sessionEnded
    /\ ends < 3
    /\ sessionEnded' = TRUE
    /\ ends' = ends + 1
    /\ UNCHANGED <<marked, sawGone, kind, phase, exit, macV, startV, recordV, broughtV, remoteV,
                   cmdEdited, otherWrote, macEdits, userEdit, remoteCmd, sends, stopReq,
                   killSent, overwrote, closes, mode, pushTries, repaired, resumed,
                   resumeGets, posts>>

\* A tracked file is pushed when it differs from its record; an ignored
\* bring_back output is never pushed. The push succeeds: its answer is ok.
PushOk ==
    /\ phase = "start"
    /\ ~stopReq
    /\ ~sessionEnded
    /\ (~marked \/ Bug = "skip_first_resume")
    /\ pushTries < 4
    /\ pushTries' = pushTries + 1
    /\ phase' = "pushed"
    /\ IF kind = "tracked"
       THEN /\ recordV' = macV
            /\ remoteV' = macV
       ELSE UNCHANGED <<marked, sawGone, recordV, remoteV>>
    /\ UNCHANGED <<marked, sawGone, kind, exit, macV, startV, broughtV, cmdEdited, otherWrote, macEdits,
                   userEdit, remoteCmd, sends, stopReq, killSent, overwrote, closes, mode,
                   sessionEnded, ends, repaired, resumed, resumeGets, posts>>

\* The push's answer says R is missing. The first time, the folder is repaired and
\* the push runs again (V5). The second time, the push is refused (125). Plan row:
\* cannot_open on push: repair when unused, else folder_missing.
PushMissing ==
    /\ phase = "start"
    /\ ~stopReq
    /\ ~sessionEnded
    /\ ~marked
    /\ pushTries < 4
    /\ pushTries' = pushTries + 1
    /\ IF ~repaired
       THEN /\ repaired' = TRUE
            /\ UNCHANGED <<marked, sawGone, phase, exit>>
       ELSE /\ Finish("125")
            /\ UNCHANGED repaired
    /\ UNCHANGED <<marked, sawGone, kind, macV, startV, recordV, broughtV, remoteV, cmdEdited, otherWrote,
                   macEdits, userEdit, remoteCmd, sends, stopReq, killSent, overwrote, closes,
                   mode, sessionEnded, ends, resumed, resumeGets, posts>>

\* A session call before exec answered 404 or 410. PushGone stands for every session call
\* before exec: first use, the marker read, the PATCH and the push (phase start), and the
\* extend before exec (phase pushed). The run has one recovery, and all of them share it (V3):
\* a remote run resumes once and runs the call again, otherwise the run is refused (125), and
\* the refusal leaves the record marked, so the next run resumes first (V3). A refusal in the
\* extend, or a second 404 or 410, posts no start request. Plan row: gone on a session call:
\* resume when remote and unused, else session_ended. Only a push try counts against the push
\* budget (PushesBounded); the extend is not a push. A record that says the session is dead is
\* resumed before any session call (ResumeFirst), so this step never sees it.
PushGone ==
    /\ phase \in {"start", "pushed"}
    /\ ~stopReq
    /\ sessionEnded
    /\ ~marked
    /\ pushTries < 4
    /\ sawGone' = TRUE
    /\ pushTries' = IF phase = "start" THEN pushTries + 1 ELSE pushTries
    /\ IF mode = "remote" /\ (~resumed \/ Bug = "unbounded_resume")
       THEN /\ resumed' = TRUE
            /\ resumeGets' = resumeGets + 1
            /\ sessionEnded' = FALSE
            /\ marked' = FALSE
            /\ UNCHANGED <<phase, exit>>
       ELSE /\ Finish("125")
            /\ marked' = (mode = "remote" /\ Bug # "no_mark")
            /\ UNCHANGED <<resumed, resumeGets, sessionEnded>>
    /\ UNCHANGED <<kind, macV, startV, recordV, broughtV, remoteV, cmdEdited, otherWrote,
                   macEdits, userEdit, remoteCmd, sends, stopReq, killSent, overwrote, closes,
                   mode, ends, repaired, posts>>

\* The push fails before it is fully sent: did not run.
PushFails ==
    /\ phase = "start"
    /\ ~marked
    /\ ~sessionEnded
    /\ pushTries < 4
    /\ pushTries' = pushTries + 1
    /\ Finish("125")
    /\ UNCHANGED <<marked, sawGone, kind, macV, startV, recordV, broughtV, remoteV, cmdEdited, otherWrote,
                   macEdits, userEdit, remoteCmd, sends, stopReq, killSent, overwrote, closes,
                   mode, sessionEnded, ends, repaired, resumed, resumeGets, posts>>

\* A stop before the start request was sent ends the run without sending it. A planted defect
\* reports it as an unconfirmed stop (143u), which only a sent request can produce.
StopBeforeSend ==
    /\ phase \in {"start", "pushed"}
    /\ stopReq
    /\ Finish(IF Bug = "stop_before_send_143u" THEN "143u" ELSE "143")
    /\ UNCHANGED <<marked, sawGone, kind, macV, startV, recordV, broughtV, remoteV, cmdEdited, otherWrote,
                   macEdits, userEdit, remoteCmd, sends, stopReq, killSent,
                   overwrote, closes, mode, sessionEnded, ends, pushTries, repaired, resumed,
                   resumeGets, posts>>

\* The start request is answered. Four answers:
\*   accepted: the request is fully sent, the command may or may not start, and the runner
\*     waits for the line that carries its id;
\*   404 or 410 before the command line, with the run's one recovery unused (remote): the
\*     command did not run. The session resumes once (PushGone), and the request goes out once
\*     more (V3, V6). A planted defect resends it when the recovery is spent (resend_twice);
\*   404 or 410 with the recovery spent, or an isolated run: the command did not run (125), and
\*     the record is marked for the next run (V3). A planted defect leaves it unmarked (no_mark);
\*   the request failed before it was fully sent: did not run (125).
Send ==
    /\ phase = "pushed"
    /\ ~stopReq
    /\ \/ /\ ~sessionEnded
          /\ sends' = sends + 1
          /\ posts' = posts + 1
          /\ remoteCmd' \in {"running", "none"}
          /\ phase' = "awaiting"
          /\ UNCHANGED <<exit, sessionEnded, marked, sawGone>>
       \/ /\ sessionEnded
          \* A 404 or 410 that is not yet resumed is followed by the resume, never by a second request.
          /\ (~sawGone \/ resumed)
          /\ posts' = posts + 1
          /\ sawGone' = TRUE
          /\ IF mode = "remote" /\ ~resumed
             THEN /\ phase' = "pushed"
                  /\ UNCHANGED <<exit, sessionEnded, marked>>
             ELSE IF Bug = "resend_twice" /\ mode = "remote"
                  THEN /\ phase' = "pushed"
                       /\ sessionEnded' = FALSE
                       /\ UNCHANGED <<exit, marked>>
                  ELSE /\ Finish("125")
                       /\ marked' = (mode = "remote" /\ Bug # "no_mark")
                       /\ UNCHANGED sessionEnded
          /\ UNCHANGED <<sends, remoteCmd>>
       \/ /\ ~sessionEnded
          /\ posts' = posts + 1
          /\ Finish("125")
          /\ UNCHANGED <<sends, remoteCmd, sessionEnded, marked, sawGone>>
    /\ UNCHANGED <<kind, macV, startV, recordV, broughtV, remoteV, cmdEdited, otherWrote,
                   macEdits, userEdit, killSent, stopReq, overwrote, closes, mode, ends,
                   pushTries, repaired, resumed, resumeGets>>

\* Before its first session call, a run whose record says the session is dead resumes it, and
\* the record is cleared. This resume does not use the run's one recovery: it answers no 404 or
\* 410 (V3, the expiry rule). Only remote runs carry a record.
ResumeFirst ==
    /\ phase = "start"
    /\ marked
    /\ marked' = FALSE
    /\ sessionEnded' = FALSE
    /\ UNCHANGED <<kind, phase, exit, macV, startV, recordV, broughtV, remoteV, cmdEdited,
                   otherWrote, macEdits, userEdit, remoteCmd, sends, stopReq, killSent,
                   overwrote, closes, mode, ends, pushTries, repaired, resumed, resumeGets,
                   posts, sawGone>>

Keep == UNCHANGED <<marked, sawGone, kind, exit, macV, startV, recordV, broughtV, remoteV,
                    cmdEdited, otherWrote, macEdits, userEdit, remoteCmd, sends, stopReq,
                    killSent, overwrote, closes, mode, sessionEnded, ends, pushTries,
                    repaired, resumed, resumeGets, posts>>

\* The id arrives: the start is known.
IdArrives ==
    /\ phase = "awaiting"
    /\ remoteCmd # "none"
    /\ phase' = "streaming"
    /\ Keep

\* No id within the deadline: the start is unknown.
NoId ==
    /\ phase = "awaiting"
    /\ phase' = "unknown"
    /\ Keep

\* An unknown start ends the run with 255, and the command is never sent
\* again: it may have run.
Unknown ==
    /\ phase = "unknown"
    /\ CASE Bug = "resend_unknown" -> phase' = "pushed" /\ UNCHANGED exit
         [] Bug = "unknown_as_125" -> Finish("125")
         [] OTHER -> Finish("255")
    /\ UNCHANGED <<marked, sawGone, kind, macV, startV, recordV, broughtV, remoteV, cmdEdited, otherWrote,
                   macEdits, userEdit, remoteCmd, sends, stopReq, killSent,
                   overwrote, closes, mode, sessionEnded, ends, pushTries, repaired, resumed,
                   resumeGets, posts>>

CmdEdits ==
    /\ remoteCmd = "running"
    /\ ~cmdEdited
    /\ remoteV' = Changed
    /\ cmdEdited' = TRUE
    /\ UNCHANGED <<marked, sawGone, kind, otherWrote, phase, exit, macV, startV, recordV, broughtV, macEdits,
                   userEdit, remoteCmd, sends, stopReq, killSent, overwrote,
                   closes, mode, sessionEnded, ends, pushTries, repaired, resumed,
                   resumeGets, posts>>

\* The command deletes a tracked file in the sandbox (V9). Its record stays until a
\* bring back finds the file gone.
CmdDeletes ==
    /\ kind = "tracked"
    /\ remoteCmd = "running"
    /\ ~cmdEdited
    /\ remoteV' = Gone
    /\ cmdEdited' = TRUE
    /\ UNCHANGED <<marked, sawGone, kind, otherWrote, phase, exit, macV, startV, recordV, broughtV,
                   macEdits, userEdit, remoteCmd, sends, stopReq, killSent, overwrote,
                   closes, mode, sessionEnded, ends, pushTries, repaired, resumed,
                   resumeGets, posts>>

CmdExits ==
    /\ remoteCmd = "running"
    /\ remoteCmd' = "exited"
    /\ UNCHANGED <<marked, sawGone, kind, phase, exit, macV, startV, recordV, broughtV, remoteV,
                   cmdEdited, otherWrote, macEdits, userEdit, sends, stopReq, killSent,
                   overwrote, closes, mode, sessionEnded, ends, pushTries, repaired, resumed,
                   resumeGets, posts>>

\* The stream ends with the command's exit code; then bring back starts.
StreamEnds ==
    /\ phase = "streaming"
    /\ ~stopReq
    /\ remoteCmd = "exited" \/ (Bug = "early_bring_back" /\ remoteCmd = "running")
    /\ phase' = "bringing"
    /\ Keep

\* Vercel closes a stream that carried no data for 340 s; the command keeps
\* running. At most MaxCloses times per run in this model.
IdleClose ==
    /\ phase = "streaming"
    /\ remoteCmd # "none"
    /\ closes < MaxCloses
    /\ closes' = closes + 1
    /\ phase' = IF Bug = "resend_after_close" THEN "pushed" ELSE "reattach"
    /\ UNCHANGED <<marked, sawGone, kind, exit, macV, startV, recordV, broughtV, remoteV,
                   cmdEdited, otherWrote, macEdits, userEdit, remoteCmd, sends, stopReq,
                   killSent, overwrote, mode, sessionEnded, ends, pushTries, repaired, resumed,
                   resumeGets, posts>>

\* Reattach reads the logs and waits for the exit code: safe to repeat. It
\* either connects and streaming goes on, or contact is lost after three
\* failed attempts in a row, folded into one step: 255.
Reattach ==
    /\ phase = "reattach"
    /\ \/ /\ phase' = "streaming"
          /\ UNCHANGED exit
       \/ Finish("255")
    /\ UNCHANGED <<marked, sawGone, kind, macV, startV, recordV, broughtV, remoteV, cmdEdited, otherWrote,
                   macEdits, userEdit, remoteCmd, sends, stopReq, killSent,
                   overwrote, closes, mode, sessionEnded, ends, pushTries, repaired, resumed,
                   resumeGets, posts>>

\* The Mac file is unchanged since its baseline: the manifest record for a
\* tracked file; for a bring_back output, its version at run start or the
\* version a bring back last wrote (an overlapping run's).
Unchanged ==
    IF kind = "tracked" THEN macV = recordV
    ELSE macV = startV \/ (macV = broughtV /\ Bug # "ignore_brought")

\* Changed in the sandbox since this run's stamp: a tracked file whose
\* sandbox copy differs from its record, or a bring_back output that this
\* run's command or an overlapping run wrote.
RemoteChanged ==
    IF kind = "tracked" THEN remoteV # recordV ELSE cmdEdited \/ otherWrote

BringBack ==
    /\ phase = "bringing"
    /\ IF kind = "tracked" /\ remoteV = Gone
       THEN \* V9: the sandbox no longer has the file. Its record leaves, so the next push sends
            \* this machine's copy, and the Mac file stays. The planted bug keeps the record.
            /\ recordV' = IF Bug = "keep_gone_record" THEN recordV ELSE NoVersion
            /\ UNCHANGED <<macV, overwrote, broughtV>>
       ELSE IF RemoteChanged
            THEN IF Unchanged \/ Bug = "overwrite_mac"
                 THEN /\ macV' = remoteV
                      /\ overwrote' = userEdit
                      /\ IF kind = "tracked"
                         THEN recordV' = remoteV /\ UNCHANGED broughtV
                         ELSE broughtV' = remoteV /\ UNCHANGED recordV
                 ELSE UNCHANGED <<marked, sawGone, macV, overwrote, recordV, broughtV>>
            ELSE UNCHANGED <<marked, sawGone, macV, overwrote, recordV, broughtV>>
    /\ Finish("cmd")
    /\ UNCHANGED <<marked, sawGone, kind, startV, remoteV, cmdEdited, otherWrote, macEdits, userEdit,
                   remoteCmd, sends, stopReq, killSent, closes, mode, sessionEnded, ends,
                   pushTries, repaired, resumed, resumeGets, posts>>

\* V5: after the run, the next push sends every tracked file that has no manifest
\* record, or one that differs from its record. Its record becomes this machine's version.
NextPush ==
    /\ phase = "done"
    /\ exit = "cmd"
    /\ kind = "tracked"
    /\ (recordV = NoVersion \/ recordV # macV)
    /\ recordV' = macV
    /\ remoteV' = macV
    /\ UNCHANGED <<marked, sawGone, kind, phase, exit, macV, startV, broughtV, cmdEdited,
                   otherWrote, macEdits, userEdit, remoteCmd, sends, stopReq, killSent,
                   overwrote, closes, mode, sessionEnded, ends, pushTries, repaired, resumed,
                   resumeGets, posts>>

\* The user edits the Mac file. For a tracked file the baseline point is the
\* push, so an edit before it is pushed; for a bring_back output it is the
\* run start, so every edit during the run counts.
MacEdit ==
    /\ phase # "done"
    /\ macEdits < MaxMacEdits
    /\ macEdits' = macEdits + 1
    /\ macV' = macEdits + 1
    /\ userEdit' = (userEdit \/ kind = "bring_back" \/ phase # "start")
    /\ UNCHANGED <<marked, sawGone, kind, phase, exit, startV, recordV, broughtV, remoteV,
                   cmdEdited, otherWrote, remoteCmd, sends, stopReq, killSent, overwrote,
                   closes, mode, sessionEnded, ends, pushTries, repaired, resumed,
                   resumeGets, posts>>

\* An overlapping run writes its own version in the sandbox and does not
\* bring it back (it was stopped, or its bring back has not run yet).
OtherRunWritesRemote ==
    /\ phase # "done"
    /\ remoteV # Other
    /\ remoteV' = Other
    /\ otherWrote' = TRUE
    /\ UNCHANGED <<marked, sawGone, kind, phase, exit, macV, startV, recordV, broughtV, cmdEdited,
                   macEdits, userEdit, remoteCmd, sends, stopReq, killSent,
                   overwrote, closes, mode, sessionEnded, ends, pushTries, repaired, resumed,
                   resumeGets, posts>>

\* An overlapping run in the same repository writes its own version of the
\* file in the sandbox, brings it back, and records it under the manifest
\* lock. It follows the same rule, so it never writes over a user edit. Not
\* a user edit itself.
OtherRunBringsBack ==
    /\ phase # "done"
    /\ ~userEdit
    /\ macV # Other
    /\ macV' = Other
    /\ remoteV' = Other
    /\ otherWrote' = TRUE
    /\ IF kind = "tracked"
       THEN recordV' = Other /\ UNCHANGED broughtV
       ELSE broughtV' = Other /\ UNCHANGED recordV
    /\ UNCHANGED <<marked, sawGone, kind, phase, exit, startV, cmdEdited, macEdits, userEdit,
                   remoteCmd, sends, stopReq, killSent, overwrote, closes, mode, sessionEnded,
                   ends, pushTries, repaired, resumed, resumeGets, posts>>

StopRequest ==
    /\ phase # "done"
    /\ ~stopReq
    /\ stopReq' = TRUE
    /\ UNCHANGED <<marked, sawGone, kind, phase, exit, macV, startV, recordV, broughtV, remoteV,
                   cmdEdited, otherWrote, macEdits, userEdit, remoteCmd, sends, killSent,
                   overwrote, closes, mode, sessionEnded, ends, pushTries, repaired, resumed,
                   resumeGets, posts>>

\* The remote kill: signal 15, then 9, folded into one step. The command's id
\* is known in streaming and in reattach.
Kill ==
    /\ phase \in {"streaming", "reattach"}
    /\ stopReq
    /\ ~killSent
    /\ Bug # "stop_ignored"
    /\ killSent' = TRUE
    /\ remoteCmd' = IF remoteCmd = "running" THEN "killed" ELSE remoteCmd
    /\ UNCHANGED <<marked, sawGone, kind, phase, exit, macV, startV, recordV, broughtV, remoteV,
                   cmdEdited, otherWrote, macEdits, userEdit, sends, stopReq, overwrote,
                   closes, mode, sessionEnded, ends, pushTries, repaired, resumed,
                   resumeGets, posts>>

\* A stop while the runner awaits the id waits for it (IdArrives, then Kill)
\* or ends as an unknown start (NoId): it never exits 143 there.
StopExit ==
    /\ phase \in {"streaming", "reattach"}
              \cup (IF Bug = "stop_before_id" THEN {"awaiting"} ELSE {})
    /\ stopReq
    /\ (killSent /\ remoteCmd # "running") \/ Bug \in {"exit_before_kill", "stop_before_id"}
    /\ Finish("143")
    /\ UNCHANGED <<marked, sawGone, kind, macV, startV, recordV, broughtV, remoteV, cmdEdited, otherWrote,
                   macEdits, userEdit, remoteCmd, sends, stopReq, killSent,
                   overwrote, closes, mode, sessionEnded, ends, pushTries, repaired, resumed,
                   resumeGets, posts>>

\* A kill the remote side refuses. The command keeps running, and the runner can only say
\* that it could not confirm the stop (N5, exit 143u).
KillFails ==
    /\ phase \in {"streaming", "reattach"}
    /\ stopReq
    /\ ~killSent
    /\ Bug # "stop_ignored"
    /\ killSent' = TRUE
    /\ UNCHANGED <<marked, sawGone, kind, phase, exit, macV, startV, recordV, broughtV, remoteV,
                   cmdEdited, otherWrote, macEdits, userEdit, remoteCmd, sends, stopReq,
                   overwrote, closes, mode, sessionEnded, ends, pushTries, repaired, resumed,
                   resumeGets, posts>>

\* A kill was sent but the command still runs: the stop is unconfirmed. A planted defect
\* reports it as a kill (143).
StopExitUnconfirmed ==
    /\ phase \in {"streaming", "reattach"}
    /\ stopReq
    /\ killSent
    /\ remoteCmd = "running"
    /\ Finish(IF Bug = "failed_kill_reports_killed" THEN "143" ELSE "143u")
    /\ UNCHANGED <<marked, sawGone, kind, macV, startV, recordV, broughtV, remoteV, cmdEdited, otherWrote,
                   macEdits, userEdit, remoteCmd, sends, stopReq, killSent, overwrote,
                   closes, mode, sessionEnded, ends, pushTries, repaired, resumed,
                   resumeGets, posts>>

Runner ==
    ResumeFirst \/ PushOk \/ PushMissing \/ PushGone \/ PushFails \/ StopBeforeSend \/ Send
    \/ IdArrives \/ NoId \/ Unknown
    \/ StreamEnds \/ BringBack \/ Reattach \/ Kill \/ StopExit
    \/ KillFails \/ StopExitUnconfirmed

\* The run has ended; nothing more happens. Keeps TLC from reporting the end
\* as a deadlock.
Done ==
    /\ phase = "done"
    /\ UNCHANGED vars

Next ==
    \/ Runner
    \/ SessionEnds
    \/ CmdEdits \/ CmdDeletes \/ CmdExits \/ IdleClose
    \/ NextPush
    \/ MacEdit \/ OtherRunBringsBack \/ OtherRunWritesRemote \/ StopRequest
    \/ Done

\* The runner's steps are fair. The command may never end, and the user may
\* never stop it. The sandbox session may end at any time before the start request.
Spec == Init /\ [][Next]_vars /\ WF_vars(Runner) /\ WF_vars(NextPush)

---------------------------------------------------------------------------
TypeOK ==
    /\ kind \in Kinds
    /\ mode \in Modes
    /\ phase \in Phases
    /\ exit \in Exits
    /\ macV \in Versions
    /\ startV \in Versions
    /\ recordV \in Versions \cup {NoVersion}
    /\ broughtV \in Versions \cup {NoVersion}
    /\ remoteV \in Versions \cup {Gone}
    /\ cmdEdited \in BOOLEAN
    /\ otherWrote \in BOOLEAN
    /\ macEdits \in 0..MaxMacEdits
    /\ userEdit \in BOOLEAN
    /\ remoteCmd \in Commands
    /\ sends \in 0..2
    /\ stopReq \in BOOLEAN
    /\ killSent \in BOOLEAN
    /\ overwrote \in BOOLEAN
    /\ closes \in 0..MaxCloses
    /\ sessionEnded \in BOOLEAN
    /\ ends \in 0..3
    /\ pushTries \in 0..4
    /\ repaired \in BOOLEAN
    /\ resumed \in BOOLEAN
    /\ resumeGets \in 0..3
    /\ posts \in 0..3
    /\ marked \in BOOLEAN
    /\ sawGone \in BOOLEAN

\* The start request goes out at most once, after an unknown start and after
\* an idle close alike.
NoDoubleSend == sends <= 1

\* The start request goes out at most twice: once, and once more after the 404 or 410 that the
\* run's one recovery covers (V3, V6).
NoDoublePost == posts <= 2

\* A second start request exists only after the run's one recovery (V3, V6).
ResendOnlyAfterRecovery == posts = 2 => resumed

\* A run whose record says the session is dead resumes it before its first session call (V3).
ResumeFirstWhenMarked == marked => phase \in {"start", "done"}

\* A run that ends on a 404 or 410 it did not recover from leaves its record marked, so the
\* next run resumes first (V3).
MarkedAfterGone == (phase = "done" /\ exit = "125" /\ sawGone /\ sessionEnded /\ mode = "remote") => marked

\* A push is sent at most three times: its first try, one retry after the one repair (V5),
\* and one retry after the one resume (V3).
PushesBounded == pushTries <= 3

\* A push resumes the session at most once per run (V3).
ResumeOnce == resumeGets <= 1

\* An isolated run never sends a resume GET (I3).
IsolatedNoResume == mode = "isolated" => resumeGets = 0

\* Bring back never writes over a user edit made after the file's baseline.
MacEditsWin == ~overwrote

\* After a successful run with no user edit, the Mac holds what the command
\* made: a file written by an overlapping run's bring back does not block it.
FreshBringBack ==
    (phase = "done" /\ exit = "cmd" /\ RemoteChanged /\ ~userEdit /\ remoteV # Gone)
        => macV = remoteV

\* V9: a path the sandbox deleted keeps no record once its bring back has run, so the next
\* push sends this machine's copy. A record left behind would make that push skip it.
GoneRecordDropped ==
    (phase = "done" /\ exit = "cmd" /\ kind = "tracked" /\ remoteV = Gone) => recordV = NoVersion

\* A path the sandbox deleted comes back: the next push sends this machine's copy.
GoneComesBack ==
    (phase = "done" /\ exit = "cmd" /\ kind = "tracked" /\ remoteV = Gone) ~> (remoteV = macV)

\* After a stop reported as a kill (143), the remote command is not left running.
\* An unconfirmed stop (143u) may leave it running: that is what "could not confirm" means.
NoOrphanAfterStop == (phase = "done" /\ exit = "143") => remoteCmd # "running"

\* A stop reported as a kill (143) after a send means the kill took effect: the command is dead
\* or has exited. A stop before the send (N24) sends nothing, so it is outside this rule.
KilledReportIsTrue == (phase = "done" /\ exit = "143" /\ sends > 0) => remoteCmd \in {"killed", "exited"}

\* The exit code tells the truth: 125 only when nothing was sent, the
\* command's code only after it exited, 255 only after one send, and the
\* unconfirmed stop 143u only after one send (an unconfirmed stop is a kill that failed).
ExitTruth ==
    /\ exit = "125" => sends = 0
    /\ exit = "cmd" => remoteCmd = "exited"
    /\ exit = "255" => sends = 1
    /\ exit = "143u" => sends = 1

\* A stop always ends the run, even when the command would never end.
StopEnds == [](stopReq => <>(phase = "done"))
=============================================================================
