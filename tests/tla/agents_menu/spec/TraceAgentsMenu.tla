---- MODULE TraceAgentsMenu ----
\* Checks runs of the built fx against AgentsMenu.
\*
\* tests/tla/drivers/agents_menu/binary-to-spec.ts drives zig-out/bin/fx in
\* tmux with seeded key sequences (open, Up, Down, Enter, Esc or Ctrl+X, a
\* paste, search letters and Backspace, Backspace or forward Delete twice,
\* a held Backspace or Delete that clears the search and goes on past it,
\* /close) and releases held subagent turns while the list is open, so rows
\* reorder under the highlight. After every step it reads the model's
\* variables from the pane and the trace log, and writes each run as one
\* sequence of states into TraceData.tla, with the step as `act`. `run` and
\* `pressed` are what the driver pressed, which no pane shows, so it records
\* them from its own keys: TLC then checks what the binary did against them.
\*
\* TLC walks every trace. ConformsToSpec holds when every recorded step is a
\* step of AgentsMenu's Next, so each run is a behavior of the model; the
\* names below re-export the model's rules, checked on what fx did.
EXTENDS Integers, Sequences, FiniteSets, TraceData

CONSTANTS InstanceOrder, Subs, Parent, InitOrder, EnvEvents, SearchKeys, Mutation

VARIABLES order, onScreen, open, sel, armed, origin, searching, hidden, run, pressed, act, trace, at

AM == INSTANCE AgentsMenu

vars == <<order, onScreen, open, sel, armed, origin, searching, hidden, run, pressed, act>>

Load(s) ==
    /\ order = s.order /\ onScreen = s.onScreen /\ open = s.open
    /\ sel = s.sel /\ armed = s.armed /\ origin = s.origin
    /\ searching = s.searching /\ hidden = s.hidden
    /\ run = s.run /\ pressed = s.pressed /\ act = s.act

LoadNext(s) ==
    /\ order' = s.order /\ onScreen' = s.onScreen /\ open' = s.open
    /\ sel' = s.sel /\ armed' = s.armed /\ origin' = s.origin
    /\ searching' = s.searching /\ hidden' = s.hidden
    /\ run' = s.run /\ pressed' = s.pressed /\ act' = s.act

TraceInit == trace \in 1..Len(Traces) /\ at = 1 /\ Load(Traces[trace][1])

TraceNext ==
    /\ at < Len(Traces[trace])
    /\ at' = at + 1
    /\ trace' = trace
    /\ LoadNext(Traces[trace][at + 1])

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, trace, at>>

\* Every trace starts where the model starts.
StartsAtInit == at = 1 => AM!Init

\* Every recorded step is a step of the model.
ConformsToSpec == [][AM!Next]_vars

TypeOK == AM!TypeOK
WellFormed == AM!WellFormed
OnScreenListed == AM!OnScreenListed
LastInstanceStays == AM!LastInstanceStays
SelListed == AM!SelListed
ClosedNoSel == AM!ClosedNoSel
SearchHides == AM!SearchHides
ArmedIsSel == AM!ArmedIsSel
OriginListed == AM!OriginListed
PreviewOnMove == AM!PreviewOnMove
PreviewOnSearch == AM!PreviewOnSearch
UpOnTopCloses == AM!UpOnTopCloses
CloseShowsRowAbove == AM!CloseShowsRowAbove
EnterShowsSelection == AM!EnterShowsSelection
BackToOrigin == AM!BackToOrigin
ScreenOnlyOnKeys == AM!ScreenOnlyOnKeys
OpensOnScreen == AM!OpensOnScreen
OriginKept == AM!OriginKept
SelectionKept == AM!SelectionKept
FallbackToScreen == AM!FallbackToScreen
MoveOneRow == AM!MoveOneRow
RunNeverCloses == AM!RunNeverCloses
====
