---- MODULE AgentsMenu ----
\* The agent list that Down on an empty composer, Ctrl+X, and /agents open
\* (src/core/app/app_agents_runtime.zig: AgentsMenu, openMenu, moveMenu,
\* submitMenu, backMenu, pressCloseKey, switchList).
\*
\* The list shows every open agent: each instance in launch order, followed
\* by its own subagents. Up and Down move only the highlight; the agent on
\* screen changes when the person presses Enter on another row, or when the
\* agent on screen closes. The highlight follows its agent, not its row, while
\* the rows change under it: a subagent starts, finishes and reorders, or
\* closes. When the highlighted agent closes, the highlight moves to the agent
\* on screen. Delete arms a close of the highlighted row, and a second Delete
\* closes it: a subagent, or an instance while another one stays open.
\*
\* The environment acts at any time, with the list open or closed: a subagent
\* starts, its instance's subagents reorder (one starts or finishes work), or
\* the main agent closes one.
\*
\* `act` names the step that led to the state; the action properties read it.
\* `Mutation` plants one bug, and each must be caught by its named rule:
\*
\*   preview     a move shows the row it lands on (fx before this change)  ScreenOnlyOnEnter
\*   enter_noop  Enter closes the list without showing the row             EnterShowsSelection
\*   open_first  the list opens on its first row, not the agent on screen  OpensOnScreen
\*   pin         the highlight snaps back to the agent on screen when the
\*               rows change                                               SelectionKept
\*   stale_sel   the highlight stays on an agent that closed               SelListed
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    InstanceOrder,   \* the instances, in launch order
    Subs,            \* the subagents that can ever be open
    Parent,          \* Parent[s]: the instance that started subagent s
    InitOrder,       \* the list's order at the start: instances and open subagents
    EnvEvents,       \* whether subagents start, reorder, and close by themselves
    Mutation         \* "none", or the planted bug to check

VARIABLES
    order,     \* the list's rows: every open agent, in switch order
    onScreen,  \* the agent on screen
    open,      \* whether the list is open
    sel,       \* the highlighted agent while open, None while closed
    armed,     \* the agent the first Delete armed, or None
    act        \* the step that led here

vars == <<order, onScreen, open, sel, armed, act>>

None == "none"
Acts == {"init", "open", "down", "up", "enter", "back", "arm", "delete",
         "env_start", "env_reorder", "env_close"}

Range(s) == {s[i] : i \in DOMAIN s}
Pos(s, x) == CHOOSE i \in DOMAIN s : s[i] = x
Clamp(i, n) == IF i < 1 THEN 1 ELSE IF i > n THEN n ELSE i
Remove(s, gone) == SelectSeq(s, LAMBDA y : y \notin gone)

Instances == Range(InstanceOrder)
Agents == Instances \cup Subs
IsInst(a) == a \in Instances
AliveInsts == {a \in Range(order) : IsInst(a)}

\* An instance's subagents, in the order the list shows them.
Group(s, p) == SelectSeq(s, LAMBDA y : y \in Subs /\ Parent[y] = p)

\* The list built from each open instance's subagent order: every instance in
\* launch order, each followed by its own subagents.
RECURSIVE BuildFrom(_, _, _)
BuildFrom(i, alive, groups) ==
    IF i > Len(InstanceOrder) THEN << >>
    ELSE LET p == InstanceOrder[i]
         IN (IF p \in alive THEN <<p>> \o groups[p] ELSE << >>)
            \o BuildFrom(i + 1, alive, groups)

Groups(s) == [p \in Instances |-> Group(s, p)]

\* `order` with instance p's subagents replaced by `g`.
WithGroup(p, g) == BuildFrom(1, AliveInsts, [Groups(order) EXCEPT ![p] = g])

