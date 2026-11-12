---- MODULE AgentsMenu ----
\* The agent list that Down on an empty composer, Ctrl+X, and /agents open
\* (src/core/app/app_agents_runtime.zig: AgentsMenu, openMenu, moveMenu,
\* submitMenu, backMenu, closeMenu, searchChanged, pressCloseKey, switchList).
\*
\* The list shows every open agent: each instance in launch order, followed
\* by its own subagents. It opens on the agent on screen, and its highlight is
\* a preview: Up and Down move the highlight one row and show the agent it
\* lands on at once. Up on the first row has nothing above it, so it closes the
\* list, and the agent shown stays. Down on the last row stays there. Enter
\* closes the list and keeps the highlighted agent on screen, so its composer
\* takes typing. Esc, Ctrl+X, and Ctrl+C close the list and show again the
\* agent it opened on (`origin`), or keep the agent shown when that one closed
\* meanwhile. A paste, or another surface taking the footer, closes the list
\* and keeps the agent shown.
\*
\* Typing searches the list (SearchKeys): only the agents whose name, title, or
\* purpose (what a subagent is for) has the text stay as rows (`hidden` holds
\* the rest; which agents a text matches is left open). A search edit that
\* hides the highlighted row moves the highlight to the agent on screen when it
\* still matches, else to the first match, and shows it, as a move does. With
\* no match there is no row, and the agent shown stays. While there is a
\* search, Backspace and Delete erase it and Esc clears it, so neither closes
\* an agent or the list.
\*
\* The highlight follows its agent, not its row, while the rows change under
\* it: a subagent starts, finishes and reorders, closes, or, under a search,
\* starts or stops matching it when its title changes. When the highlighted
\* agent leaves the rows, the highlight moves to the agent on screen, or to the
\* first row when a search hides that one too. Only a key, or the close of the
\* agent on screen, changes the agent on screen.
\*
\* Delete arms a close of the highlighted row, and a second Delete closes it
\* and every subagent it started: a subagent, or an instance while another one
\* stays open. /close on an instance's screen, with the list closed, closes
\* that instance the same way, and the main agent can close one of its
\* subagents at any time. Whenever the agent on screen closes, the row just
\* above the closed agent takes its place: closing the last of ten rows shows
\* the ninth, and closing that one the eighth. The highlighted agent is the one
\* shown, so the highlight moves there too. The first row has none above, so
\* the next open instance takes its place.
\*
\* The environment acts at any time, with the list open or closed: a subagent
\* starts, its instance's subagents reorder (one starts or finishes work), the
\* main agent closes one, or, under a search, an agent's title changes.
\*
\* Subagents here are started only by instances. fx also lists a subagent's
\* own subagents right under it, so the row above a subagent is above its
\* whole branch, as the row above an instance is above its subagents.
\*
\* `act` names the step that led to the state; the action properties read it.
\* `Mutation` plants one bug, and each must be caught by its named rule:
\*
\*   move_only     a move changes only the highlight, as fx did before this
\*                 change                                             PreviewOnMove
\*   search_stays  a search edit moves the highlight without showing it  PreviewOnSearch
\*   up_stays      Up on the first row stays there                     UpOnTopCloses
\*   close_parent  a close of the agent on screen shows its instance or
\*                 the next instance, not the row above                CloseShowsRowAbove
\*   back_stays    Esc keeps the agent shown, not the one the list
\*                 opened on                                           BackToOrigin
\*   paste_back    a paste goes back to the agent the list opened on   ScreenOnlyOnKeys
\*   stale_origin  the agent the list opened on stays its origin after
\*                 it closed                                           OriginListed
\*   enter_noop    Enter closes the list without showing the row       EnterShowsSelection
\*   open_first    the list opens on its first row, not the agent on
\*                 screen                                              OpensOnScreen
\*   row           the highlight stays on its row, not its agent, when
\*                 the rows change                                     SelectionKept
\*   stale_sel     the highlight stays on an agent that closed         SelListed
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    InstanceOrder,   \* the instances, in launch order
    Subs,            \* the subagents that can ever be open
    Parent,          \* Parent[s]: the instance that started subagent s
    InitOrder,       \* the list's order at the start: instances and open subagents
    EnvEvents,       \* whether subagents start, reorder, close, and retitle by themselves
    SearchKeys,      \* whether the person types a search
    Mutation         \* "none", or the planted bug to check

VARIABLES
    order,      \* every open agent, in switch order
    onScreen,   \* the agent on screen
    open,       \* whether the list is open
    sel,        \* the highlighted agent while open, None while closed
    armed,      \* the agent the first Delete armed, or None
    origin,     \* the agent the list opened on while it is open, or None
    searching,  \* whether a search is typed
    hidden,     \* the open agents the search hides
    act         \* the step that led here

