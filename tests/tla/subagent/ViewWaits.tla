------------------------------ MODULE ViewWaits ------------------------------
(***************************************************************************)
(* Two views and what each shows for the person-only items in its tree.    *)
(*                                                                         *)
(* `Design` "current" is the code in this tree. "a" is the design the person *)
(* chose and "b" the one not taken (see below); neither is code yet, so this *)
(* spec is their design record and the rows for them run only here until the *)
(* build lands.                                                             *)
(*                                                                         *)
(* A view is main's or an instance's (`instanceOnScreen`,                   *)
(* src/core/app/app_agents_runtime.zig:1171-1174). A view owns the children *)
(* of its tree (`lendsTo`, :2434-2436). A child raises either a prompt      *)
(* object, kinds B, C and D (`question_prompt`, src/core/agents/agent.zig:38*)
(* synced at src/core/app/app_worker_runtime.zig:1404-1444), or a wait with *)
(* no prompt, kind E (`waitsForUser`, src/core/output/worker_status.zig:105-*)
(* 112, statuses from src/core/recovery/recovery.zig:142-152).              *)
(*                                                                         *)
(* `Design` picks the mechanism the view uses. `"a"` is the design the      *)
(* person chose (2026-11-25): a third owned prompt, the wait card, lent into *)
(* the view and refreshed by a later pass. The card owns a copy, so a state *)
(* right after a change can draw the old copy until `Sync` settles it.      *)
(* `"b"` is a projection computed from the child's live state, storing      *)
(* nothing. It was not taken: the spike drew that card through the question *)
(* band, which keeps the agent list from painting while it shows (S1, S7    *)
(* and S8 failed there), and the spike did not fix it. It stays here as the *)
(* comparison the rules are checked against; the build follows `"a"`.       *)
(*   "current" today: the question and approval lent, kind E with no card.  *)
(*                                                                         *)
(* `Mutant` plants one defect, and the row named for it must catch it:     *)
(*   no-wait-card      kind E is never shown (today)          ShownWhenFree *)
(*   footer-blind      the footer counts a shown item (today, kind B)       *)
(*                                                        FooterQuietForShown*)
(*   picker-to-screen  an action from a view goes to the screen's agent     *)
(*                                                        ActionReachesOwner*)
(*   no-settle         design A never discards a stale copy   NoStaleShown  *)
(*   lend-under-alt    a lend while the alternate screen is owned           *)
(*                                                       HeldUnderAltScreen *)
(*   two-shown         a view adds a second item             OneAtATime     *)
(*   cross-tree        a view shows another tree's item      InstanceScope  *)
(*   note-content      the note carries the question text    NoSecretToModel*)
(*   main-answers      main answers the item            MainOnlyTellsOrStops*)
(*   view-only         the child's own screen cannot act     OwnScreenActable*)
(*   lend-under-picker  a view lends the card under the picker it opened    *)
(*                                                        CardYieldsToPicker *)
(*                                                                         *)
(* A view's `/model` picker for a subagent's wait is not an item of its own: *)
(* it stands where the card would (src/core/app/app_agents_runtime.zig       *)
(* `modelPickerOpenFor`, `childWaitsForCard`, `viewShows`). While the picker  *)
(* is queued for the view to open (`picker`, `picker_open` false: the        *)
(* worker's `.open_model_picker` event, `hasPendingModelPicker`) or open, no *)
(* card is lent for that child (`CardYieldsToPicker`) and the view counts the *)
(* item as shown, so the footer stays quiet (`ShownNow`). A model choice and *)
(* the wait it continues arrive in one action, `ModelChosen`, which changes  *)
(* nothing but where the choice goes; closing the picker without a choice    *)
(* frees the item, and the next pass lends the card again (`PickerCloses`).  *)
(* The new model's identity is not modelled: what the rules need is that the *)
(* wait survives the choice and the choice reaches its owner. While the view  *)
(* holds a picker, the picker is its one modal: `lendPrompt` lends nothing    *)
(* (`CanLend`), a card the view already held goes back (`PickerQueued`), the  *)
(* picker counts as the view's item (`OneAtATime`), and the child it stands   *)
(* for keeps it (`PickerHolds`). A picker that closes or takes a choice frees *)
(* the view, so the next pass lends its tree's oldest waiting item again      *)
(* (`PickerCloses`, `ModelChosen`, `OldestFirst`).                          *)
(*                                                                         *)
(* The one-step settle is `clock` and `last_change`. A change to the items  *)
(* (raise, end, deadline, close, stop, switch, the alternate screen, the    *)
(* view's own prompt) stamps `last_change` with the new `clock`. A design   *)
(* that copies (`a`, `current`) is allowed to draw the old copy in exactly  *)
(* that one state, and `Sync`, the next pass, moves past it, so a design    *)
(* that never settles fails on the next pass. `ShownWhenFree` and           *)
(* `NoStaleShown` say so.                                                  *)
(*                                                                         *)
(* A child's status row can outlive the wait it showed. Today a refused      *)
(* request resent by the parent's follow-up, and a turn that ends on the     *)
(* error, leave the row saying `need_user`: `finish_prompt` resets the stream *)
(* with `resetStream(app, agent, false)` (src/core/app/app_worker_runtime.zig: *)
(* 1599) and so clears no recovery status, and the module's own clear runs    *)
(* only when its request succeeded or was cancelled                            *)
(* (src/core/app/../agent/runtime/request_recovery.zig:348-360, :419-425).    *)
(* `row` is that row; `kind` is the wait that is really there. A view must    *)
(* read `kind` to decide what to show and may read `row` only for the reason. *)
(* The card lets Ctrl+O through to the full transcript: that is input routing *)
(* and a test proves it, not this model.                                      *)
(*                                                                         *)
(* Approvals are modelled only as far as the one-item order needs them: an  *)
(* approval is a `prompt` item here. Its routing, its registry, the note's  *)
(* authority and the review copy are `tests/tla/subagent/                  *)
(* TuiParentApproval.tla` (NoStaleLent, NoStalePrompt, Authority).          *)
(*                                                                         *)
(* Code the actions stand for:                                              *)
(*   Raise        a worker raises a prompt or starts a status wait          *)
(*                (worker_runtime.zig:3608; orchestrator.zig:5120-5145)     *)
(*   Sync         `lendPrompt` (app_agents_runtime.zig:1198-1219),          *)
(*                `settleLentQuestion` (:1245-1250) and `waitingNote`       *)
(*                (:1574-1605) in one pass of src/main.zig:3495-3503        *)
(*   SwitchScreen `attach` returns a lent prompt (:2504-2508)               *)
(*   OwnPrompt    a view's own prompt returns the lent one                  *)
(*                (app_worker_runtime.zig:1410-1414)                        *)
(*   Stop, Close  `stopSet` returns a lent prompt, then cancels (:2253-2260)*)
(*   End, Deadline the child ends its wait by itself; `settleLentQuestion`  *)
(*                clears the lent copy a pass later; an MCP deadline does   *)
(*                the same (app_agent_runtime.zig:641-680)                  *)
(*   Act          an action pressed on what is shown, which must reach the  *)
(*                child that owns it (`answerLentQuestion`, :1256-1265)     *)
(*   MainTells, MainStops a note from the child (tool_host.zig:3141-3155)  *)
(*                and main's only actions on it: tell, stop, close          *)
(*   AltOpen      the file-approval screen or a catalog menu takes the      *)
(*                alternate buffer (src/ui/shell_runtime.zig:58-63;         *)
(*                src/main.zig:3069)                                        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
  MainKids,   \* children in main's tree
  InstKids,   \* children in the instance's tree
  ChildScreens, \* children the person may be looking at
  Design,     \* "a" | "b" | "current"
  Mutant,     \* "none" or one defect from the list above
  Hazards     \* "none" keeps only raise, act and tell; "all" adds the rest

Views == {"main", "inst"}
Kids == MainKids \cup InstKids
Screen == Views \cup ChildScreens
MaxClock == 6
MaxLive == 2

Tree(k) == IF k \in MainKids THEN "main" ELSE "inst"
KidsOf(v) == {k \in Kids : Tree(k) = v}

ASSUME Design \in {"a", "b", "current"}
ASSUME Mutant \in {"none", "no-wait-card", "footer-blind", "picker-to-screen",
                   "no-settle", "lend-under-alt", "two-shown", "cross-tree",
                   "note-content", "main-answers", "view-only", "row-as-wait",
                   "lend-under-picker"}
ASSUME Hazards \in {"none", "all"}

VARIABLES
  kind,        \* each child: "none", "prompt" (B, C, D) or "wait" (E)
  row,         \* its status row: "none", "live" (it waits) or "stale" (it
               \* still says need_user and nothing waits)
  asked,       \* its order stamp while it waits: 0, or the clock when it came
  alive,       \* "open" or "closed"
  screen,      \* the person's current screen: a view or a child's own
  alt,         \* "none" or "owned" (the alternate screen)
  own_prompt,  \* each view: whether its own prompt is active
  shown,       \* each view: the child whose item the lend holds (design a)
  picker,      \* each view: the child whose wait its model picker is for
  picker_open, \* each view: whether that picker has opened (false: queued)
  served,      \* where the last action went
  main_did,    \* main's last action on a note
  note_text,   \* what the child's note carried
  own_blocked, \* the child's own screen cannot act on its item
  clock,       \* passes and ticks
  last_change  \* the clock of the last change to the items

\* The picker a view holds for a child, whether queued or open, and whether
\* the card must stay back for it.
PickerHolds(k) == \E v \in Views : picker[v] = k
HeldByPicker(k) == PickerHolds(k) /\ Mutant # "lend-under-picker"

vars == <<kind, row, asked, alive, screen, alt, own_prompt, shown, picker,
          picker_open, served, main_did, note_text, own_blocked, clock,
          last_change>>

Live(k) == kind[k] # "none" /\ alive[k] = "open"
LiveCount == Cardinality({k \in Kids : Live(k)})

\* Whether the current design can show a wait with no prompt. Today it cannot.
HiddenWait(k) == Design = "current" /\ Mutant = "no-wait-card" /\ kind[k] = "wait"
\* What a view can see of a child: its live wait. `row-as-wait` is the defect
\* the spike found, a view that reads the status row instead, so a row that
\* outlived its wait is shown as if the child still waited.
Visible(k) == IF Mutant = "row-as-wait" THEN row[k] # "none" ELSE Live(k)

\* The items a view can show, and the oldest of them. `Oldest` is the truth
\* the rules compare against; `LendTarget` is what the design lends, which
\* today leaves a wait with no prompt out.
Lendable(k) == Visible(k) /\ ~HiddenWait(k)
Candidates(v) == {k \in KidsOf(v) : Visible(k)}
Oldest(v) ==
  IF Candidates(v) = {} THEN "none"
  ELSE CHOOSE k \in Candidates(v) : \A j \in Candidates(v) : asked[k] <= asked[j]
LendCandidates(v) == {k \in KidsOf(v) : Lendable(k) /\ ~HeldByPicker(k)}
OldestLendable(v) ==
  IF LendCandidates(v) = {} THEN "none"
  ELSE CHOOSE k \in LendCandidates(v) : \A j \in LendCandidates(v) : asked[k] <= asked[j]

LendTarget(v) == IF Mutant = "cross-tree" THEN OldestLendable("main") ELSE OldestLendable(v)

\* The item a view shows. `a` and `current` hold a copy in `shown`; `b` derives
\* it from the live state, so no settle is needed there.
Projection(v) ==
  IF v = screen /\ alt = "none" /\ ~own_prompt[v] /\ picker[v] = "none"
     /\ LendTarget(v) # "none"
  THEN {LendTarget(v)} ELSE {}
Shown(v) == IF Design = "b" THEN Projection(v) ELSE shown[v]

\* What the lend does in one pass. A stale copy is discarded first, then the
\* oldest item is lent when the view is free and the alternate screen is not
\* owned.
StaleCopy(v) == Mutant # "no-settle" /\ \E k \in shown[v] : ~(Live(k) /\ Tree(k) = v)
OtherKid(v) == CHOOSE j \in KidsOf(v) : Lendable(j) /\ j \notin shown[v]
Second(v) ==
  IF Mutant = "two-shown" /\ {j \in KidsOf(v) : Lendable(j) /\ j \notin shown[v]} # {}
  THEN {OtherKid(v)} ELSE {}
CanLend(v) ==
  (alt = "none" \/ Mutant = "lend-under-alt") /\ ~own_prompt[v] /\
  (picker[v] = "none" \/ Mutant = "lend-under-picker") /\
  LendTarget(v) # "none"
LentAfter(v) ==
  IF Design = "b" THEN shown[v]
  ELSE IF v # screen THEN {}
  (* A stale copy is discarded and the oldest item is lent in the same pass,
     as `settleLentQuestion` then `lendPrompt` do (src/main.zig:3501-3502). *)
  ELSE IF ~StaleCopy(v) /\ shown[v] # {} THEN shown[v] \cup Second(v)
  ELSE IF CanLend(v) THEN {LendTarget(v)}
  ELSE {}

\* The footer note and the list word. Today they count every wait. A design
\* counts only a wait the current screen does not show. The IF keeps an index
\* by `screen` defined when the person is on a child's own screen.
ShownInView == IF screen \in Views THEN Shown(screen) ELSE {}
OwnHere == IF screen \in Views THEN own_prompt[screen] ELSE FALSE
ShownNow(k) == k \in ShownInView \/ screen = k \/ PickerHolds(k)
FooterSays(k) ==
  IF Mutant = "footer-blind" THEN Live(k)
  ELSE Live(k) /\ ~ShownNow(k)

\* What the person can press: an item shown in the view, or its own screen.
Showable(k) == k \in ShownInView \/ (screen = k /\ ~own_blocked)
               \/ PickerHolds(k)

Init ==
  /\ kind = [k \in Kids |-> "none"]
  /\ row = [k \in Kids |-> "none"]
  /\ asked = [k \in Kids |-> 0]
  /\ alive = [k \in Kids |-> "open"]
  /\ screen = "main"
  /\ alt = "none"
  /\ own_prompt = [v \in Views |-> FALSE]
  /\ shown = [v \in Views |-> {}]
  /\ picker = [v \in Views |-> "none"]
  /\ picker_open = [v \in Views |-> FALSE]
  /\ served = "none"
  /\ main_did = "none"
  /\ note_text = "none"
  /\ own_blocked = FALSE
  /\ clock = 0
  /\ last_change = 0

\* A child raises a person-only item. Its note reaches its parent, with a
\* reason only.
Raise(k, item) ==
  /\ alive[k] = "open"
  /\ kind[k] = "none"
  /\ LiveCount < MaxLive
  /\ clock < MaxClock - 1
  /\ kind' = [kind EXCEPT ![k] = item]
  /\ row' = [row EXCEPT ![k] = "live"]
  /\ asked' = [asked EXCEPT ![k] = clock + 1]
  /\ note_text' = IF Mutant = "note-content" THEN "content" ELSE "reason"
  /\ own_blocked' = IF Mutant = "view-only" THEN TRUE ELSE own_blocked
  (* A lend is tied to the child's current item: a new item for the same child
     returns the view's copy of the old one, so the next pass lends the new
     item (design A). Design B stores nothing. *)
  /\ shown' = [v \in Views |-> shown[v] \ {k}]
  /\ clock' = clock + 1
  /\ last_change' = clock + 1
  /\ UNCHANGED <<alive, screen, alt, own_prompt, served, main_did, picker, picker_open>>

\* One pass of the main loop: settle a stale copy and lend the oldest.
Sync ==
  /\ clock < MaxClock
  /\ shown' = [v \in Views |-> LentAfter(v)]
  /\ clock' = clock + 1
  /\ UNCHANGED <<kind, row, asked, alive, screen, alt, own_prompt, served,
                 main_did, note_text, own_blocked, last_change, picker, picker_open>>

\* The person switches screens. A lent copy goes back to its child.
SwitchScreen(to) ==
  /\ clock < MaxClock
  /\ to \in Screen
  /\ to # screen
  /\ screen' = to
  /\ shown' = [v \in Views |-> IF Design = "b" THEN shown[v] ELSE {}]
  /\ clock' = clock + 1
  /\ last_change' = clock + 1
  /\ UNCHANGED <<kind, row, asked, alive, alt, own_prompt, served, main_did,
                 note_text, own_blocked, picker, picker_open>>

\* The view gets its own prompt, which returns the lent one.
OwnPrompt ==
  /\ clock < MaxClock
  /\ Hazards = "all"
  /\ screen \in Views
  /\ ~OwnHere
  /\ picker' = [v \in Views |-> IF v = screen THEN "none" ELSE picker[v]]
  /\ picker_open' = [v \in Views |-> IF v = screen THEN FALSE ELSE picker_open[v]]
  /\ own_prompt' = [v \in Views |-> own_prompt[v] \/ v = screen]
  /\ shown' = [v \in Views |-> IF Design = "b" THEN shown[v] ELSE {}]
  /\ clock' = clock + 1
  /\ last_change' = clock + 1
  /\ UNCHANGED <<kind, row, asked, alive, screen, alt, served, main_did, note_text, own_blocked, picker, picker_open>>

OwnPromptDone ==
  /\ clock < MaxClock
  /\ Hazards = "all"
  /\ \E v \in Views : own_prompt[v]
  /\ own_prompt' = [v \in Views |-> FALSE]
  /\ clock' = clock + 1
  /\ last_change' = clock + 1
  /\ UNCHANGED <<kind, row, asked, alive, screen, alt, shown, served, main_did,
                 note_text, own_blocked, picker, picker_open>>

\* The child's wait ends by itself: its answer went in, its turn ended, or its
\* MCP deadline passed. `finish_prompt` resets the stream without clearing the
\* row (src/core/app/app_worker_runtime.zig:1598), so this is the one case a
\* stale row can still come from; the probes cleared the resend (P1) and the
\* stop (P2). The lend settles a pass later.
ChildEnds(k) ==
  /\ clock < MaxClock
  /\ Hazards = "all"
  /\ Live(k)
  /\ kind' = [kind EXCEPT ![k] = "none"]
  /\ row' = [row EXCEPT ![k] = "stale"]
  /\ asked' = [asked EXCEPT ![k] = 0]
  /\ clock' = clock + 1
  /\ last_change' = clock + 1
  /\ UNCHANGED <<alive, screen, alt, own_prompt, shown, served, main_did,
                 note_text, own_blocked, picker, picker_open>>

Deadline(k) == ChildEnds(k)

\* A refused request is sent again with no new prompt: the parent's follow-up
\* takes it as one (`parent_may_continue`, src/core/subagent/managed_owner.zig:
\* 371-373). The request is on the wire, nothing waits, and the row clears:
\* the probe on b205b3bfd4 shows `event=responding ... status=clear` on the
\* resend's first byte (P1), so this action clears the row too.
Resend(k) ==
  /\ clock < MaxClock
  /\ kind[k] # "none"
  /\ row[k] = "live"
  /\ kind' = [kind EXCEPT ![k] = "none"]
  /\ row' = [row EXCEPT ![k] = "none"]
  /\ asked' = [asked EXCEPT ![k] = 0]
  /\ clock' = clock + 1
  /\ last_change' = clock + 1
  /\ UNCHANGED <<alive, screen, alt, own_prompt, shown, served, main_did,
                 note_text, own_blocked, picker, picker_open>>

\* The recovery module's own clear of a row whose wait is gone
\* (request_recovery.zig:348-360 for a success, :419-425 for a cancel).
RowClears(k) ==
  /\ clock < MaxClock
  /\ kind[k] = "none"
  /\ row[k] # "none"
  /\ row' = [row EXCEPT ![k] = "none"]
  /\ UNCHANGED <<kind, asked, alive, screen, alt, own_prompt, shown, served,
                 main_did, note_text, own_blocked, clock, last_change, picker, picker_open>>

\* Main stops or closes the child: the lend returns in the same step
\* (`stopSet`).
StopOrClose(k, how) ==
  /\ clock < MaxClock
  /\ Hazards = "all"
  /\ Live(k)
  /\ alive' = [alive EXCEPT ![k] = "closed"]
  /\ kind' = [kind EXCEPT ![k] = "none"]
  \* The stop's cancel reaches the module, which clears the row: the probe on
  \* b205b3bfd4 shows `event=user_cancel ... status=clear` (P2).
  /\ row' = [row EXCEPT ![k] = "none"]
  /\ asked' = [asked EXCEPT ![k] = 0]
  /\ shown' = [v \in Views |-> shown[v] \ {k}]
  /\ picker' = [v \in Views |-> IF picker[v] = k THEN "none" ELSE picker[v]]
  /\ picker_open' = [v \in Views |-> IF picker[v] = k THEN FALSE ELSE picker_open[v]]
  /\ main_did' = how
  /\ clock' = clock + 1
  /\ last_change' = clock + 1
  /\ UNCHANGED <<screen, alt, own_prompt, served, note_text, own_blocked>>

\* The alternate screen takes and gives back the terminal.
AltOpen ==
  /\ clock < MaxClock
  /\ Hazards = "all"
  /\ alt = "none"
  /\ alt' = "owned"
  /\ shown' = [v \in Views |-> IF Design = "b" THEN shown[v] ELSE {}]
  /\ clock' = clock + 1
  /\ last_change' = clock + 1
  /\ UNCHANGED <<kind, row, asked, alive, screen, own_prompt, served, main_did,
                 note_text, own_blocked, picker, picker_open>>

AltClose ==
  /\ clock < MaxClock
  /\ Hazards = "all"
  /\ alt = "owned"
  /\ alt' = "none"
  /\ clock' = clock + 1
  /\ last_change' = clock + 1
  /\ UNCHANGED <<kind, row, asked, alive, screen, own_prompt, shown, served,
                 main_did, note_text, own_blocked, picker, picker_open>>

\* The person presses an action on what is shown. It must reach the child.
Act(k) ==
  /\ Showable(k)
  /\ served' = IF Mutant = "picker-to-screen" /\ screen \in Views THEN "screen_agent" ELSE "owner"
  /\ UNCHANGED <<kind, row, asked, alive, screen, alt, own_prompt, shown,
                 main_did, note_text, own_blocked, clock, last_change, picker, picker_open>>

\* Main acts on the child's note: tell the person, stop, or close. It never
\* answers the item.
MainTells(k) ==
  /\ clock < MaxClock
  /\ Hazards = "all"
  /\ Live(k)
  /\ main_did' = "tell"
  /\ UNCHANGED <<kind, row, asked, alive, screen, alt, own_prompt, shown,
                 served, note_text, own_blocked, clock, last_change, picker, picker_open>>

MainStops(k) ==
  /\ clock < MaxClock
  /\ Hazards = "all"
  /\ Live(k)
  /\ alive' = [alive EXCEPT ![k] = "closed"]
  /\ kind' = [kind EXCEPT ![k] = "none"]
  /\ row' = [row EXCEPT ![k] = "none"]
  /\ asked' = [asked EXCEPT ![k] = 0]
  /\ shown' = [v \in Views |-> shown[v] \ {k}]
  /\ picker' = [v \in Views |-> IF picker[v] = k THEN "none" ELSE picker[v]]
  /\ picker_open' = [v \in Views |-> IF picker[v] = k THEN FALSE ELSE picker_open[v]]
  /\ main_did' = "stop"
  /\ clock' = clock + 1
  /\ last_change' = clock + 1
  /\ UNCHANGED <<screen, alt, own_prompt, served, note_text, own_blocked>>

\* A defect: main answers the item itself.
MainAnswers(k) ==
  /\ clock < MaxClock
  /\ Mutant = "main-answers"
  /\ Live(k)
  /\ kind' = [kind EXCEPT ![k] = "none"]
  /\ row' = [row EXCEPT ![k] = "none"]
  /\ asked' = [asked EXCEPT ![k] = 0]
  /\ main_did' = "answer"
  /\ clock' = clock + 1
  /\ last_change' = clock + 1
  /\ UNCHANGED <<alive, screen, alt, own_prompt, shown, served, note_text,
                 own_blocked, picker, picker_open>>

\* The person's answer on the item (the card's Change model, or the
\* out-of-credits picker's "Switch to another model") returns the card and
\* queues the picker the view opens for that child (`workerBridgeOpenModelPicker`
\* sets the target when the event drains).
PickerQueued(k) ==
  /\ clock < MaxClock
  /\ Hazards = "all"
  /\ Live(k)
  /\ picker[Tree(k)] = "none"
  /\ ~own_prompt[Tree(k)]
  /\ picker' = [v \in Views |-> IF v = Tree(k) THEN k ELSE picker[v]]
  /\ picker_open' = [v \in Views |-> IF v = Tree(k) THEN FALSE ELSE picker_open[v]]
  \* The picker is the view's one modal, so any card it holds goes back.
  /\ shown' = [v \in Views |-> IF v = Tree(k) THEN {} ELSE shown[v]]
  /\ clock' = clock + 1
  /\ last_change' = clock + 1
  /\ UNCHANGED <<kind, row, asked, alive, screen, alt, own_prompt, served,
                 main_did, note_text, own_blocked>>

\* The main loop drains that event: the picker opens, and the card stays back
\* (`modelPickerOpenFor` in `childWaitsForCard` and `viewShows`).
PickerOpens(v) ==
  /\ clock < MaxClock
  /\ Hazards = "all"
  /\ picker[v] # "none"
  /\ ~picker_open[v]
  /\ picker_open' = [w \in Views |-> IF w = v THEN TRUE ELSE picker_open[w]]
  /\ clock' = clock + 1
  /\ last_change' = clock + 1
  /\ UNCHANGED <<kind, row, asked, alive, screen, alt, own_prompt, shown,
                 picker, served, main_did, note_text, own_blocked>>

\* The person leaves the picker without a choice: its target is cleared and
\* the next pass lends the card again (`settleModelChoiceTarget`, then
\* `lendPrompt`).
PickerCloses(v) ==
  /\ clock < MaxClock
  /\ Hazards = "all"
  /\ picker[v] # "none"
  /\ picker' = [w \in Views |-> IF w = v THEN "none" ELSE picker[w]]
  /\ picker_open' = [w \in Views |-> IF w = v THEN FALSE ELSE picker_open[w]]
  /\ shown' = [w \in Views |-> IF w = v THEN {} ELSE shown[w]]
  /\ clock' = clock + 1
  /\ last_change' = clock + 1
  /\ UNCHANGED <<kind, row, asked, alive, screen, alt, own_prompt, served,
                 main_did, note_text, own_blocked>>

\* The person picks a model for the child the picker holds: the wait keeps its
\* kind, row and order, and the choice reaches the child, which sends the
\* request again on the new model (`orchestrator.zig`, non-root `.switch_model`
\* keeps the wait with `waitForSend` and resends).
ModelChosen(v) ==
  /\ clock < MaxClock
  /\ Hazards = "all"
  /\ picker[v] # "none"
  /\ picker_open[v]
  /\ Live(picker[v])
  /\ served' = IF Mutant = "picker-to-screen" THEN "screen_agent" ELSE "owner"
  /\ picker' = [w \in Views |-> IF w = v THEN "none" ELSE picker[w]]
  /\ picker_open' = [w \in Views |-> IF w = v THEN FALSE ELSE picker_open[w]]
  /\ shown' = [w \in Views |-> IF w = v THEN {} ELSE shown[w]]
  /\ clock' = clock + 1
  /\ last_change' = clock + 1
  /\ UNCHANGED <<kind, row, asked, alive, screen, alt, own_prompt,
                 main_did, note_text, own_blocked>>

Finished ==
  /\ clock = MaxClock
  /\ UNCHANGED vars

Next ==
  \/ \E k \in Kids, item \in {"prompt", "wait"} : Raise(k, item)
  \/ \E k \in Kids : ChildEnds(k) \/ Deadline(k) \/ MainTells(k) \/ MainStops(k)
       \/ MainAnswers(k) \/ Act(k) \/ Resend(k) \/ RowClears(k)
  \/ \E k \in Kids, how \in {"stop", "close"} : StopOrClose(k, how)
  \/ \E to \in Screen : SwitchScreen(to)
  \/ \E k \in Kids : PickerQueued(k)
  \/ \E v \in Views : PickerOpens(v) \/ PickerCloses(v) \/ ModelChosen(v)
  \/ Sync
  \/ OwnPrompt
  \/ OwnPromptDone
  \/ AltOpen
  \/ AltClose
  \/ Finished

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ kind \in [Kids -> {"none", "prompt", "wait"}]
  /\ row \in [Kids -> {"none", "live", "stale"}]
  /\ asked \in [Kids -> 0..MaxClock]
  /\ alive \in [Kids -> {"open", "closed"}]
  /\ screen \in Screen
  /\ alt \in {"none", "owned"}
  /\ own_prompt \in [Views -> BOOLEAN]
  /\ \A v \in Views : shown[v] \subseteq Kids
  /\ \A v \in Views : picker[v] \in KidsOf(v) \cup {"none"}
  /\ picker_open \in [Views -> BOOLEAN]
  /\ \A v \in Views : picker[v] = "none" => ~picker_open[v]
  /\ served \in {"none", "owner", "screen_agent"}
  /\ main_did \in {"none", "tell", "stop", "close", "answer"}
  /\ note_text \in {"none", "reason", "content"}
  /\ own_blocked \in BOOLEAN
  /\ clock \in 0..MaxClock
  /\ last_change \in 0..MaxClock

\* When a view is on screen, the alternate screen is free and the view shows
\* nothing of its own, the oldest item in its tree is shown there. A design
\* that copies is allowed exactly the state in which the item changed.
ShownWhenFree ==
  IF screen \in Views /\ alt = "none" /\ ~OwnHere /\ picker[screen] = "none"
     /\ Oldest(screen) # "none"
  THEN Oldest(screen) \in Shown(screen)
       \/ (Design # "b" /\ clock = last_change)
  ELSE TRUE

\* One item at a time in a view, and the view's own prompt counts as one.
OneAtATime ==
  \A v \in Views :
    Cardinality(Shown(v)) + (IF own_prompt[v] THEN 1 ELSE 0)
    + (IF picker[v] # "none" THEN 1 ELSE 0) <= 1

\* No card is lent under the picker that stands where it would, queued or open.
CardYieldsToPicker ==
  \A v \in Views : \A k \in shown[v] : ~PickerHolds(k)

\* A view shows its tree's oldest waiting item.
OldestFirst ==
  \A v \in Views : \A k \in Shown(v) : \A j \in Kids :
    (Live(j) /\ Tree(j) = v /\ j # k) => asked[k] < asked[j]

\* The footer and the list say "needs you" for a wait only when the person's
\* screen does not show it.
FooterQuietForShown == \A k \in Kids : FooterSays(k) => (Live(k) /\ ~ShownNow(k))

\* An action pressed on a shown item reaches the child that owns it, never the
\* screen's own agent.
ActionReachesOwner == served # "screen_agent"

\* What a view shows belongs to a child that still exists and still waits. A
\* copying design may lag by the state that changed.
NoStaleShown ==
  \A v \in Views : \A k \in Shown(v) :
    (Live(k) /\ Tree(k) = v) \/ (Design # "b" /\ clock = last_change)

\* Nothing is lent or drawn while the alternate screen is owned.
HeldUnderAltScreen == alt = "none" \/ (\A v \in Views : Shown(v) = {})

\* An item shows only in its own tree's view.
InstanceScope == \A v \in Views : \A k \in Shown(v) : Tree(k) = v

\* A view shows an item only while the child really waits on it: a status row
\* that outlived its wait may supply the words, never the item. A copying
\* design may lag by the state that changed.
ShownOnlyWhileWaiting ==
  \A v \in Views : \A k \in Shown(v) :
    Live(k) \/ (Design # "b" /\ clock = last_change)

\* The note carries a reason only, never a question, a field value or a URL.
NoSecretToModel == note_text # "content"

\* Main only tells, stops or closes; it never answers the item.
MainOnlyTellsOrStops == main_did # "answer"

\* On the child's own screen the person can always act on its item.
OwnScreenActable == \A k \in Kids : (screen = k /\ Live(k)) => ~own_blocked

=============================================================================
