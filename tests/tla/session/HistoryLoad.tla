---------------------------- MODULE HistoryLoad ----------------------------
(***************************************************************************)
(* How an ACP client gets a saved session's history on `session/load`,    *)
(* and two designs that send the bottom screen first. "b" is fx for a      *)
(* client that asks with `_meta.fx.historyPages`                           *)
(* (`src/acp/history_pages.zig`); "a" was rejected, since its load still   *)
(* sends the whole history; "current" is fx for a client that doesn't ask. *)
(*                                                                         *)
(* The log is a sequence of pieces, oldest first. A saved turn is one      *)
(* piece; the huge turn BigTurn is Big pieces, cut at paragraph starts. A  *)
(* page is a run of pieces; Budget bounds a page, whatever the history's   *)
(* size.                                                                   *)
(*                                                                         *)
(*   - "current" (`src/acp/sessions.zig` `handleRestoreSession`): restore  *)
(*     the runtime history, then every turn oldest first through a forward *)
(*     read (`sendActiveHistoryUpdates`), then the reply.                  *)
(*   - "a": the newest page, read from the log's tail, then a bottom       *)
(*     marker, the runtime restore, every older page newest first, each a  *)
(*     block tagged to go above, then the reply.                           *)
(*   - "b": the newest page, a bottom marker, the reply with a cursor to   *)
(*     the next older page; fx restores the runtime history before it      *)
(*     reads another request. `_fx/session/history` with a cursor answers  *)
(*     with the page before it, a block, and the next cursor.              *)
(* A client without the capability gets "current".                         *)
(*                                                                         *)
(* Edge cases: a damaged line (Damaged), a turn continuing the turn before *)
(* it (Continued: a Ctrl+G yield and its continuation, which the replay    *)
(* joins), a huge turn, live turns while older pages load, a crash at any  *)
(* step, a pane loading the chat again, an answer to a request from before *)
(* that, and a second fx on the session (Other), which holds its flock:    *)
(* the load waits for the lock (`openResume`, 2 s since fx#2469), while    *)
(* the other fx may still append a turn; then it gets the lock, or gives  *)
(* up with Busy. A backward read takes no lock, so a design could read the *)
(* tail before the lock; the mutants read_before_lock and send_before_lock *)
(* do. A compaction summary and a subagent's items are pieces of their     *)
(* turn, and a fork's log is its own copy (`copyFolded`), so none of them  *)
(* needs an action of its own.                                             *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Turns,       \* saved turns before the first load
    BigTurn,     \* the turn of Big pieces; 0 for none
    Big,
    Damaged,     \* the turn whose line is damaged; 0 for none
    Continued,   \* the turn that continues the one before it; 0 for none
    Budget,      \* pieces a page holds
    MaxLive,     \* live turns the client may start
    MaxCrashes,
    MaxReloads,
    OldClient,   \* the client lacks the capability
    Other,       \* a second fx on the session: "none" | "closes" (holds the lock, then closes) | "keeps"
    MaxOther,    \* turns the other fx may append while it holds the lock
    Design,      \* "current" | "a" | "b"
    Cut,         \* where a real fx started each page: page end piece -> its first
                 \* piece, for the trace check (`HistoryLoadTrace.tla`); <<>> otherwise
    Mutant       \* "none" | "no_split" | "no_tag" | "past_damage" | "split_continuation"
                 \* | "prompt_before_restore" | "no_generation" | "ignore_capability"
                 \* | "read_before_lock" | "send_before_lock"

ASSUME Turns \in Nat /\ Turns >= 1 /\ Budget \in Nat /\ Budget >= 1 /\ Big \in Nat /\ Big >= 2
ASSUME BigTurn \in 0..Turns /\ Damaged \in 0..(Turns - 1) /\ Continued \in 0..Turns
ASSUME Continued /= 1 /\ (Continued > 0 => Damaged \notin {Continued - 1, Continued} /\ BigTurn \notin {Continued - 1, Continued})
ASSUME Design \in {"current", "a", "b"}
ASSUME Mutant \in {"none", "no_split", "no_tag", "past_damage", "split_continuation",
                   "prompt_before_restore", "no_generation", "ignore_capability",
                   "read_before_lock", "send_before_lock"}
ASSUME Other \in {"none", "closes", "keeps"} /\ MaxOther \in Nat

Mode == IF Design = "current" \/ (OldClient /\ Mutant /= "ignore_capability") THEN "current" ELSE Design

Pieces(t) == IF t = BigTurn THEN Big ELSE 1
RECURSIVE FlatLog(_)
FlatLog(t) == IF t = 0 THEN <<>> ELSE FlatLog(t - 1) \o [i \in 1..Pieces(t) |-> [t |-> t, i |-> i]]
SavedLog == FlatLog(Turns)

\* A page bounds what fx reads and sends before the client has its bottom
\* screen: Budget pieces, and one more turn when a continuation needs the
\* turn it continues.
Bound == Budget + 1

VARIABLES
    log,        \* every piece, oldest first; a live turn is appended when it starts
    fx,         \* "idle" | "waiting" (for the lock) | "loading" | "loaded" | "failed" (Busy) | "dead"
    plan,       \* what fx still sends for the request it is in
    req,        \* "b": page requests fx hasn't read, oldest first
    pending,    \* live turns' updates fx hasn't sent yet
    chan,       \* what fx sent that the client hasn't read, oldest first
    restored,   \* fx's runtime history is restored for the model
    sentBottom, \* fx sent the bottom marker (today: the reply) of this load
    loadEnd,    \* the log's last piece when this load began
    gen,        \* the client's load; an answer to an older one is stale
    view,       \* the history pieces the client shows, top to bottom
    live,       \* the live turns the client shows below the history
    bottom,     \* the client has its bottom screen
    replied,    \* the client has the load's reply
    cursor,     \* "b": the client's cursor to the next older page; 0 for none
    inflight,   \* "b": the client waits for a page
    notice,     \* the client says older history can't be read
    workBefore, \* pieces fx sent in this load before its bottom marker
    loadWork,   \* pieces fx sent in this load before its reply
    tags,       \* the tags fx sent in this load
    unrestoredPrompt, \* a prompt ran before the runtime history was restored
    started, crashes, reloads,
    holder,     \* who holds the session's flock: "none" | "fx" | "other"
    busy,       \* the client got Busy for its load
    otherTurns  \* turns the other fx appended

vars == <<log, fx, plan, req, pending, chan, restored, sentBottom, loadEnd, gen, view, live, bottom,
          replied, cursor, inflight, notice, workBefore, loadWork, tags, unrestoredPrompt, started,
          crashes, reloads, holder, busy, otherTurns>>
lockVars == <<holder, busy, otherTurns>>

Last(s) == s[Len(s)]
Range(s) == {s[k] : k \in DOMAIN s}
TurnOf(p) == log[p].t
TurnStart(p) == log[p].i = 1
FirstOf(t) == CHOOSE q \in DOMAIN log : log[q].t = t /\ log[q].i = 1
LastOf(t) == FirstOf(t) + Pieces(t) - 1

\* The oldest piece a backward read reaches: the one after a damaged line,
\* which a backward read stops at (`readPage`: nothing past damage is trusted).
Floor == IF Damaged = 0 \/ Mutant = "past_damage" THEN 1 ELSE LastOf(Damaged) + 1
\* Today's forward read ends before the damaged line, silently.
ForwardEnd(e) == IF Damaged = 0 THEN e ELSE FirstOf(Damaged) - 1

\* Where the page that ends at piece `e` starts. Budget pieces back, not past
\* Floor; inside a turn, forward to the next turn's start, unless the page is
\* all one turn, which is cut at a paragraph start (the "no_split" mutant
\* sends that turn whole); then back to the turn a continuation continues.
NextStart(p, e) == CHOOSE q \in p..e : TurnStart(q) /\ \A r \in p..(q - 1) : ~TurnStart(r)
BudgetStart(e) ==
    LET s0 == IF e + 1 > Budget /\ e + 1 - Budget > Floor THEN e + 1 - Budget ELSE Floor
        s1 == IF TurnStart(s0) THEN s0
              ELSE IF TurnOf(s0) = TurnOf(e)
                   THEN (IF Mutant = "no_split" /\ FirstOf(TurnOf(e)) >= Floor THEN FirstOf(TurnOf(e)) ELSE s0)
              ELSE NextStart(s0, e)
        s2 == IF Mutant /= "split_continuation" /\ TurnStart(s1) /\ TurnOf(s1) = Continued /\ FirstOf(Continued - 1) >= Floor
              THEN FirstOf(Continued - 1) ELSE s1
    IN s2

\* A trace of the real fx gives its own page starts (Cut); the model's own
\* configs leave it empty and cut by Budget.
PageStart(e) == IF e \in DOMAIN Cut THEN Cut[e] ELSE BudgetStart(e)
\* The model's own configs give no cut (`Cut <- NoCut`): a config file can't write <<>>.
NoCut == <<>>

Piece(p, tag, g) == [kind |-> "piece", p |-> p, ps |-> <<>>, tag |-> tag, g |-> g, c |-> 0]
Mark(kind, g, c) == [kind |-> kind, p |-> 0, ps |-> <<>>, tag |-> "none", g |-> g, c |-> c]
Up(p, q, tag, g) == [k \in 1..(IF q >= p THEN q - p + 1 ELSE 0) |-> Piece(p + k - 1, tag, g)]
Run(p, q) == [k \in 1..(IF q >= p THEN q - p + 1 ELSE 0) |-> p + k - 1]
\* A page above the client's view: its pieces in order, put above as one block.
Block(kind, p, q, g, c) == [kind |-> kind, p |-> 0, ps |-> Run(p, q), tag |-> IF Mutant = "no_tag" THEN "replay" ELSE "older", g |-> g, c |-> c]
Restore == Mark("restore", 0, 0)

\* "a": every page older than the one ending at `e`, newest first.
RECURSIVE OlderPages(_, _)
OlderPages(e, g) == IF e < Floor THEN <<>> ELSE LET s == PageStart(e) IN <<Block("block", s, e, g, 0)>> \o OlderPages(s - 1, g)

LoadPlan(e, g) ==
    LET s == PageStart(e)
        older == IF s > Floor THEN s ELSE 0
        gap == IF Floor > 1 THEN <<Mark("notice", g, 0)>> ELSE <<>>
    IN CASE Mode = "current" -> <<Restore>> \o Up(1, ForwardEnd(e), "replay", g) \o <<Mark("reply", g, 0)>>
         [] Mode = "a" -> Up(s, e, "newest", g) \o <<Mark("bottom", g, 0), Restore>>
                          \o OlderPages(s - 1, g) \o gap \o <<Mark("reply", g, 0)>>
         [] Mode = "b" -> Up(s, e, "newest", g) \o <<Mark("bottom", g, 0)>>
                          \o (IF older = 0 THEN gap ELSE <<>>) \o <<Mark("reply", g, older)>>
                          \o (IF Mutant = "prompt_before_restore" THEN <<>> ELSE <<Restore>>)

PagePlan(c, g) ==
    LET s == PageStart(c - 1)
        older == IF s > Floor THEN s ELSE 0
    IN (IF older = 0 /\ Floor > 1 THEN <<Mark("notice", g, 0)>> ELSE <<>>) \o <<Block("page", s, c - 1, g, older)>>

Init ==
    /\ log = SavedLog /\ fx = "idle" /\ plan = <<>> /\ req = <<>> /\ pending = <<>> /\ chan = <<>>
    /\ restored = FALSE /\ sentBottom = FALSE /\ loadEnd = 0 /\ gen = 1
    /\ view = <<>> /\ live = <<>> /\ bottom = FALSE /\ replied = FALSE /\ cursor = 0 /\ inflight = FALSE
    /\ notice = FALSE /\ workBefore = 0 /\ loadWork = 0 /\ tags = {} /\ unrestoredPrompt = FALSE
    /\ started = 0 /\ crashes = 0 /\ reloads = 0
    /\ holder = (IF Other = "none" THEN "none" ELSE "other") /\ busy = FALSE /\ otherTurns = 0

\* The client sends `session/load`. With the lock free or its own, fx takes
\* it and plans what it sends; while the other fx holds it, fx waits.
Load ==
    /\ fx = "idle" /\ ~replied /\ ~busy /\ view = <<>>
    /\ sentBottom' = FALSE /\ workBefore' = 0 /\ loadWork' = 0 /\ tags' = {}
    /\ IF holder = "other"
       THEN /\ fx' = "waiting"
            /\ plan' = IF Mutant = "read_before_lock" THEN LoadPlan(Len(log), gen) ELSE <<>>
            /\ IF Mutant = "send_before_lock" /\ Mode /= "current"
               THEN /\ chan' = chan \o Up(PageStart(Len(log)), Len(log), "newest", gen) \o <<Mark("bottom", gen, 0)>>
                    /\ loadEnd' = Len(log)
               ELSE UNCHANGED <<chan, loadEnd>>
            /\ UNCHANGED holder
       ELSE /\ fx' = "loading" /\ plan' = LoadPlan(Len(log), gen) /\ loadEnd' = Len(log)
            /\ holder' = "fx" /\ UNCHANGED chan
    /\ UNCHANGED <<log, req, pending, restored, gen, view, live, bottom, replied, cursor, inflight,
                   notice, unrestoredPrompt, started, crashes, reloads, busy, otherTurns>>

\* The other fx appends a turn while it holds the lock.
OtherAppend ==
    /\ holder = "other" /\ otherTurns < MaxOther
    /\ log' = Append(log, [t |-> 100 + otherTurns, i |-> 1]) /\ otherTurns' = otherTurns + 1
    /\ UNCHANGED <<fx, plan, req, pending, chan, restored, sentBottom, loadEnd, gen, view, live, bottom,
                   replied, cursor, inflight, notice, workBefore, loadWork, tags, unrestoredPrompt, started,
                   crashes, reloads, holder, busy>>

\* The other fx closes, and its lock is free.
OtherRelease ==
    /\ holder = "other" /\ Other = "closes"
    /\ holder' = "none"
    /\ UNCHANGED <<log, fx, plan, req, pending, chan, restored, sentBottom, loadEnd, gen, view, live, bottom,
                   replied, cursor, inflight, notice, workBefore, loadWork, tags, unrestoredPrompt, started,
                   crashes, reloads, busy, otherTurns>>

\* The waiting load gets the lock, and plans from the log as it is now.
LockTaken ==
    /\ fx = "waiting" /\ holder = "none"
    /\ holder' = "fx" /\ fx' = "loading" /\ loadEnd' = Len(log)
    /\ plan' = IF Mutant = "read_before_lock" THEN plan ELSE LoadPlan(Len(log), gen)
    /\ UNCHANGED <<log, req, pending, chan, restored, sentBottom, gen, view, live, bottom, replied, cursor,
                   inflight, notice, workBefore, loadWork, tags, unrestoredPrompt, started, crashes, reloads,
                   busy, otherTurns>>

\* The wait ends with the lock still held: the load fails with Busy, and the
\* client may only load the chat again.
GiveUp ==
    /\ fx = "waiting" /\ holder = "other"
    /\ fx' = "failed" /\ plan' = <<>> /\ chan' = Append(chan, Mark("busy", gen, 0))
    /\ UNCHANGED <<log, req, pending, restored, sentBottom, loadEnd, gen, view, live, bottom, replied, cursor,
                   inflight, notice, workBefore, loadWork, tags, unrestoredPrompt, started, crashes, reloads,
                   holder, busy, otherTurns>>

\* fx sends the next thing it planned. A restore is a step of its own.
Send ==
    /\ fx \in {"loading", "loaded"} /\ plan /= <<>>
    /\ LET m == Head(plan) IN
       /\ plan' = Tail(plan)
       /\ restored' = (restored \/ m.kind = "restore")
       /\ chan' = IF m.kind = "restore" THEN chan ELSE Append(chan, m)
       /\ fx' = IF m.kind = "reply" THEN "loaded" ELSE fx
       /\ sentBottom' = (sentBottom \/ m.kind \in {"bottom", "reply"})
       /\ workBefore' = workBefore + (IF m.kind \in {"piece", "block"} /\ ~sentBottom /\ fx = "loading" THEN Len(m.ps) + (IF m.kind = "piece" THEN 1 ELSE 0) ELSE 0)
       /\ loadWork' = loadWork + (IF m.kind \in {"piece", "block"} /\ fx = "loading" THEN Len(m.ps) + (IF m.kind = "piece" THEN 1 ELSE 0) ELSE 0)
       /\ tags' = IF m.kind \in {"piece", "block"} /\ fx = "loading" THEN tags \cup {m.tag} ELSE tags
    /\ UNCHANGED <<log, req, pending, loadEnd, gen, view, live, bottom, replied, cursor, inflight, notice,
                   unrestoredPrompt, started, crashes, reloads>> /\ UNCHANGED lockVars

\* The client reads what fx sent. History goes in order or above; live turns
\* below. An answer to an older load is dropped (not by the mutant).
Receive ==
    /\ chan /= <<>>
    /\ LET m == Head(chan) IN
       /\ chan' = Tail(chan)
       /\ IF m.g /= gen /\ Mutant /= "no_generation"
          THEN UNCHANGED <<view, live, bottom, replied, cursor, inflight, notice>>
          ELSE /\ view' = CASE m.kind = "piece" -> Append(view, m.p)
                            [] m.kind \in {"block", "page"} /\ m.tag = "older" -> m.ps \o view
                            [] m.kind \in {"block", "page"} -> view \o m.ps
                            [] OTHER -> view
               /\ live' = IF m.kind = "live" THEN Append(live, m.p) ELSE live
               /\ bottom' = (bottom \/ m.kind \in {"bottom", "reply"})
               /\ replied' = (replied \/ m.kind = "reply")
               /\ cursor' = IF m.kind \in {"reply", "page"} THEN m.c ELSE cursor
               /\ inflight' = IF m.kind = "page" THEN FALSE ELSE inflight
               /\ notice' = (notice \/ m.kind = "notice")
    /\ busy' = (busy \/ (Head(chan).kind = "busy" /\ Head(chan).g = gen))
    /\ UNCHANGED <<log, fx, plan, req, pending, restored, sentBottom, loadEnd, gen, workBefore, loadWork,
                   tags, unrestoredPrompt, started, crashes, reloads, holder, otherTurns>>

\* The client starts a turn; fx reads it between requests. Its updates follow
\* at any time, between the pieces of a page too.
Prompt ==
    /\ fx = "loaded" /\ replied /\ plan = <<>> /\ started < MaxLive
    /\ log' = Append(log, [t |-> Turns + started + 1, i |-> 1])
    /\ pending' = Append(pending, [kind |-> "live", p |-> Len(log) + 1, ps |-> <<>>, tag |-> "live", g |-> gen, c |-> 0])
    /\ unrestoredPrompt' = (unrestoredPrompt \/ ~restored)
    /\ started' = started + 1
    /\ UNCHANGED <<fx, plan, req, chan, restored, sentBottom, loadEnd, gen, view, live, bottom, replied,
                   cursor, inflight, notice, workBefore, loadWork, tags, crashes, reloads>> /\ UNCHANGED lockVars

LiveSend ==
    /\ fx \in {"loading", "loaded"} /\ pending /= <<>>
    /\ chan' = Append(chan, Head(pending))
    /\ pending' = Tail(pending)
    /\ UNCHANGED <<log, fx, plan, req, restored, sentBottom, loadEnd, gen, view, live, bottom, replied,
                   cursor, inflight, notice, workBefore, loadWork, tags, unrestoredPrompt, started, crashes, reloads>>
    /\ UNCHANGED lockVars

\* "b": at the top, the client asks for the page before its cursor.
ScrollTop ==
    /\ Mode = "b" /\ replied /\ cursor > 0 /\ ~inflight /\ fx = "loaded"
    /\ req' = Append(req, [c |-> cursor, g |-> gen]) /\ inflight' = TRUE
    /\ UNCHANGED <<log, fx, plan, pending, chan, restored, sentBottom, loadEnd, gen, view, live, bottom,
                   replied, cursor, notice, workBefore, loadWork, tags, unrestoredPrompt, started, crashes, reloads>>
    /\ UNCHANGED lockVars

Page ==
    /\ fx = "loaded" /\ plan = <<>> /\ req /= <<>>
    /\ plan' = PagePlan(Head(req).c, Head(req).g) /\ req' = Tail(req)
    /\ UNCHANGED <<log, fx, pending, chan, restored, sentBottom, loadEnd, gen, view, live, bottom, replied,
                   cursor, inflight, notice, workBefore, loadWork, tags, unrestoredPrompt, started, crashes, reloads>>
    /\ UNCHANGED lockVars

\* fx dies at any step. What it wrote to the pipe still arrives; the rest is
\* gone, and so is its lock.
Crash ==
    /\ fx \in {"loading", "loaded", "waiting"} /\ crashes < MaxCrashes
    /\ fx' = "dead" /\ plan' = <<>> /\ req' = <<>> /\ pending' = <<>> /\ crashes' = crashes + 1
    /\ holder' = IF holder = "fx" THEN "none" ELSE holder
    /\ UNCHANGED <<log, chan, restored, sentBottom, loadEnd, gen, view, live, bottom, replied, cursor,
                   inflight, notice, workBefore, loadWork, tags, unrestoredPrompt, started, reloads, busy, otherTurns>>

\* The pane loads the chat again: through the same fx, whose pipe still holds
\* the old load's answers, or a new fx after a crash.
Reload ==
    /\ reloads < MaxReloads /\ (fx = "dead" \/ (fx = "loaded" /\ replied /\ plan = <<>>) \/ (fx = "failed" /\ busy))
    /\ reloads' = reloads + 1 /\ gen' = gen + 1
    /\ view' = <<>> /\ live' = <<>> /\ bottom' = FALSE /\ replied' = FALSE /\ cursor' = 0
    /\ inflight' = FALSE /\ notice' = FALSE /\ busy' = FALSE
    /\ IF fx = "dead"
       THEN fx' = "idle" /\ chan' = <<>> /\ restored' = FALSE
       ELSE fx' = "idle" /\ chan' = chan /\ restored' = restored
    /\ UNCHANGED <<log, plan, req, pending, sentBottom, loadEnd, workBefore, loadWork, tags,
                   unrestoredPrompt, started, crashes, holder, otherTurns>>

Next == Load \/ Send \/ Receive \/ Prompt \/ LiveSend \/ ScrollTop \/ Page \/ Crash \/ Reload
        \/ OtherAppend \/ OtherRelease \/ LockTaken \/ GiveUp

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Requirements *)

TypeOK ==
    /\ fx \in {"idle", "waiting", "loading", "loaded", "failed", "dead"}
    /\ holder \in {"none", "fx", "other"}
    /\ view \in Seq(DOMAIN log) /\ live \in Seq(Nat)
    /\ workBefore \in Nat /\ loadWork \in Nat

\* The goal: what fx reads and sends before the client has its bottom
\* screen does not grow with the history.
BottomBounded == workBefore <= Bound

\* 1000x the size: a load's own work does not grow with the history either.
LoadBounded == loadWork <= Bound

\* The client shows a run of the log in order, with no piece twice and none
\* missing between two it shows.
TranscriptExact == \A k \in 1..(Len(view) - 1) : view[k + 1] = view[k] + 1

\* At its bottom screen the client shows the newest saved piece.
BottomIsNewest == (bottom /\ view /= <<>>) => Last(view) = loadEnd

\* History shows above live turns, never among them.
LiveBelowHistory == (\A p \in Range(view) : p <= loadEnd) /\ (\A p \in Range(live) : p > loadEnd)

\* Nothing from a damaged line shows.
TrustedOnly == \A p \in Range(view) : TurnOf(p) /= Damaged

\* A continuation never shows without the turn it continues.
WholeTurns == Continued > 0 =>
    ((\E p \in Range(view) : TurnOf(p) = Continued) => (\E p \in Range(view) : TurnOf(p) = Continued - 1))

\* When the client has all it will get, it shows the history from its first
\* piece, or says that older history can't be read.
Done == replied /\ chan = <<>> /\ plan = <<>> /\ (Mode /= "b" \/ (cursor = 0 /\ ~inflight))
NoSilentGap == (Done /\ view /= <<>>) => (view[1] = 1 \/ notice)

\* A turn's model request sees the whole restored history.
PromptSeesFullHistory == ~unrestoredPrompt

\* A client without the capability gets exactly today's replay.
OldClientUnchanged == OldClient => tags \subseteq {"replay"}

\* A load that gets Busy shows no history: none was read before the lock.
BusyShowsNothing == busy => view = <<>>

-----------------------------------------------------------------------------
(* Witnesses, each violated, so the designs' configs are not vacuous *)

\* The client pages up to the log's first piece.
NeverPagedToTop == ~(Mode = "b" /\ Done /\ cursor = 0 /\ view /= <<>> /\ view[1] = 1 /\ Len(view) = loadEnd /\ loadEnd > Bound)

\* A live turn shows while a page is under way.
NeverLiveDuringPage == ~(inflight /\ live /= <<>>)

\* A load waits for the other fx, which appends a turn and closes, and then
\* shows its bottom screen with that turn.
NeverLockedBottom == ~(otherTurns > 0 /\ holder = "fx" /\ bottom /\ view /= <<>> /\ Last(view) = Len(SavedLog) + otherTurns)

\* A load gets Busy.
NeverBusy == ~busy

=============================================================================
