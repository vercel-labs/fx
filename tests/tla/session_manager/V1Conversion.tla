---------------------------- MODULE V1Conversion ----------------------------
(***************************************************************************)
(* Step: v1 sessions convert to v2 when they are opened (D55, D56, D59,   *)
(* D60, D61).                                                              *)
(*                                                                         *)
(* Processes of the new build (Procs) each ask to open a root id, or the  *)
(* convert-all command asks for it. If v2 holds the id, the request is    *)
(* answered at once, after deleting any v1 folder of the family a crash   *)
(* left behind that is unchanged since it was copied. If only v1 holds   *)
(* it, the process converts the family, the root and the child sessions  *)
(* in its registry, before it answers: it takes the v1 lock of every     *)
(* member (a held one answers "busy"), and only then clears the family's *)
(* crash leftovers in .tmp and stages a copy of each member (an          *)
(* unreadable member answers "unreadable" and drops the staging). A      *)
(* child an earlier, crashed conversion already published is reused as  *)
(* it is. It publishes the children and then the root, deletes each      *)
(* member's v1 folder under its lock while that folder is the version   *)
(* its copy holds (D60), and releases the locks. A delete the file      *)
(* system refuses leaves the folder and still answers. Nothing converts *)
(* without a request, and the converter writes no v1 file: it only      *)
(* deletes a folder whose copy is published.                             *)
(*                                                                         *)
(* Older builds keep writing v1 sessions throughout: a writer holds a     *)
(* session's lock while it has the session open, and a write in progress *)
(* leaves the files torn. The new build creates fresh v2 sessions and    *)
(* appends to any v2 root. Any process can crash at any step: a crash    *)
(* drops every lock it held and leaves staging, published children and  *)
(* undeleted v1 folders behind.                                           *)
(*                                                                         *)
(* Rule R1 (AvoidV1Ids): a fresh v2 session never takes the id of a live  *)
(* v1 session. Assumption A1: an older build never creates a v1 session   *)
(* under an id v2 holds (ids are 72 random bits).                         *)
(*                                                                         *)
(* Converted once per id (D55): a v1 folder an older build changed after  *)
(* its copy was made is never converted again or deleted, so v1ver may   *)
(* run ahead of base.                                                      *)
(*                                                                         *)
(* Salvage (D64): `fx session recover` on a damaged v1 root copies the   *)
(* start v1's own recover would keep into a fresh v2 session. It holds   *)
(* the root's v1 lock for the read, as v1 does, and never writes,        *)
(* converts or deletes the v1 session. A healthy root needs no salvage,  *)
(* and a root whose damage leaves no validated start cannot be salvaged. *)
(* No answer refuses without its cause: "busy" only while another holds *)
(* a lock, "unreadable" or "unsalvageable" only for damage v1 could not  *)
(* get past either, so nothing v1 opens or salvages is lost (no-bricking *)
(* contract, docs/session-manager/v1-removal/plan.md).                   *)
(*                                                                         *)
(* Design: system-design.md D53 to D57 and D59 to D61, D64.               *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Procs,      \* processes of the new build
    RootId,     \* a v1 root session
    ChildId,    \* a child session in that root's registry
    NewIds,     \* ids only fresh v2 sessions can take
    None,
    Torn,       \* the copy of a member read while a writer was mid-write
    MaxV,       \* versions a v1 session reaches
    MaxLocks,   \* times a writer opens one session
    MaxExtra,   \* v2 turns appended to one session
    MaxCrash,   \* crashes and refused deletes in one behavior
    MaxReq,     \* open and convert-all requests in one behavior
    AvoidV1Ids  \* rule R1

Ids == {RootId, ChildId}
Parent == [i \in Ids |-> IF i = ChildId THEN RootId ELSE None]
ASSUME RootId # ChildId /\ Ids \cap NewIds = {} /\ Procs \cap {"free", "writer"} = {}

AllIds == Ids \cup NewIds
Roots == {i \in Ids : Parent[i] = None}
Children(r) == {c \in Ids : Parent[c] = r}
Fam(r) == {r} \cup Children(r)

Kinds == {"none", "open", "all", "recover"}
Answers == {"none", "opened", "converted", "busy", "unreadable", "notfound",
            "recovered", "healthy", "unsalvageable", "inv2"}
Status == {"none", "import", "fresh", "salvage"}
\* "salvage": damaged, with a start v1's recover validates; "lost": none.
Damages == {"ok", "salvage", "lost"}

VARIABLES
    v1ver,      \* [Ids -> 0..MaxV]: 0 absent, else the version of its files
    v1lock,     \* [Ids -> {"free", "writer"} \cup Procs]
    writing,    \* [Ids -> BOOLEAN]: a writer is mid-write; the files are torn
    locks,      \* [Ids -> 0..MaxLocks]: times a writer took the lock
    bad,        \* [Ids -> Damages]: the member's v1 files cannot be read
    pub,        \* [AllIds -> Status]: the id in v2
    base,       \* [AllIds -> 0..MaxV \cup {Torn}]: the version a conversion
                \* copied, which the v2 copy records as its fingerprint
    staged,     \* [Ids -> BOOLEAN]: a copy in .tmp
    stagedBase, \* [Ids -> 0..MaxV \cup {Torn}]
    extra,      \* [AllIds -> 0..MaxExtra]: v2 turns appended since publish
    conv,       \* [Procs -> the converter: pc, the family root, its locked
                \* members, and those it copied in this run]
    req,        \* [Procs -> the request being answered: kind and root]
    out,        \* [Procs -> the answer to the latest request: ans and root]
    refused,    \* [Procs -> SUBSET Ids]: deletes refused in the current request
    reqs,       \* requests made
    crashes,
    famOf       \* [Roots -> SUBSET Ids]: the members a root's conversion covered

vars == <<v1ver, v1lock, writing, locks, bad, pub, base, staged, stagedBase,
          extra, conv, req, out, refused, reqs, crashes, famOf>>

Idle == [pc |-> "idle", root |-> None, members |-> {}, copied |-> {}]
NoReq == [kind |-> "none", root |-> None]

TypeOK ==
    /\ v1ver \in [Ids -> 0..MaxV]
    /\ v1lock \in [Ids -> {"free", "writer"} \cup Procs]
    /\ writing \in [Ids -> BOOLEAN]
    /\ locks \in [Ids -> 0..MaxLocks]
    /\ bad \in [Ids -> Damages]
    /\ pub \in [AllIds -> Status]
    /\ base \in [AllIds -> (0..MaxV) \cup {Torn}]
    /\ staged \in [Ids -> BOOLEAN]
    /\ stagedBase \in [Ids -> (0..MaxV) \cup {Torn}]
    /\ extra \in [AllIds -> 0..MaxExtra]
    /\ \A p \in Procs :
         /\ conv[p].pc \in {"idle", "locked", "staged", "published", "salvaging"}
         /\ conv[p].root \in Roots \cup {None}
         /\ conv[p].members \subseteq Ids /\ conv[p].copied \subseteq conv[p].members
         /\ req[p].kind \in Kinds /\ req[p].root \in Roots \cup {None}
         /\ out[p].ans \in Answers /\ out[p].root \in Roots \cup {None}
         /\ refused[p] \subseteq Ids
    /\ reqs \in 0..MaxReq
    /\ crashes \in 0..MaxCrash
    /\ famOf \in [Roots -> SUBSET Ids]

Live(i) == pub[i] \in {"import", "fresh", "salvage"}

\* A published child whose root is not published: a crash's leftover, which
\* the next conversion of its family reuses as it is.
Orphan(i) == Parent[i] # None /\ pub[i] = "import" /\ pub[Parent[i]] = "none"
Dirty == \E i \in Ids : staged[i]

\* A v1 folder a crash or a refused delete left behind, unchanged since its
\* copy (damage changes its fingerprint too), free, and not refused in p's
\* current request: p's open deletes it.
Leftover(p, i) ==
    /\ pub[i] = "import" /\ v1ver[i] > 0 /\ v1ver[i] = base[i] /\ bad[i] = "ok"
    /\ v1lock[i] = "free" /\ i \notin refused[p]

\* What the picker and `fx sessions` list: v2 roots, and v1 roots v2 does not
\* hold; children are internal.
Listed ==
    {r \in Roots : Live(r) \/ (pub[r] = "none" /\ v1ver[r] > 0)}
        \cup {n \in NewIds : Live(n)}

Init ==
    /\ v1ver = [i \in Ids |-> 0]
    /\ v1lock = [i \in Ids |-> "free"]
    /\ writing = [i \in Ids |-> FALSE]
    /\ locks = [i \in Ids |-> 0]
    /\ bad = [i \in Ids |-> "ok"]
    /\ pub = [i \in AllIds |-> "none"]
    /\ base = [i \in AllIds |-> 0]
    /\ staged = [i \in Ids |-> FALSE]
    /\ stagedBase = [i \in Ids |-> 0]
    /\ extra = [i \in AllIds |-> 0]
    /\ conv = [p \in Procs |-> Idle]
    /\ req = [p \in Procs |-> NoReq]
    /\ out = [p \in Procs |-> [ans |-> "none", root |-> None]]
    /\ refused = [p \in Procs |-> {}]
    /\ reqs = 0
    /\ crashes = 0
    /\ famOf = [r \in Roots |-> {}]

(* -- v1 writers: older builds *)

WCreate(i) ==
    /\ v1ver[i] = 0
    /\ Parent[i] # None => v1ver[Parent[i]] > 0
    /\ pub[i] = "none"                                   \* A1
    /\ v1ver' = [v1ver EXCEPT ![i] = 1]
    /\ UNCHANGED <<v1lock, writing, locks, bad, pub, base, staged, stagedBase,
                   extra, conv, req, out, refused, reqs, crashes, famOf>>

WLock(i) ==
    /\ v1ver[i] > 0
    /\ v1lock[i] = "free"
    /\ locks[i] < MaxLocks
    /\ v1lock' = [v1lock EXCEPT ![i] = "writer"]
    /\ locks' = [locks EXCEPT ![i] = @ + 1]
    /\ UNCHANGED <<v1ver, writing, bad, pub, base, staged, stagedBase, extra,
                   conv, req, out, refused, reqs, crashes, famOf>>

WBegin(i) ==
    /\ v1lock[i] = "writer"
    /\ ~writing[i]
    /\ v1ver[i] < MaxV
    /\ writing' = [writing EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<v1ver, v1lock, locks, bad, pub, base, staged, stagedBase,
                   extra, conv, req, out, refused, reqs, crashes, famOf>>

WEnd(i) ==
    /\ writing[i]
    /\ writing' = [writing EXCEPT ![i] = FALSE]
    /\ v1ver' = [v1ver EXCEPT ![i] = @ + 1]
    /\ UNCHANGED <<v1lock, locks, bad, pub, base, staged, stagedBase, extra,
                   conv, req, out, refused, reqs, crashes, famOf>>

WUnlock(i) ==
    /\ v1lock[i] = "writer"
    /\ ~writing[i]
    /\ v1lock' = [v1lock EXCEPT ![i] = "free"]
    /\ UNCHANGED <<v1ver, writing, locks, bad, pub, base, staged, stagedBase,
                   extra, conv, req, out, refused, reqs, crashes, famOf>>

\* A writer dies: the kernel drops its lock, and v1's own open repairs a torn
\* write back to the last whole version.
WCrash(i) ==
    /\ v1lock[i] = "writer"
    /\ crashes < MaxCrash
    /\ v1lock' = [v1lock EXCEPT ![i] = "free"]
    /\ writing' = [writing EXCEPT ![i] = FALSE]
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<v1ver, locks, bad, pub, base, staged, stagedBase, extra,
                   conv, req, out, refused, reqs, famOf>>

\* A member's v1 files become unreadable: damage from outside fx, which may
\* leave a start v1's recover validates.
Damage(i) ==
    /\ v1ver[i] > 0
    /\ bad[i] = "ok"
    /\ \E d \in Damages \ {"ok"} : bad' = [bad EXCEPT ![i] = d]
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, pub, base, staged,
                   stagedBase, extra, conv, req, out, refused, reqs, crashes, famOf>>

(* -- the new build's own v2 sessions *)

FCreate(i) ==
    /\ i \in NewIds \/ (i \in Roots /\ (AvoidV1Ids => v1ver[i] = 0))
    /\ pub[i] = "none"
    /\ i \in Ids => ~staged[i]
    /\ pub' = [pub EXCEPT ![i] = "fresh"]
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, base, staged,
                   stagedBase, extra, conv, req, out, refused, reqs, crashes, famOf>>

FAppend(i) ==
    /\ Live(i)
    /\ i \in NewIds \/ i \in Roots
    /\ extra[i] < MaxExtra
    /\ extra' = [extra EXCEPT ![i] = @ + 1]
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, pub, base, staged,
                   stagedBase, conv, req, out, refused, reqs, crashes, famOf>>

(* -- requests and the converter, in each requesting process *)

Request(p, k, r) ==
    /\ k \in Kinds \ {"none"}
    /\ req[p] = NoReq
    /\ conv[p] = Idle
    /\ reqs < MaxReq
    /\ req' = [req EXCEPT ![p] = [kind |-> k, root |-> r]]
    /\ out' = [out EXCEPT ![p] = [ans |-> "none", root |-> r]]
    /\ refused' = [refused EXCEPT ![p] = {}]
    /\ reqs' = reqs + 1
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, conv, crashes, famOf>>

Answer(p, a) ==
    /\ req' = [req EXCEPT ![p] = NoReq]
    /\ out' = [out EXCEPT ![p] = [ans |-> a, root |-> req[p].root]]

Done(p) == IF req[p].kind = "open" THEN "opened" ELSE "converted"

Waiting(p) == req[p] # NoReq /\ conv[p] = Idle /\ req[p].kind # "recover"

\* v2 already holds the id: any leftover of its family is cleaned first.
AHeld(p) ==
    /\ Waiting(p)
    /\ Live(req[p].root)
    /\ ~\E i \in Fam(req[p].root) : Leftover(p, i)
    /\ Answer(p, Done(p))
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, conv, refused, reqs, crashes, famOf>>

\* A leftover v1 folder, unchanged since its copy, is deleted under its lock.
CClean(p, i) ==
    /\ Waiting(p)
    /\ Live(req[p].root)
    /\ i \in Fam(req[p].root)
    /\ Leftover(p, i)
    /\ v1ver' = [v1ver EXCEPT ![i] = 0]
    /\ UNCHANGED <<v1lock, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, conv, req, out, refused, reqs, crashes, famOf>>

\* The file system refuses that delete: the folder stays, the open goes on.
CCleanRefused(p, i) ==
    /\ Waiting(p)
    /\ Live(req[p].root)
    /\ i \in Fam(req[p].root)
    /\ Leftover(p, i)
    /\ crashes < MaxCrash
    /\ refused' = [refused EXCEPT ![p] = @ \cup {i}]
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, conv, req, out, reqs, famOf>>

\* Neither store holds it.
AMissing(p) ==
    /\ Waiting(p)
    /\ pub[req[p].root] = "none" /\ v1ver[req[p].root] = 0
    /\ Answer(p, IF req[p].kind = "open" THEN "notfound" ELSE "converted")
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, conv, refused, reqs, crashes, famOf>>

\* Takes every present member's lock, or answers "busy" holding none. The
\* check that v2 does not hold the root is made under the locks: another
\* process may have converted it while this one waited.
CBegin(p) ==
    LET r == req[p].root
        present == {i \in Fam(r) : v1ver[i] > 0} IN
    /\ Waiting(p)
    /\ pub[r] = "none" /\ v1ver[r] > 0
    /\ IF \A i \in present : v1lock[i] = "free"
       THEN /\ v1lock' = [i \in Ids |-> IF i \in present THEN p ELSE v1lock[i]]
            /\ conv' = [conv EXCEPT ![p] = [pc |-> "locked", root |-> r, members |-> present, copied |-> {}]]
            /\ UNCHANGED <<req, out>>
       ELSE /\ Answer(p, "busy")
            /\ UNCHANGED <<v1lock, conv>>
    /\ UNCHANGED <<v1ver, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, refused, reqs, crashes, famOf>>

\* Under the locks: the family's staging leftovers go, and each member not
\* already published gets a fresh copy in .tmp; an unreadable member drops
\* the staging and answers "unreadable".
CStage(p) ==
    LET m == conv[p].members
        copy == {i \in m : pub[i] = "none"} IN
    /\ conv[p].pc = "locked"
    /\ IF \E i \in copy : bad[i] # "ok"
       THEN /\ v1lock' = [i \in Ids |-> IF i \in m THEN "free" ELSE v1lock[i]]
            /\ staged' = [i \in Ids |-> IF i \in Fam(conv[p].root) THEN FALSE ELSE staged[i]]
            /\ conv' = [conv EXCEPT ![p] = Idle]
            /\ Answer(p, "unreadable")
            /\ UNCHANGED stagedBase
       ELSE /\ staged' = [i \in Ids |-> IF i \in Fam(conv[p].root) THEN i \in copy ELSE staged[i]]
            /\ stagedBase' = [i \in Ids |->
                                IF i \in copy
                                THEN (IF writing[i] THEN Torn ELSE v1ver[i])
                                ELSE stagedBase[i]]
            /\ conv' = [conv EXCEPT ![p].pc = "staged", ![p].copied = copy]
            /\ UNCHANGED <<v1lock, req, out>>
    /\ UNCHANGED <<v1ver, writing, locks, bad, pub, base, extra, refused,
                   reqs, crashes, famOf>>

\* Publishing is the manager's atomic rename.
CPublishChild(p, c) ==
    /\ conv[p].pc = "staged"
    /\ c \in conv[p].members \ {conv[p].root}
    /\ staged[c]
    /\ staged' = [staged EXCEPT ![c] = FALSE]
    /\ pub' = [pub EXCEPT ![c] = "import"]
    /\ base' = [base EXCEPT ![c] = stagedBase[c]]
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, stagedBase, extra, conv,
                   req, out, refused, reqs, crashes, famOf>>

CPublishRoot(p) ==
    LET r == conv[p].root IN
    /\ conv[p].pc = "staged"
    /\ \A c \in conv[p].members \ {r} : ~staged[c]
    /\ staged' = [staged EXCEPT ![r] = FALSE]
    /\ pub' = [pub EXCEPT ![r] = "import"]
    /\ base' = [base EXCEPT ![r] = stagedBase[r]]
    /\ conv' = [conv EXCEPT ![p].pc = "published"]
    /\ famOf' = [famOf EXCEPT ![r] = conv[p].members]
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, stagedBase, extra, req,
                   out, refused, reqs, crashes>>

\* A member whose v1 folder p may delete: one it copied in this run, or a
\* reused child still at its copy's version and fingerprint.
Deletable(p, i) ==
    /\ i \in conv[p].members /\ v1ver[i] > 0 /\ v1ver[i] = base[i]
    /\ i \in conv[p].copied \/ bad[i] = "ok"

\* D60: with the copy durable, each member's v1 folder goes, still locked.
CDelete(p, i) ==
    /\ conv[p].pc = "published"
    /\ Deletable(p, i)
    /\ i \notin refused[p]
    /\ v1ver' = [v1ver EXCEPT ![i] = 0]
    /\ UNCHANGED <<v1lock, writing, locks, bad, pub, base, staged, stagedBase,
                   extra, conv, req, out, refused, reqs, crashes, famOf>>

\* The file system refuses that delete: the folder stays as a leftover.
CDeleteRefused(p, i) ==
    /\ conv[p].pc = "published"
    /\ Deletable(p, i)
    /\ i \notin refused[p]
    /\ crashes < MaxCrash
    /\ refused' = [refused EXCEPT ![p] = @ \cup {i}]
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, conv, req, out, reqs, famOf>>

\* Every member's folder is gone, refused, or not deletable (a reused child
\* an older build changed or that was damaged): the locks go, it answers.
CFinish(p) ==
    /\ conv[p].pc = "published"
    /\ \A i \in conv[p].members : ~Deletable(p, i) \/ i \in refused[p]
    /\ v1lock' = [i \in Ids |-> IF i \in conv[p].members THEN "free" ELSE v1lock[i]]
    /\ conv' = [conv EXCEPT ![p] = Idle]
    /\ Answer(p, Done(p))
    /\ UNCHANGED <<v1ver, writing, locks, bad, pub, base, staged, stagedBase,
                   extra, refused, reqs, crashes, famOf>>

(* -- salvage of a damaged v1 root (D64) *)

SWaiting(p) == req[p].kind = "recover" /\ conv[p] = Idle
OnlyV1(r) == pub[r] = "none" /\ v1ver[r] > 0

\* The id is not a v1-only session: v2's own recover answers, or nothing
\* holds it.
SElsewhere(p) ==
    /\ SWaiting(p)
    /\ ~OnlyV1(req[p].root)
    /\ Answer(p, IF Live(req[p].root) THEN "inv2" ELSE "notfound")
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, conv, refused, reqs, crashes, famOf>>

\* Takes the root's v1 lock for the read, or answers "busy".
SBegin(p) ==
    LET r == req[p].root IN
    /\ SWaiting(p)
    /\ OnlyV1(r)
    /\ IF v1lock[r] = "free"
       THEN /\ v1lock' = [v1lock EXCEPT ![r] = p]
            /\ conv' = [conv EXCEPT ![p] = [pc |-> "salvaging", root |-> r, members |-> {r}, copied |-> {}]]
            /\ UNCHANGED <<req, out>>
       ELSE /\ Answer(p, "busy")
            /\ UNCHANGED <<conv, v1lock>>
    /\ UNCHANGED <<v1ver, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, refused, reqs, crashes, famOf>>

\* Reads the root under its lock and answers. A validated start is
\* published as a fresh v2 session in one rename, the manager's import;
\* when every fresh id this model tracks is taken, it lands in one it does
\* not track (real ids are random).
SFinish(p) ==
    LET r == conv[p].root
        free == {n \in NewIds : pub[n] = "none"} IN
    /\ conv[p].pc = "salvaging"
    /\ IF bad[r] = "salvage" /\ free # {}
       THEN \E n \in free : pub' = [pub EXCEPT ![n] = "salvage"]
       ELSE UNCHANGED pub
    /\ v1lock' = [v1lock EXCEPT ![r] = "free"]
    /\ conv' = [conv EXCEPT ![p] = Idle]
    /\ Answer(p, CASE bad[r] = "ok" -> "healthy"
                  [] bad[r] = "salvage" -> "recovered"
                  [] OTHER -> "unsalvageable")
    /\ UNCHANGED <<v1ver, writing, locks, bad, base, staged, stagedBase,
                   extra, refused, reqs, crashes, famOf>>

SalvStep(p) == SElsewhere(p) \/ SBegin(p) \/ SFinish(p)

\* The process dies: no answer, and its locks go with it.
CCrash(p) ==
    /\ req[p] # NoReq
    /\ crashes < MaxCrash
    /\ v1lock' = [i \in Ids |-> IF v1lock[i] = p THEN "free" ELSE v1lock[i]]
    /\ conv' = [conv EXCEPT ![p] = Idle]
    /\ req' = [req EXCEPT ![p] = NoReq]
    /\ out' = [out EXCEPT ![p] = [ans |-> "none", root |-> req[p].root]]
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<v1ver, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, refused, reqs, famOf>>

\* A converter's steps, without its faults.
ConvWork(p) ==
    \/ AHeld(p) \/ AMissing(p) \/ CBegin(p) \/ CStage(p) \/ CPublishRoot(p) \/ CFinish(p)
    \/ SalvStep(p)
    \/ \E c \in Ids : CPublishChild(p, c) \/ CDelete(p, c) \/ CClean(p, c)

\* Faults: a refused delete.
ConvRefused(p) == \E c \in Ids : CDeleteRefused(p, c) \/ CCleanRefused(p, c)

ConvStep(p) == ConvWork(p) \/ ConvRefused(p) \/ CCrash(p)

WriterStep(i) == WCreate(i) \/ WLock(i) \/ WBegin(i) \/ WEnd(i) \/ WUnlock(i) \/ WCrash(i)

Next ==
    \/ \E p \in Procs :
         \/ ConvStep(p)
         \/ \E k \in Kinds \ {"none"}, r \in Roots : Request(p, k, r)
    \/ \E i \in Ids : WriterStep(i) \/ Damage(i)
    \/ \E i \in AllIds : FCreate(i) \/ FAppend(i)

Spec == Init /\ [][Next]_vars

\* Each converter keeps going on a request it holds, and writers release
\* their locks; requests, crashes, writes and opens are bounded.
FairSpec ==
    /\ Spec
    /\ \A p \in Procs :
         /\ WF_vars(AHeld(p)) /\ WF_vars(AMissing(p)) /\ WF_vars(CBegin(p))
         /\ WF_vars(CStage(p)) /\ WF_vars(CPublishRoot(p)) /\ WF_vars(CFinish(p))
         /\ WF_vars(SElsewhere(p)) /\ WF_vars(SBegin(p)) /\ WF_vars(SFinish(p))
         /\ \A c \in Ids : WF_vars(CPublishChild(p, c)) /\ WF_vars(CDelete(p, c)) /\ WF_vars(CClean(p, c))
    /\ \A i \in Ids : WF_vars(WUnlock(i)) /\ WF_vars(WEnd(i))

(* -- properties *)

\* A converter holds every member's lock from staging to the delete, so the
\* copy it publishes is the version v1 has, never a torn one, and the
\* folder it deletes is that version.
LockHeld ==
    \A p \in Procs :
        conv[p].pc \in {"locked", "staged", "published", "salvaging"} =>
            \A i \in conv[p].members : v1lock[i] = p
CopyIsCurrent ==
    \A p \in Procs :
        conv[p].pc = "staged" =>
            \A i \in conv[p].members : staged[i] => stagedBase[i] = v1ver[i]
NoTornImport == \A i \in Ids : pub[i] = "import" => base[i] # Torn

\* A converter's locks never outlive its conversion.
NoStaleConvLock == \A p \in Procs : conv[p].pc = "idle" => \A i \in Ids : v1lock[i] # p

\* A fresh v2 session never takes a live v1 root's id, which would hide that
\* v1 session for good.
NoShadow == \A r \in Roots : v1ver[r] > 0 => pub[r] # "fresh"

\* A published root's conversion covered every member present when it
\* began, and each of those children is published.
ChildrenLanded ==
    \A r \in Roots : pub[r] = "import" => \A c \in famOf[r] \ {r} : pub[c] = "import"

\* A child whose root never landed still has its v1 folder: no delete
\* happens before the whole family is published.
OrphansKeepV1 == \A i \in Ids : Orphan(i) => v1ver[i] > 0

\* The step at which p answers; each answer is judged when it is given.
AnswerStep(p) == req[p] # NoReq /\ req'[p] = NoReq /\ out'[p].ans # "none"

\* "Opened" or "converted" means v2 holds the root (its children by
\* ChildrenLanded), or there is nothing to convert.
AnsweredWhole ==
    [][\A p \in Procs :
         (AnswerStep(p) /\ out'[p].ans \in {"opened", "converted"}) =>
             (pub'[req[p].root] \in {"import", "fresh"} \/ v1ver'[req[p].root] = 0)]_vars

\* A live v1 session is never reported missing.
NoFalseNotFound ==
    [][\A p \in Procs :
         (AnswerStep(p) /\ out'[p].ans = "notfound") =>
             (pub'[req[p].root] = "none" /\ v1ver'[req[p].root] = 0)]_vars

\* A refused request converts nothing: "busy" changes no staging and takes
\* no lock; "unreadable" leaves no staging of the family and no lock.
NothingHalfConverted ==
    [][\A p \in Procs :
         /\ (AnswerStep(p) /\ out'[p].ans = "busy") =>
                (staged' = staged /\ pub' = pub /\ \A i \in Ids : v1lock'[i] # p)
         /\ (AnswerStep(p) /\ out'[p].ans = "unreadable") =>
                (pub' = pub /\ \A i \in Fam(req[p].root) : ~staged'[i] /\ v1lock'[i] # p)]_vars

\* D60: a v1 folder goes only once its v2 copy is published and is that
\* folder's version, under its converter's lock or free; no writer deletes.
NoLossOnDelete ==
    [][\A i \in Ids :
         (v1ver[i] > 0 /\ v1ver'[i] = 0) =>
             /\ pub[i] = "import" /\ pub'[i] = "import"
             /\ base[i] = v1ver[i] /\ ~writing[i]
             /\ v1lock[i] # "writer"]_vars

\* An answered open or conversion leaves no v1 folder of the family that
\* equals its copy, except one held by a writer or by another converter
\* (which deletes it as it finishes), damaged since, or whose delete was
\* refused.
LeftoversGone ==
    [][\A p \in Procs :
         (AnswerStep(p) /\ out'[p].ans \in {"opened", "converted"}) =>
             \A i \in Fam(req[p].root) :
                 (pub'[i] = "import" /\ v1ver'[i] > 0 /\ v1ver'[i] = base'[i])
                     => (v1lock'[i] \in {"writer"} \cup (Procs \ {p}) \/ bad'[i] # "ok" \/ i \in refused'[p])]_vars

\* The converter writes no v1 file: it only deletes v1 folders.
ConverterOnlyDeletes ==
    [][(\E p \in Procs : ConvStep(p)) =>
         /\ \A i \in Ids : v1ver'[i] \in {v1ver[i], 0}
         /\ UNCHANGED <<writing, bad>>]_vars

\* Nothing converts without a request for that root: no background work.
ConvertsOnlyOnRequest ==
    [][\A r \in Roots :
         (pub[r] = "none" /\ pub'[r] = "import") => \E p \in Procs : req[p].root = r]_vars

\* A live v2 root is never replaced, and a conversion is never redone, nor
\* is a published child's copy, reused or not: once per id.
RootsStick ==
    [][\A i \in Roots \cup NewIds :
         Live(i) => (pub'[i] = pub[i] /\ base'[i] = base[i])]_vars
ChildrenStick ==
    [][\A c \in Ids :
         (Parent[c] # None /\ pub[c] = "import") => (pub'[c] = "import" /\ base'[c] = base[c])]_vars

\* D64: salvage never writes, converts or deletes a v1 session; the only id
\* it changes is a fresh one (RootsStick keeps that from replacing a live
\* session).
SalvageLeavesSource ==
    [][\A p \in Procs :
         SalvStep(p) => /\ UNCHANGED <<v1ver, writing, bad, base, staged>>
                        /\ \A i \in Ids : pub'[i] = pub[i]]_vars

\* No-bricking: an answer that refuses names a cause v1 shares. "busy" only
\* while someone else holds a lock of the family; "unreadable" only for a
\* damaged member not yet in v2; salvage reports the damage as it is.
RefusedOnlyWithCause ==
    [][\A p \in Procs :
         LET r == req[p].root
             a == out'[p].ans IN
         AnswerStep(p) =>
             /\ a = "busy" => \E i \in Fam(r) : v1lock[i] \notin {"free", p}
             /\ a = "unreadable" => \E i \in Fam(r) : pub[i] = "none" /\ bad[i] # "ok"
             /\ a = "unsalvageable" => bad[r] = "lost"
             /\ a = "healthy" => bad[r] = "ok"
             /\ a = "recovered" => bad[r] = "salvage"]_vars

\* Every request is answered, unless its process dies.
RequestsAnswered == \A p \in Procs : (req[p] # NoReq) ~> (req[p] = NoReq)
=============================================================================
