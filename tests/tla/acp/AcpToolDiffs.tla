---------------------------- MODULE AcpToolDiffs ----------------------------
(***************************************************************************)
(* What an ACP client sees of fx's file edits (src/acp/prompt.zig): ACP    *)
(* v1's `diff` tool call content, with a file's whole text before and     *)
(* after, on write_file and edit_file calls.                               *)
(*                                                                         *)
(*  - fx prepares an edit against the file as it is, and commits it only  *)
(*    if the file hasn't changed since; otherwise the call fails.         *)
(*  - A permission request for an edit shows the prepared change.         *)
(*  - A committed edit's completed update carries its diff, then its      *)
(*    text. An update's content replaces the call's, so the diff must be  *)
(*    in that last update.                                                *)
(*  - A failed or denied call ends with text only, which replaces any     *)
(*    diff its permission request showed.                                 *)
(*  - A side over 1 MiB, or not UTF-8, sends no diff anywhere: the call   *)
(*    keeps only its text (Big).                                          *)
(*                                                                         *)
(* A file's text is a version: InitVer gives each file's first one, 0 for *)
(* a file that doesn't exist, and each prepared edit picks a new one from *)
(* Vs. A diff is the pair <<old, new>> of versions.                       *)
(*                                                                         *)
(* `Rules` set to FALSE gives fx acp before these rules:                  *)
(* no update carries a diff. AcpToolDiffsToday.cfg shows                  *)
(* Complete failing.                                                      *)
(*                                                                         *)
(* tests/tla/drivers/acp/tool_diffs/driver.ts runs the real fx acp        *)
(* through edits and has TLC check each run against this model through    *)
(* AcpToolDiffsTrace.tla.                                                 *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Rules,      \* TRUE: the tool diffs rules; FALSE: fx acp before them
    Calls,      \* the edit calls of the run
    Files,
    FileOf,     \* [Calls -> Files]
    Ask,        \* the calls that need the client's approval
    Big,        \* the calls whose diff is over the limit
    InitVer,    \* [Files -> Nat]: each file's first version, 0 if absent
    Vs          \* the versions an edit may write

None == <<>>

VARIABLES
    ver,        \* [Files -> Nat]: each file's version on disk
    st,         \* [Calls -> states]
    pre,        \* [Calls -> Nat]: the version the edit was prepared against
    post,       \* [Calls -> Nat]: the version it writes
    before,     \* [Calls -> Nat]: the version on disk just before its commit
    after,      \* [Calls -> Nat]: just after
    chan,       \* updates fx wrote and the client hasn't read
    view        \* [Calls -> [status, diff]]: what the client shows

vars == <<ver, st, pre, post, before, after, chan, view>>

States == {"idle", "prepared", "asked", "approved", "committed", "done", "failed"}
Statuses == {"none", "pending", "permission", "completed", "failed"}

Used == {post[c] : c \in Calls} \cup {InitVer[f] : f \in Files}

\* An update for call c: its status, and its content, when it has any.
\* `content` is FALSE for an update that leaves the call's content as it
\* is; otherwise `diff` is the diff it shows, or None.
Upd(c, status, content, diff) == [c |-> c, status |-> status, content |-> content, diff |-> diff]

ShowsDiff(c) == Rules /\ c \notin Big

Init ==
    /\ ver = InitVer
    /\ st = [c \in Calls |-> "idle"]
    /\ pre = [c \in Calls |-> 0]
    /\ post = [c \in Calls |-> 0]
    /\ before = [c \in Calls |-> 0]
    /\ after = [c \in Calls |-> 0]
    /\ chan = <<>>
    /\ view = [c \in Calls |-> [status |-> "none", diff |-> None]]

\* fx prepares the edit against the file as it is now.
Prepare(c) ==
    /\ st[c] = "idle"
    /\ \E v \in Vs \ Used :
         /\ pre' = [pre EXCEPT ![c] = ver[FileOf[c]]]
         /\ post' = [post EXCEPT ![c] = v]
    /\ st' = [st EXCEPT ![c] = "prepared"]
    /\ chan' = Append(chan, Upd(c, "pending", FALSE, None))
    /\ UNCHANGED <<ver, before, after, view>>

\* The permission request shows the prepared change.
AskClient(c) ==
    /\ st[c] = "prepared" /\ c \in Ask
    /\ st' = [st EXCEPT ![c] = "asked"]
    /\ chan' = Append(chan, Upd(c, "permission", ShowsDiff(c),
                                IF ShowsDiff(c) THEN <<pre[c], post[c]>> ELSE None))
    /\ UNCHANGED <<ver, pre, post, before, after, view>>

Approve(c) ==
    /\ st[c] = "asked"
    /\ st' = [st EXCEPT ![c] = "approved"]
    /\ UNCHANGED <<ver, pre, post, before, after, chan, view>>

\* A denied call fails with text, which replaces the diff it showed.
Deny(c) ==
    /\ st[c] = "asked"
    /\ st' = [st EXCEPT ![c] = "failed"]
    /\ chan' = Append(chan, Upd(c, "failed", TRUE, None))
    /\ UNCHANGED <<ver, pre, post, before, after, view>>

\* fx commits the edit only if the file is as it was prepared against.
Commit(c) ==
    /\ \/ st[c] = "approved"
       \/ st[c] = "prepared" /\ c \notin Ask
    /\ LET f == FileOf[c] IN
       IF ver[f] = pre[c]
       THEN /\ ver' = [ver EXCEPT ![f] = post[c]]
            /\ before' = [before EXCEPT ![c] = ver[f]]
            /\ after' = [after EXCEPT ![c] = post[c]]
            /\ st' = [st EXCEPT ![c] = "committed"]
            /\ UNCHANGED chan
       ELSE /\ st' = [st EXCEPT ![c] = "failed"]
            /\ chan' = Append(chan, Upd(c, "failed", TRUE, None))
            /\ UNCHANGED <<ver, before, after>>
    /\ UNCHANGED <<pre, post, view>>

\* The committed edit's completed update: its diff, then its text.
Finish(c) ==
    /\ st[c] = "committed"
    /\ st' = [st EXCEPT ![c] = "done"]
    /\ chan' = Append(chan, Upd(c, "completed", TRUE,
                                IF ShowsDiff(c) THEN <<before[c], after[c]>> ELSE None))
    /\ UNCHANGED <<ver, pre, post, before, after, view>>

Deliver ==
    /\ chan # <<>>
    /\ LET m == Head(chan) IN
       /\ chan' = Tail(chan)
       /\ view' = [view EXCEPT ![m.c] = [status |-> m.status,
                                          diff |-> IF m.content THEN m.diff ELSE @.diff]]
    /\ UNCHANGED <<ver, st, pre, post, before, after>>