vars == <<order, onScreen, open, sel, armed, origin, searching, hidden, act>>

None == "none"
Acts == {"init", "open", "down", "up", "enter", "back", "close", "search", "arm",
         "delete", "slash_close", "env_start", "env_reorder", "env_close", "env_retitle"}

Range(s) == {s[i] : i \in DOMAIN s}
Pos(s, x) == CHOOSE i \in DOMAIN s : s[i] = x
Clamp(i, n) == IF i < 1 THEN 1 ELSE IF i > n THEN n ELSE i
Remove(s, gone) == SelectSeq(s, LAMBDA y : y \notin gone)

Instances == Range(InstanceOrder)
Agents == Instances \cup Subs
IsInst(a) == a \in Instances
AliveInsts == {a \in Range(order) : IsInst(a)}

\* The rows the list shows: the open agents the search does not hide.
Filter(s, h) == SelectSeq(s, LAMBDA y : y \notin h)
Rows == Filter(order, hidden)

\* Where the highlight goes in `rows`: `s` while it is listed, else the agent
\* on screen while that one is, else the first row. With no row, it stays on
\* the agent on screen.
Pick(rows, s, screen) ==
    IF s \in Range(rows) THEN s
    ELSE IF screen \in Range(rows) THEN screen
    ELSE IF rows # << >> THEN rows[1]
    ELSE screen

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

\* The highlight after the rows change under it to `rows`: on its agent, or
\* for `row`, on the row it was on.
Kept(rows) ==
    IF ~open THEN None
    ELSE IF Mutation = "row" /\ sel \in Range(Rows) /\ rows # << >>
         THEN rows[Clamp(Pos(Rows, sel), Len(rows))]
         ELSE Pick(rows, sel, onScreen)

\* The list closes, and with it the highlight, an armed close, its origin, and
\* the search.
Ends ==
    /\ open' = FALSE
    /\ sel' = None
    /\ armed' = None
    /\ origin' = None
    /\ searching' = FALSE
    /\ hidden' = {}

Init ==
    /\ order = InitOrder
    /\ onScreen = InstanceOrder[1]
    /\ open = FALSE
    /\ sel = None
    /\ armed = None
    /\ origin = None
    /\ searching = FALSE
    /\ hidden = {}
    /\ act = "init"

\* Down on an empty composer, Ctrl+X, or /agents, with another agent open.
OpenList ==
    /\ ~open
    /\ Len(order) >= 2
    /\ open' = TRUE
    /\ sel' = IF Mutation = "open_first" THEN order[1] ELSE onScreen
    /\ origin' = onScreen
    /\ armed' = None
    /\ act' = "open"
    /\ UNCHANGED <<order, onScreen, searching, hidden>>

\* Up or Down: the highlight moves one row and shows the agent it lands on.
\* Down stops at the last row; Up on the first row closes the list. With no
\* row, under a search that matches nothing, they do nothing.
Move(d) ==
    /\ open
    /\ IF Rows = << >>
       THEN UNCHANGED <<order, onScreen, open, sel, armed, origin, searching, hidden>>
       ELSE IF d < 0 /\ Pos(Rows, sel) = 1 /\ Mutation # "up_stays"
       THEN /\ Ends
            /\ UNCHANGED <<order, onScreen>>
       ELSE LET to == Rows[Clamp(Pos(Rows, sel) + d, Len(Rows))]
            IN /\ sel' = to
               /\ onScreen' = IF Mutation = "move_only" THEN onScreen ELSE to
               /\ armed' = None
               /\ UNCHANGED <<order, open, origin, searching, hidden>>
    /\ act' = IF d > 0 THEN "down" ELSE "up"

\* Enter: the list closes and the highlighted agent stays on screen.
Enter ==
    /\ open
    /\ onScreen' = IF Rows # << >> /\ Mutation # "enter_noop" THEN sel ELSE onScreen
    /\ Ends
    /\ act' = "enter"
    /\ UNCHANGED order

\* Esc with no search, Ctrl+X, or Ctrl+C: the list closes and shows again the
\* agent it opened on, or keeps the one shown when that one closed.
Back ==
    /\ open
    /\ onScreen' = IF origin # None /\ Mutation # "back_stays" THEN origin ELSE onScreen
    /\ Ends
    /\ act' = "back"
    /\ UNCHANGED order

\* A paste, or another surface taking the footer: the list closes and the
\* agent shown stays.
Close ==
    /\ open
    /\ onScreen' = IF Mutation = "paste_back" /\ origin # None THEN origin ELSE onScreen
    /\ Ends
    /\ act' = "close"
    /\ UNCHANGED order