\* Every order of the agents in sequence `s`.
Perms(s) ==
    {f \in [1..Len(s) -> Range(s)] :
        \A i, j \in 1..Len(s) : i # j => f[i] # f[j]}

\* `g` with `a` put in at any place.
Insertions(g, a) ==
    {SubSeq(g, 1, k) \o <<a>> \o SubSeq(g, k + 1, Len(g)) : k \in 0..Len(g)}

\* The open instance after x in launch order, wrapping, other than x.
NextAlive(x) ==
    LET n == Len(InstanceOrder)
        i == Pos(InstanceOrder, x)
        at(k) == InstanceOrder[((i - 1 + k) % n) + 1]
        ks == {k \in 1..(n - 1) : at(k) \in Range(order)}
    IN at(CHOOSE k \in ks : \A j \in ks : k <= j)

\* What a close takes: an instance and its subagents, or one subagent.
TreeOf(x) == IF IsInst(x) THEN {x} \cup {s \in Subs : Parent[s] = x} ELSE {x}

\* Delete closes any subagent, and an instance while another one stays open.
Closable(a) == ~IsInst(a) \/ Cardinality(AliveInsts) > 1

\* The highlight after the rows change under it: where it was, unless
\* `pin` snaps it back to the agent on screen.
Kept == IF open /\ Mutation = "pin" THEN onScreen ELSE sel

Init ==
    /\ order = InitOrder
    /\ onScreen = InstanceOrder[1]
    /\ open = FALSE
    /\ sel = None
    /\ armed = None
    /\ act = "init"

\* Down on an empty composer, Ctrl+X, or /agents, with another agent open.
OpenList ==
    /\ ~open
    /\ Len(order) >= 2
    /\ open' = TRUE
    /\ sel' = IF Mutation = "open_first" THEN order[1] ELSE onScreen
    /\ armed' = None
    /\ act' = "open"
    /\ UNCHANGED <<order, onScreen>>

\* Up or Down: the highlight moves one row and stops at either end.
Move(d) ==
    /\ open
    /\ LET to == order[Clamp(Pos(order, sel) + d, Len(order))]
       IN /\ sel' = to
          /\ onScreen' = IF Mutation = "preview" THEN to ELSE onScreen
    /\ armed' = None
    /\ act' = IF d > 0 THEN "down" ELSE "up"
    /\ UNCHANGED <<order, open>>

\* Enter: the list closes and the highlighted agent comes on screen.
Enter ==
    /\ open
    /\ open' = FALSE
    /\ onScreen' = IF Mutation = "enter_noop" THEN onScreen ELSE sel
    /\ sel' = None
    /\ armed' = None
    /\ act' = "enter"
    /\ UNCHANGED order

\* Esc, Ctrl+X, Ctrl+C, a paste, or another surface taking the footer: the
\* list closes and the agent on screen stays.
Back ==
    /\ open
    /\ open' = FALSE
    /\ sel' = None
    /\ armed' = None
    /\ act' = "back"
    /\ UNCHANGED <<order, onScreen>>

\* The first Delete on a row that can close.
Arm ==
    /\ open
    /\ Closable(sel)
    /\ armed # sel
    /\ armed' = sel
    /\ act' = "arm"
    /\ UNCHANGED <<order, onScreen, open, sel>>

\* Closes x and what it takes. The agent on screen, when it closes, gives way
\* to the subagent's instance or to the next open instance; the highlight,
\* when its agent closes, moves to the agent on screen.
CloseAgent(x, label) ==
    LET gone == TreeOf(x)
        screen == IF onScreen \notin gone THEN onScreen
                  ELSE IF IsInst(x) THEN NextAlive(x) ELSE Parent[x]
    IN /\ order' = Remove(order, gone)
       /\ onScreen' = screen
       /\ sel' = IF ~open THEN None
                 ELSE IF sel \in gone
                      THEN (IF Mutation = "stale_sel" THEN sel ELSE screen)
                      ELSE sel
       /\ armed' = IF armed \in gone THEN None ELSE armed
       /\ act' = label
       /\ UNCHANGED open

\* The second Delete closes the armed row.
Delete ==
    /\ open
    /\ armed = sel
    /\ armed # None
    /\ Closable(sel)
    /\ CloseAgent(sel, "delete")

\* A subagent starts, and takes a place among its instance's subagents.
EnvStart(a) ==
    /\ EnvEvents
    /\ a \notin Range(order)
    /\ Parent[a] \in Range(order)
    /\ \E g \in Insertions(Group(order, Parent[a]), a) : order' = WithGroup(Parent[a], g)
    /\ sel' = Kept
    /\ act' = "env_start"
    /\ UNCHANGED <<onScreen, open, armed>>

\* An instance's subagents reorder: one starts or finishes work.
EnvReorder(p) ==
    /\ EnvEvents
    /\ p \in AliveInsts
    /\ Len(Group(order, p)) >= 2
    /\ \E g \in Perms(Group(order, p)) :
          /\ g # Group(order, p)
          /\ order' = WithGroup(p, g)
    /\ sel' = Kept
    /\ act' = "env_reorder"
    /\ UNCHANGED <<onScreen, open, armed>>

\* The main agent closes one of its subagents.
EnvClose(a) ==
    /\ EnvEvents
    /\ a \in Subs
    /\ a \in Range(order)
    /\ CloseAgent(a, "env_close")

Next ==
    \/ OpenList
    \/ Move(1)
    \/ Move(-1)
    \/ Enter
    \/ Back
    \/ Arm
    \/ Delete
    \/ \E a \in Subs : EnvStart(a) \/ EnvClose(a)
    \/ \E p \in Instances : EnvReorder(p)

Spec == Init /\ [][Next]_vars

----
\* Invariants

TypeOK ==
    /\ order \in Seq(Agents)
    /\ onScreen \in Agents
    /\ open \in BOOLEAN
    /\ sel \in Agents \cup {None}
    /\ armed \in Agents \cup {None}
    /\ act \in Acts

\* The rows are the open instances in launch order, each followed by its own
\* subagents, with no agent twice.
WellFormed ==
    /\ Cardinality(Range(order)) = Len(order)
    /\ order = BuildFrom(1, AliveInsts, Groups(order))

\* Some instance always stays open, and it is the one on screen or the
\* instance of the subagent on screen.
OnScreenListed == onScreen \in Range(order)
LastInstanceStays == AliveInsts # {}

\* While open, the highlight is on a listed agent; while closed, nothing is
\* highlighted or armed.
SelListed == open => sel \in Range(order)
ClosedNoSel == ~open => (sel = None /\ armed = None)

\* A close is only ever armed for the highlighted row, and only for a row
\* Delete can close.
ArmedIsSel == armed # None => (armed = sel /\ Closable(armed))

----
\* Action properties

\* The screen changes only on Enter, or when the agent on screen closes.
ScreenOnlyOnEnter ==
    [][onScreen' # onScreen => (act' = "enter" \/ onScreen \notin Range(order'))]_vars

\* Enter shows the highlighted agent.
EnterShowsSelection == [][act' = "enter" => onScreen' = sel]_vars

\* The list opens on the agent on screen.
OpensOnScreen == [][act' = "open" => sel' = onScreen]_vars

\* While the list stays open, only a move changes the highlight, unless its
\* agent closes.
SelectionKept ==
    [][(open /\ open' /\ act' \notin {"up", "down"} /\ sel \in Range(order')) => sel' = sel]_vars

\* When the highlighted agent closes, the highlight moves to the agent on
\* screen.
FallbackToScreen ==
    [][(open /\ open' /\ sel \notin Range(order')) => sel' = onScreen']_vars

\* A move goes one row, and stops at either end.
MoveOneRow ==
    [][act' \in {"up", "down"} =>
        sel' = order[Clamp(Pos(order, sel) + (IF act' = "down" THEN 1 ELSE -1), Len(order))]]_vars
====