Next ==
    \/ Deliver
    \/ \E c \in Calls : \/ Prepare(c) \/ AskClient(c) \/ Approve(c) \/ Deny(c)
                        \/ Commit(c) \/ Finish(c)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
TypeOK ==
    /\ ver \in [Files -> Nat]
    /\ st \in [Calls -> States]
    /\ \A c \in Calls : view[c].status \in Statuses

Delivered == chan = <<>>

\* A diff the client shows on a finished call is the file just before and
\* just after that call's commit.
ShownMatchesDisk ==
    \A c \in Calls :
        view[c].status = "completed" /\ view[c].diff # None =>
            view[c].diff = <<before[c], after[c]>>

\* While a call waits for approval, its diff is the change it would make.
ProposedMatchesPrepared ==
    \A c \in Calls :
        view[c].status = "permission" /\ view[c].diff # None =>
            view[c].diff = <<pre[c], post[c]>>

\* Once the client has read every update, each committed edit within the
\* limit shows its diff.
Complete ==
    Delivered =>
        \A c \in Calls :
            st[c] = "done" /\ c \notin Big => view[c].diff = <<before[c], after[c]>>

\* A failed or denied call shows no diff.
NoDiffUnlessCommitted ==
    \A c \in Calls : view[c].status = "failed" => view[c].diff = None

\* A call over the limit never shows a diff.
BigNoDiff ==
    \A c \in Big : view[c].diff = None
=============================================================================