\* A letter starts or grows the search, Backspace or Delete takes one off, and
\* Esc clears it. Each match of the search is one set of hidden agents.
Search ==
    /\ open
    /\ SearchKeys
    /\ \E s \in BOOLEAN, h \in SUBSET Range(order) :
         /\ s \/ searching
         /\ s \/ h = {}
         /\ searching' = s
         /\ hidden' = h
         /\ LET rows == Filter(order, h)
                to == Pick(rows, sel, onScreen)
            IN /\ sel' = to
               /\ onScreen' = IF rows # << >> /\ Mutation # "search_stays" THEN to ELSE onScreen
    /\ armed' = None
    /\ act' = "search"
    /\ UNCHANGED <<order, open, origin>>

\* The first Delete on a row that can close, with no search.
Arm ==
    /\ open
    /\ ~searching
    /\ Closable(sel)
    /\ armed # sel
    /\ armed' = sel
    /\ act' = "arm"
    /\ UNCHANGED <<order, onScreen, open, sel, origin, searching, hidden>>

\* Closes x and what it takes. When the agent on screen closes with it, the
\* row above x takes its place; the first row has none, so the next open
\* instance does. The highlight, when its agent closes, moves to the agent on
\* screen; the origin, when its agent closes, is gone.
CloseAgent(x, label) ==
    LET gone == TreeOf(x)
        newOrder == Remove(order, gone)
        newHidden == hidden \ gone
        screen ==
            IF onScreen \notin gone THEN onScreen
            ELSE IF Pos(order, x) > 1 /\ Mutation # "close_parent" THEN order[Pos(order, x) - 1]
            ELSE IF IsInst(x) THEN NextAlive(x) ELSE Parent[x]
    IN /\ order' = newOrder
       /\ hidden' = newHidden
       /\ onScreen' = screen
       /\ sel' = IF ~open THEN None
                 ELSE IF Mutation = "stale_sel" /\ sel \in gone THEN sel
                 ELSE Pick(Filter(newOrder, newHidden), sel, screen)
       /\ origin' = IF origin \in gone /\ Mutation # "stale_origin" THEN None ELSE origin
       /\ armed' = IF armed \in gone THEN None ELSE armed
       /\ act' = label
       /\ UNCHANGED <<open, searching>>

\* The second Delete closes the armed row.
Delete ==
    /\ open
    /\ ~searching
    /\ armed = sel
    /\ armed # None
    /\ Closable(sel)
    /\ CloseAgent(sel, "delete")

\* /close on an instance's screen, with the list closed and another instance
\* open.
SlashClose ==
    /\ ~open
    /\ IsInst(onScreen)
    /\ Cardinality(AliveInsts) > 1
    /\ CloseAgent(onScreen, "slash_close")

\* A subagent starts, and takes a place among its instance's subagents. Under
\* a search it may match it or not.
EnvStart(a) ==
    /\ EnvEvents
    /\ a \notin Range(order)
    /\ Parent[a] \in Range(order)
    /\ \E g \in Insertions(Group(order, Parent[a]), a), shown \in BOOLEAN :
         /\ searching \/ shown
         /\ order' = WithGroup(Parent[a], g)
         /\ hidden' = IF shown THEN hidden ELSE hidden \cup {a}
    /\ sel' = Kept(Filter(order', hidden'))
    /\ act' = "env_start"
    /\ UNCHANGED <<onScreen, open, armed, origin, searching>>

\* An instance's subagents reorder: one starts or finishes work.
EnvReorder(p) ==
    /\ EnvEvents
    /\ p \in AliveInsts
    /\ Len(Group(order, p)) >= 2
    /\ \E g \in Perms(Group(order, p)) :
          /\ g # Group(order, p)
          /\ order' = WithGroup(p, g)
    /\ sel' = Kept(Filter(order', hidden))
    /\ act' = "env_reorder"
    /\ UNCHANGED <<onScreen, open, armed, origin, searching, hidden>>

\* The main agent closes one of its subagents.
EnvClose(a) ==
    /\ EnvEvents
    /\ a \in Subs
    /\ a \in Range(order)
    /\ CloseAgent(a, "env_close")

\* Under a search, an agent's title changes, and it starts or stops matching.
EnvRetitle(a) ==
    /\ EnvEvents
    /\ searching
    /\ a \in Range(order)
    /\ hidden' = IF a \in hidden THEN hidden \ {a} ELSE hidden \cup {a}
    /\ sel' = Kept(Filter(order, hidden'))
    /\ act' = "env_retitle"
    /\ UNCHANGED <<order, onScreen, open, armed, origin, searching>>

Next ==
    \/ OpenList
    \/ Move(1)
    \/ Move(-1)
    \/ Enter
    \/ Back
    \/ Close
    \/ Search
    \/ Arm
    \/ Delete
    \/ SlashClose
    \/ \E a \in Subs : EnvStart(a) \/ EnvClose(a)
    \/ \E p \in Instances : EnvReorder(p)
    \/ \E a \in Agents : EnvRetitle(a)

