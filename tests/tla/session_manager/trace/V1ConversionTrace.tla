--------------------------- MODULE V1ConversionTrace ---------------------------
(***************************************************************************)
(* Trace validation for V1Conversion.tla from what real fx runs leave.    *)
(*                                                                         *)
(* A driver runs real fx processes one step at a time and observes the    *)
(* result after each (`Obs`, from ConversionData.tla), a record with      *)
(*   k      the step: create | write | hold | release (older-build v1     *)
(*          writers), open | all | crash (a request, the last one killed  *)
(*          mid-request), open2 (two processes opening the same root at   *)
(*          once), recover (a salvage, D64), damage, fresh (a new v2      *)
(*          session), list                                                 *)
(*   r      the requested root ("none" for other steps)                    *)
(*   ans    the request's answer: opened | converted | busy | unreadable  *)
(*          | notfound, recovered | healthy | unsalvageable | inv2 for    *)
(*          recover, or none; ans2 the second process's, for open2       *)
(*   v1     [Ids -> version]: each v1 member's distinct contents in order *)
(*          of first appearance, 0 absent                                  *)
(*   pub    [AllIds -> Status]: each id in v2                              *)
(*   base   [AllIds -> version]: for a converted id, the v1 version its   *)
(*          copy equals, -1 when it equals none                            *)
(*   extra  [AllIds -> Nat]: v2 turns after the copied ones                *)
(*   dirty  conversion leftovers in .tmp                                   *)
(*   listed the ids the listing shows                                      *)
(*   bad    [Ids -> Damages]: members the driver made unreadable, and     *)
(*          whether the v1 writer's own recover salvages them              *)
(*   held   the members a still-running older build has open               *)
(*   denied the driver made the file system refuse deletes in this step    *)
(* Between observations, only the actions of that step's kind may run,   *)
(* any number of them; a request step makes exactly its requests, by     *)
(* process p1 (and p2 for open2). Accepted when some behavior of          *)
(* V1Conversion passes through every observation in order: `NotDone`     *)
(* then fails.                                                             *)
(***************************************************************************)
EXTENDS V1Conversion, ConversionData, Sequences, TLC

VARIABLE l
tvars == <<vars, l>>

ASSUME TLCSet(1, 0)

P1 == "p1"
P2 == "p2"

\* The requests observation `j` makes.
Made(o) == CASE o.k = "open2" -> 2 [] o.k \in {"open", "all", "crash", "recover"} -> 1 [] OTHER -> 0
RECURSIVE ReqCount(_)
ReqCount(n) == IF n = 0 THEN 0 ELSE Made(Obs[n]) + ReqCount(n - 1)

\* A refused delete is a fault only a step that injected it may show.
ConvAllowed(p, o) == ConvWork(p) \/ (o.denied /\ ConvRefused(p))

\* During a request, an older build may write only if an earlier hold step
\* left it holding the session; it cannot take a lock there.
HolderStep(i) == WBegin(i) \/ WEnd(i)

\* The actions a step of kind `o.k` may take, at observation index `n`.
Hidden(o, n) ==
    CASE o.k \in {"create", "write", "hold", "release"} ->
            \E i \in Ids : WriterStep(i)
      [] o.k = "damage" -> \E i \in Ids : Damage(i)
      [] o.k = "fresh" -> \E i \in NewIds : FCreate(i) \/ FAppend(i)
      [] o.k \in {"open", "all", "recover"} ->
            \/ reqs < ReqCount(n) /\ Request(P1, o.k, o.r)
            \/ ConvAllowed(P1, o)
            \/ \E i \in Ids : HolderStep(i)
            \/ req[P1] = NoReq /\ reqs = ReqCount(n) /\ \E i \in AllIds : FAppend(i)
      [] o.k = "open2" ->
            \/ reqs = ReqCount(n) - 2 /\ Request(P1, "open", o.r)
            \/ reqs = ReqCount(n) - 1 /\ Request(P2, "open", o.r)
            \/ \E p \in {P1, P2} : ConvAllowed(p, o)
            \/ \E i \in Ids : HolderStep(i)
            \/ req[P1] = NoReq /\ req[P2] = NoReq /\ reqs = ReqCount(n) /\ \E i \in AllIds : FAppend(i)
      [] o.k = "crash" ->
            \/ reqs < ReqCount(n) /\ \E kk \in {"open", "all"} : Request(P1, kk, o.r)
            \/ ConvAllowed(P1, o) \/ CCrash(P1)
            \/ \E i \in Ids : HolderStep(i)
      [] OTHER -> FALSE

Match(o, n) ==
    /\ v1ver = o.v1
    /\ pub = o.pub
    /\ \A i \in AllIds : pub[i] = "import" => base[i] = o.base[i]
    /\ extra = o.extra
    /\ Dirty = o.dirty
    /\ Listed = o.listed
    /\ bad = o.bad
    /\ {i \in Ids : v1lock[i] = "writer"} = o.held
    /\ reqs = ReqCount(n)
    /\ \A p \in Procs : req[p] = NoReq /\ conv[p] = Idle
    /\ o.k \in {"open", "all", "recover"} => out[P1].ans = o.ans
    /\ o.k = "open2" =>
         \/ out[P1].ans = o.ans /\ out[P2].ans = o.ans2
         \/ out[P1].ans = o.ans2 /\ out[P2].ans = o.ans
    /\ o.k = "crash" => out[P1].ans = "none"

TraceInit == Init /\ l = 1

TraceNext ==
    /\ l <= Len(Obs)
    /\ \/ Hidden(Obs[l], l) /\ UNCHANGED l
       \/ Match(Obs[l], l) /\ l' = l + 1 /\ UNCHANGED vars

TraceSpec == TraceInit /\ [][TraceNext]_tvars

Progress ==
    IF l - 1 > TLCGet(1)
    THEN TLCSet(1, l - 1) /\ PrintT(<<"matched_lines", l - 1>>)
    ELSE TRUE

NotDone == l <= Len(Obs)
=============================================================================
