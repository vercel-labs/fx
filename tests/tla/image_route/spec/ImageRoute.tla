----------------------------- MODULE ImageRoute -----------------------------
(***************************************************************************)
(* How images reach the model on one request: the pure core                *)
(* `step(state, event)` in src/core/images/image_route.zig.                *)
(*                                                                         *)
(* Each core event is one action with the same name: TurnStarted,          *)
(* RequestReady, and CapabilitiesResolved. The environment acts through    *)
(* the values those events carry and through Crash:                        *)
(*   - the catalog can be listed, missing the model, or down (a refused,   *)
(*     slow, or garbage catalog reads as down), in any order;              *)
(*   - a reply can be lost (the next turn starts first), duplicated, or    *)
(*     stale (CapabilitiesResolved with nothing waiting);                  *)
(*   - a request can be delivered twice (RequestReady while a reply is     *)
(*     owed);                                                              *)
(*   - the process can crash at any step, which drops all core state.      *)
(* A second process is not modeled: core state lives in one turn of one    *)
(* process and nothing else can read or write it.                          *)
(*                                                                         *)
(* support, resolved, notified, and pending are `abstract(state)` in the   *)
(* code. out is the effects the step returned, and act is the event the    *)
(* step took, recorded so the laws can name it.                            *)
(*                                                                         *)
(* A request's user images are split by when they arrived: user_images     *)
(* are the ones attached this turn, and earlier_images are the ones from   *)
(* earlier turns that the history still holds. Only images attached this  *)
(* turn can fail a request. Earlier ones, like tool images, are attached   *)
(* or withheld with a notice, so an old image never blocks a new turn.     *)
(***************************************************************************)
EXTENDS Naturals, Sequences

Supports == {"unknown", "non_native", "native"}
Routes == {"native", "fallback", "unavailable"}
Modes == {"unavailable", "optional", "required"}
ToolImages == {"none", "attached", "withheld_fallback", "withheld_dead_end", "withheld_unknown"}
Reasons == {"capability_unknown", "no_native_image"}

Views == [kind: {"listed"}, vision: BOOLEAN, file_input: BOOLEAN]
         \cup [kind: {"missing", "down"}, vision: {FALSE}, file_input: {FALSE}]

Requests == {r \in [user_images: BOOLEAN, earlier_images: BOOLEAN, pending_images: BOOLEAN,
                    tool_images: BOOLEAN, fallback: BOOLEAN, catalog_down: BOOLEAN] :
               r.pending_images => r.user_images}

Sends == [kind: {"send"}, route: Routes, mode: Modes, tool_images: ToolImages, earlier_images: ToolImages]
Effects == [kind: {"resolve", "notify"}] \cup Sends \cup [kind: {"fail"}, reason: Reasons]

\* At most one request; the core's `?Request`.
Pending == {<<>>} \cup {<<r>> : r \in Requests}

Acts == [name: {"Init", "Crash"}]
        \cup [name: {"TurnStarted"}, view: Views]
        \cup [name: {"RequestReady"}, req: Requests]
        \cup [name: {"CapabilitiesResolved"}, view: Views, answered: Pending]

VARIABLES support, resolved, notified, pending, out, act

vars == <<support, resolved, notified, pending, out, act>>

\* `supportFromCatalog`.
Derive(v) == IF v.kind = "listed" THEN (IF v.vision THEN "native" ELSE "non_native") ELSE "unknown"

\* `held`: how images already in the history travel under support s on
\* route. Tool images and earlier user images follow this one rule.
Held(s, route) == CASE s = "native" -> "attached"
                    [] s = "unknown" -> "withheld_unknown"
                    [] OTHER -> IF route = "fallback" THEN "withheld_fallback" ELSE "withheld_dead_end"

\* `decision`.
Decide(s, r) ==
    LET route == CASE s = "native" -> "native"
                   [] s = "unknown" -> "unavailable"
                   [] OTHER -> IF r.fallback THEN "fallback" ELSE "unavailable"
        mode == IF route # "fallback" THEN "unavailable"
                ELSE IF r.pending_images THEN "required" ELSE "optional"
        tool == IF ~r.tool_images THEN "none" ELSE Held(s, route)
        earlier == IF ~r.earlier_images THEN "none" ELSE Held(s, route)
    IN [kind |-> "send", route |-> route, mode |-> mode, tool_images |-> tool, earlier_images |-> earlier]

\* Whether send e withholds some image as unconfirmed.
WithholdsUnknown(e) == e.tool_images = "withheld_unknown" \/ e.earlier_images = "withheld_unknown"

Unroutable(s, r) == r.user_images /\ Decide(s, r).route = "unavailable"
Notifies(s, r, n) == ~Unroutable(s, r) /\ WithholdsUnknown(Decide(s, r)) /\ r.catalog_down /\ ~n

\* `decide`: the effects of deciding r under s, and the next notified flag.
DecideOut(s, r, n) ==
    IF Unroutable(s, r)
    THEN <<[kind |-> "fail", reason |-> IF s = "unknown" THEN "capability_unknown" ELSE "no_native_image"]>>
    ELSE IF Notifies(s, r, n) THEN <<[kind |-> "notify"], Decide(s, r)>>
    ELSE <<Decide(s, r)>>

DecideNotified(s, r, n) == n \/ Notifies(s, r, n)

HasImages(r) == r.user_images \/ r.earlier_images \/ r.tool_images

NeedsResolve(r) == support = "unknown" /\ ~resolved /\ HasImages(r)

Init ==
    /\ support = "unknown"
    /\ resolved = FALSE
    /\ notified = FALSE
    /\ pending = <<>>
    /\ out = <<>>
    /\ act = [name |-> "Init"]

TurnStarted(v) ==
    /\ act' = [name |-> "TurnStarted", view |-> v]
    /\ support' = Derive(v)
    /\ resolved' = FALSE   \* a new turn may ask again
    /\ notified' = FALSE   \* a new turn may tell the user again
    /\ pending' = <<>>
    /\ out' = <<>>

RequestReady(r) ==
    /\ act' = [name |-> "RequestReady", req |-> r]
    /\ IF pending # <<>>
       THEN pending' = <<r>> /\ out' = <<>> /\ UNCHANGED <<support, resolved, notified>>
       ELSE IF NeedsResolve(r)
       THEN /\ resolved' = TRUE
            /\ pending' = <<r>>
            /\ out' = <<[kind |-> "resolve"]>>
            /\ UNCHANGED <<support, notified>>
       ELSE /\ out' = DecideOut(support, r, notified)
            /\ notified' = DecideNotified(support, r, notified)
            /\ UNCHANGED <<support, resolved, pending>>

CapabilitiesResolved(v) ==
    /\ act' = [name |-> "CapabilitiesResolved", view |-> v, answered |-> pending]
    /\ IF pending = <<>>
       THEN out' = <<>> /\ UNCHANGED <<support, resolved, notified, pending>>
       ELSE LET s == Derive(v) IN
            /\ support' = s
            /\ pending' = <<>>
            /\ out' = DecideOut(s, Head(pending), notified)
            /\ notified' = DecideNotified(s, Head(pending), notified)
            /\ UNCHANGED resolved

\* The process dies; the next process starts from the core's zero state.
Crash ==
    /\ act' = [name |-> "Crash"]
    /\ support' = "unknown"
    /\ resolved' = FALSE
    /\ notified' = FALSE
    /\ pending' = <<>>
    /\ out' = <<>>

Reply == pending # <<>> /\ \E v \in Views : CapabilitiesResolved(v)

Next ==
    \/ \E v \in Views : TurnStarted(v)
    \/ \E r \in Requests : RequestReady(r)
    \/ \E v \in Views : CapabilitiesResolved(v)
    \/ Crash

\* A reply the shell waits for arrives unless the turn ends first.
Spec == Init /\ [][Next]_vars /\ WF_vars(Reply)

-----------------------------------------------------------------------------
(* Laws. DESIGN.md names each one and where it is enforced.                *)

HasKind(k) == \E i \in 1..Len(out) : out[i].kind = k
SendsOut == {out[i] : i \in {j \in 1..Len(out) : out[j].kind = "send"}}
FailsOut == {out[i] : i \in {j \in 1..Len(out) : out[j].kind = "fail"}}
\* The request this step decided, as a sequence of at most one.
Decided == IF act.name = "RequestReady" THEN <<act.req>>
           ELSE IF act.name = "CapabilitiesResolved" THEN act.answered
           ELSE <<>>

TypeOK ==
    /\ support \in Supports
    /\ resolved \in BOOLEAN
    /\ notified \in BOOLEAN
    /\ pending \in Pending
    /\ Len(out) <= 2 /\ \A i \in 1..Len(out) : out[i] \in Effects
    /\ act \in Acts

\* L11: one waiting request, and at most a notice then one answer.
Bounded ==
    /\ Len(pending) <= 1
    /\ Len(out) <= 2
    /\ Len(out) = 2 => (out[1].kind = "notify" /\ out[2].kind = "send")

\* L1: a model the catalog lists with vision takes images inline, whatever
\* its file-input tag says; one listed without vision does not; an unlisted
\* model or an unreachable catalog leaves support unknown.
VisionImpliesNative ==
    (act.name = "TurnStarted" \/ (act.name = "CapabilitiesResolved" /\ act.answered # <<>>)) =>
        /\ (act.view.kind = "listed" /\ act.view.vision) => support = "native"
        /\ (act.view.kind = "listed" /\ ~act.view.vision) => support = "non_native"
        /\ act.view.kind # "listed" => support = "unknown"

\* L5: no image goes to a model the catalog has not confirmed.
UnknownNeverInline ==
    \A e \in SendsOut : (e.tool_images = "attached" \/ e.earlier_images = "attached") => support = "native"

\* L4: route, mode, tool images, and earlier images all follow the one
\* support value the state holds after the step.
OneSnapshot ==
    \A e \in SendsOut :
        /\ (e.route = "native") <=> (support = "native")
        /\ \A h \in {e.tool_images, e.earlier_images} :
              /\ h = "withheld_unknown" => support = "unknown"
              /\ h = "withheld_fallback" => (support = "non_native" /\ e.route = "fallback")
              /\ h = "withheld_dead_end" => (support = "non_native" /\ e.route = "unavailable")

\* L2: the vision tool is offered exactly on the fallback route.
RouteModeCoherent == \A e \in SendsOut : (e.route = "fallback") <=> (e.mode # "unavailable")

\* L3: native delivery and the vision tool never meet.
NativeExcludesFallback == \A e \in SendsOut : support = "native" => (e.route = "native" /\ e.mode = "unavailable")

\* L6: tool images and earlier images are attached or withheld with a
\* notice; never neither.
NoSilentWithhold ==
    \A e \in SendsOut :
        /\ Decided # <<>>
        /\ Head(Decided).tool_images <=> e.tool_images # "none"
        /\ Head(Decided).earlier_images <=> e.earlier_images # "none"

\* L6: the vision tool is required exactly while user images wait.
RequiredWhenPending ==
    \A e \in SendsOut : e.route = "fallback" => ((e.mode = "required") <=> Head(Decided).pending_images)

\* L7: images attached this turn without a route fail the request; nothing
\* else does, so earlier images never block a turn.
FailExactlyWhenUnroutable ==
    /\ \A e \in FailsOut :
          /\ Decided # <<>>
          /\ Head(Decided).user_images
          /\ (support = "unknown" \/ (support = "non_native" /\ ~Head(Decided).fallback))
          /\ e.reason = IF support = "unknown" THEN "capability_unknown" ELSE "no_native_image"
    /\ \A e \in SendsOut : Head(Decided).user_images => e.route # "unavailable"

\* L8: the core asks for capabilities only when images wait on unknown support.
ResolveOnlyWhenNeeded ==
    HasKind("resolve") =>
        /\ act.name = "RequestReady"
        /\ support = "unknown"
        /\ HasImages(act.req)
        /\ pending = <<act.req>>

\* L15: support is judged unknown, by withholding images as unconfirmed or
\* failing for it, only after the turn asked the catalog.
AskedBeforeUnknown ==
    /\ \A e \in SendsOut : WithholdsUnknown(e) => resolved
    /\ \A e \in FailsOut : e.reason = "capability_unknown" => resolved

\* L9: the user hears about a down catalog only for images it withholds.
NotifyOnlyWhenDown ==
    HasKind("notify") =>
        /\ \E e \in SendsOut : WithholdsUnknown(e)
        /\ Head(Decided).catalog_down

\* L13: a decision comes only once no reply is owed.
DecideOnlyWhenReady ==
    (HasKind("send") \/ HasKind("fail")) =>
        /\ pending = <<>>
        /\ (act.name = "RequestReady" \/ (act.name = "CapabilitiesResolved" /\ act.answered # <<>>))

\* L14: a new turn, or a new process, starts clean.
TurnResets ==
    act.name \in {"TurnStarted", "Crash"} => (~resolved /\ ~notified /\ pending = <<>> /\ out = <<>>)

\* L13: while a reply is owed, the core has asked once and decided nothing.
PendingWaitsForReply ==
    pending # <<>> => (resolved /\ support = "unknown" /\ (out = <<>> \/ out = <<[kind |-> "resolve"]>>))

\* L8: at most one capability request per turn.
ResolveOncePerTurn == [][(\E i \in 1..Len(out') : out'[i].kind = "resolve") => ~resolved]_vars

\* L9: at most one catalog-down notice per turn.
NotifyOncePerTurn == [][(\E i \in 1..Len(out') : out'[i].kind = "notify") => ~notified]_vars

\* L10: a request delivered while a reply is owed runs nothing.
DuplicateRequestIsQuiet == [][(act'.name = "RequestReady" /\ pending # <<>>) => out' = <<>>]_vars

\* L10: a reply nothing waits for changes nothing.
StaleReplyIsQuiet ==
    [][(act'.name = "CapabilitiesResolved" /\ pending = <<>>) =>
          (out' = <<>> /\ UNCHANGED <<support, resolved, notified, pending>>)]_vars

\* L12: every request that waits is answered, unless its turn ends.
Answered == (pending # <<>>) ~> (pending = <<>>)
=============================================================================