Spec == Init /\ [][Next]_vars

----
\* Invariants

TypeOK ==
    /\ order \in Seq(Agents)
    /\ onScreen \in Agents
    /\ open \in BOOLEAN
    /\ sel \in Agents \cup {None}
    /\ armed \in Agents \cup {None}
    /\ origin \in Agents \cup {None}
    /\ searching \in BOOLEAN
    /\ hidden \subseteq Agents
    /\ act \in Acts

\* The rows are the open instances in launch order, each followed by its own
\* subagents, with no agent twice.
WellFormed ==
    /\ Cardinality(Range(order)) = Len(order)
    /\ order = BuildFrom(1, AliveInsts, Groups(order))

\* Some instance always stays open, and the agent on screen is open.
OnScreenListed == onScreen \in Range(order)
LastInstanceStays == AliveInsts # {}

\* While open, the highlight is on a row whenever there is one; while closed,
\* nothing is highlighted, armed, searched, or kept to go back to.
SelListed == (open /\ Rows # << >>) => sel \in Range(Rows)
ClosedNoSel == ~open => (sel = None /\ armed = None /\ origin = None /\ ~searching)

\* Only a search hides rows, and only open agents.
SearchHides == hidden \subseteq Range(order) /\ (~searching => hidden = {})

\* A close is only ever armed for the highlighted row, only for a row Delete
\* can close, and never under a search.
ArmedIsSel == armed # None => (armed = sel /\ Closable(armed) /\ ~searching)

\* The agent Esc goes back to is an open one.
OriginListed == origin # None => origin \in Range(order)

----
\* Action properties

\* A move shows the agent it lands on.
PreviewOnMove == [][(act' \in {"up", "down"} /\ open') => onScreen' = sel']_vars

\* A search edit shows the highlighted row, when there is one.
PreviewOnSearch == [][(act' = "search" /\ Rows' # << >>) => onScreen' = sel']_vars

\* Up on the first row closes the list, and the agent shown stays.
UpOnTopCloses ==
    [][(act' = "up" /\ Rows # << >> /\ Rows[1] = sel) => (~open' /\ onScreen' = onScreen)]_vars

\* The first row a step closed, when it closed one: the closed agent's own,
\* above the subagents that close with it.
FirstGone ==
    CHOOSE i \in DOMAIN order :
        /\ order[i] \notin Range(order')
        /\ \A j \in 1..(i - 1) : order[j] \in Range(order')

\* When the agent on screen closes, the row just above the closed agent takes
\* its place, when there is one.
CloseShowsRowAbove ==
    [][(onScreen \notin Range(order') /\ FirstGone > 1) => onScreen' = order[FirstGone - 1]]_vars

\* Enter keeps the highlighted agent on screen.
EnterShowsSelection == [][act' = "enter" => onScreen' = IF Rows # << >> THEN sel ELSE onScreen]_vars

\* Esc goes back to the agent the list opened on, or keeps the one shown when
\* that one closed.
BackToOrigin == [][act' = "back" => onScreen' = IF origin # None THEN origin ELSE onScreen]_vars

\* The agent on screen changes only on a move, a search edit, Enter, or Esc,
\* or when it closes. A paste and the other surfaces keep it.
ScreenOnlyOnKeys ==
    [][onScreen' # onScreen => (act' \in {"down", "up", "search", "enter", "back"} \/ onScreen \notin Range(order'))]_vars

\* The list opens on the agent on screen, which Esc goes back to.
OpensOnScreen == [][act' = "open" => (sel' = onScreen /\ origin' = onScreen)]_vars

\* While the list stays open, the agent Esc goes back to changes only when it
\* closes.
OriginKept == [][(open /\ open' /\ origin' # origin) => origin \notin Range(order')]_vars

\* While the list stays open, only a move or a search edit changes the
\* highlight, unless its agent leaves the rows.
SelectionKept ==
    [][(open /\ open' /\ act' \notin {"up", "down", "search"} /\ sel \in Range(Rows')) => sel' = sel]_vars

\* When the highlighted agent closes, the highlight moves to the agent on
\* screen, when that one is a row.
FallbackToScreen ==
    [][(open /\ open' /\ sel \notin Range(order') /\ onScreen' \in Range(Rows')) => sel' = onScreen']_vars

\* A move that keeps the list open goes one row, and stops at the last row.
MoveOneRow ==
    [][(act' \in {"up", "down"} /\ open' /\ Rows # << >>) =>
        sel' = Rows[Clamp(Pos(Rows, sel) + (IF act' = "down" THEN 1 ELSE -1), Len(Rows))]]_vars
====
