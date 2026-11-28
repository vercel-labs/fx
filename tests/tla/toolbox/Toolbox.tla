------------------------------ MODULE Toolbox ------------------------------
(***************************************************************************)
(* The toolbox (src/core/tooling/toolbox.zig, with the request building in *)
(* src/core/agent/runtime/orchestrator.zig).                               *)
(*                                                                         *)
(* fx sends its built-in tools and one `toolbox` tool, and a menu of the   *)
(* skills, MCP servers, custom tools, and tools moved behind toolbox that  *)
(* the session can use. The tools and the menu are fixed for the session.  *)
(* The model opens an entry, and what it opens arrives at the end of the   *)
(* conversation; it runs a tool through toolbox, or calls one by name, and *)
(* fx checks permission on the real tool first. The MCP catalog changes    *)
(* underneath, fx compacts the conversation, crashes in the middle of a   *)
(* run, and resumes in a new process.                                      *)
(* A search, whose result carries each tool's arguments, is an open here:  *)
(* what it finds arrives at the end of the conversation too.               *)
(*                                                                         *)
(* Each request is recorded as fx sends it, so the rules can say that no   *)
(* request ever changes what an earlier one sent: the cache never breaks.  *)
(*                                                                         *)
(* Bug plants one defect for the mutation configs:                         *)
(*   "append_tool"        an opened or called tool is added to the tools   *)
(*   "live_menu"          the menu follows the catalog's availability      *)
(*   "menu_from_live"     a resume rebuilds the menu from what is up now   *)
(*   "compact_resets_menu"  compaction rebuilds the menu from what is up   *)
(*                        now, as a new conversation does                  *)
(*   "compact_forgets_notes"  after a compaction, fx counts the notes the  *)
(*                        summary replaced as still told                   *)
(*   "skip_admission"     a run goes ahead when permission was denied      *)
(*   "rerun_after_crash"  a resume runs an interrupted call again          *)
(*   "run_needs_open"     a run fails unless its entry was opened in the   *)
(*                        conversation, so compaction strands a tool       *)
(*   "hook_overrides_deny"  a hook's allow is checked before a configured  *)
(*                        deny, so a call the deny covers runs             *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS MaxActions, MaxIds, Bug

\* What the menu lists: a skill, an MCP server, a custom host tool, and a
\* built-in moved behind toolbox (install_skill).
Entries == {"skill", "server", "custom", "install"}
\* What `toolbox {run}` can run, and the menu entry each belongs to.
Runnable == {"echo", "custom", "install"}
Owner(t) == IF t = "echo" THEN "server" ELSE t
\* Entries whose availability the outside world can change.
Live == {"server", "custom"}

BaseTools == <<"builtins", "toolbox">>
InitMenu == Entries
Ids == 1..MaxIds
None == 0

\* The PreToolUse hook's answer for a call: none, allow, ask, or deny.
HookAnswers == {"none", "allow", "ask", "deny"}

\* The sources of a run's permission decision. The first six allow the call.
\* full_access is the full-access mode, which the policy documents as bypassing
\* configured rules (AGENTS.md: "Full access bypasses fx permission policy").
Sources == {"full_access", "rule_allow", "grant", "hook_allow", "reviewer_allow", "prompt_yes",
            "rule_deny", "hook_deny", "reviewer_deny", "prompt_no"}
AllowSources == {"full_access", "rule_allow", "grant", "hook_allow", "reviewer_allow", "prompt_yes"}

\* The sources a call can get, given its hook answer, whether a configured deny
\* covers it, and whether the session is in full access. The order follows the
\* code: a hook deny is refused before admission (user_hooks.zig:707-719); full
\* access approves before the configured rules unless a hook asks
\* (tool_admission.zig:1574-1582); a configured deny refuses (:1594-1596); a hook
\* allow approves without the reviewer or the prompt (:1686-1692); a hook ask
\* prompts the person (:1635-1654). Configured asks and remembered session
\* approvals are not modeled.
Decide(hook, covered, full) ==
    IF hook = "deny" THEN {"hook_deny"}
    ELSE IF full /\ hook # "ask" THEN {"full_access"}
    ELSE IF Bug = "hook_overrides_deny" /\ hook = "allow" THEN {"hook_allow"}
    ELSE IF covered THEN {"rule_deny"}
    ELSE IF hook = "allow" THEN {"hook_allow"}
    ELSE IF hook = "ask" THEN {"prompt_yes", "prompt_no"}
    ELSE {"rule_allow", "grant", "reviewer_allow", "reviewer_deny", "prompt_yes", "prompt_no"}

VARIABLES
    tools,      \* the tools fx sends
    menu,       \* the menu fx sends
    conv,       \* the conversation, oldest first
    reqs,       \* every request fx sent, in order
    epoch,      \* compactions so far
    avail,      \* which entries the catalog can serve now
    executed,   \* how many times each run id reached the real tool
    admitted,   \* run ids whose permission check allowed them
    coveredRan, \* a call a configured deny covers has run without full access
    askFull,    \* a hook's ask was answered by full access
    pending,    \* the run id in flight, or None
    pendingTool,
    nextId,
    actions

vars == <<tools, menu, conv, reqs, epoch, avail, executed, admitted, coveredRan, askFull, pending, pendingTool, nextId, actions>>

TypeOK ==
    /\ epoch \in Nat
    /\ avail \in [Entries -> BOOLEAN]
    /\ executed \in [Ids -> Nat]
    /\ admitted \subseteq Ids
    /\ coveredRan \in BOOLEAN
    /\ askFull \in BOOLEAN
    /\ pending \in Ids \cup {None}
    /\ pendingTool \in Runnable \cup {"none"}
    /\ nextId \in 1..(MaxIds + 1)
    /\ actions \in 0..MaxActions

Init ==
    /\ tools = BaseTools
    /\ menu = InitMenu
    /\ conv = << [k |-> "user"] >>
    /\ reqs = << >>
    /\ epoch = 0
    /\ avail = [e \in Entries |-> TRUE]
    /\ executed = [i \in Ids |-> 0]
    /\ admitted = {}
    /\ coveredRan = FALSE
    /\ askFull = FALSE
    /\ pending = None
    /\ pendingTool = "none"
    /\ nextId = 1
    /\ actions = 0

Step == actions < MaxActions /\ actions' = actions + 1
Idle == pending = None

OpenedIn(e, c) == \E i \in DOMAIN c : c[i].k = "opened" /\ c[i].e = e

\* fx sends a request built from what it has now.
Send ==
    /\ Step /\ Idle
    /\ reqs' = Append(reqs, [tools |-> tools, menu |-> menu, conv |-> conv, epoch |-> epoch, avail |-> avail])
    /\ UNCHANGED <<tools, menu, conv, epoch, avail, executed, admitted, coveredRan, askFull, pending, pendingTool, nextId>>

\* toolbox {open: e}: the entry's text, or why it can't be opened, goes at
\* the end of the conversation.
Open(e) ==
    /\ Step /\ Idle
    /\ e \in menu
    /\ conv' = conv \o << [k |-> "open", e |-> e],
                         [k |-> IF avail[e] THEN "opened" ELSE "unavailable", e |-> e] >>
    /\ tools' = IF Bug = "append_tool" /\ e = "server" THEN Append(tools, "echo") ELSE tools
    /\ UNCHANGED <<menu, reqs, epoch, avail, executed, admitted, coveredRan, askFull, pending, pendingTool, nextId>>

\* toolbox {run: t}, or a call of t by its own name: both take this path.
\* hook is the PreToolUse answer, covered says a configured deny covers the call,
\* full says the session is in full access, and src is the decision (see Decide).
\* A call the hook denies is refused here as a source. It never reaches the tool
\* and is never admitted, the same as any other refusal. coveredRan and askFull
\* record what a run did, for the properties below.
Run(t, hook, covered, full, src) ==
    /\ Step /\ Idle
    /\ nextId <= MaxIds
    /\ LET id == nextId
           allowed == src \in AllowSources
           passes == allowed \/ Bug = "skip_admission"
           opened == Bug # "run_needs_open" \/ OpenedIn(Owner(t), conv)
           runs == passes /\ avail[Owner(t)] /\ opened
       IN /\ nextId' = nextId + 1
          /\ admitted' = IF allowed THEN admitted \cup {id} ELSE admitted
          /\ coveredRan' = (coveredRan \/ (runs /\ covered /\ src # "full_access"))
          /\ askFull' = (askFull \/ (runs /\ hook = "ask" /\ src = "full_access"))
          /\ executed' = IF runs THEN [executed EXCEPT ![id] = @ + 1] ELSE executed
          /\ pending' = IF runs THEN id ELSE None
          /\ pendingTool' = IF runs THEN t ELSE "none"
          \* A run that doesn't reach the tool is answered at once.
          /\ conv' = IF runs THEN conv
                     ELSE conv \o << [k |-> "run", t |-> t, id |-> id],
                                     [k |-> "result", id |-> id, ok |-> FALSE,
                                      allowed |-> allowed, avail |-> avail[Owner(t)]] >>
    /\ tools' = IF Bug = "append_tool" THEN Append(tools, t) ELSE tools
    /\ UNCHANGED <<menu, reqs, epoch, avail>>

\* The real tool answered, and fx saves the result.
Finish ==
    /\ pending # None
    /\ conv' = conv \o << [k |-> "run", t |-> pendingTool, id |-> pending],
                         [k |-> "result", id |-> pending, ok |-> TRUE, allowed |-> TRUE, avail |-> TRUE] >>
    /\ pending' = None
    /\ pendingTool' = "none"
    /\ UNCHANGED <<tools, menu, reqs, epoch, avail, executed, admitted, coveredRan, askFull, nextId, actions>>

\* fx dies while the real tool runs; the next process records the call as
\* interrupted and never runs it again.
CrashAndResume ==
    /\ pending # None
    /\ conv' = conv \o << [k |-> "run", t |-> pendingTool, id |-> pending],
                         [k |-> "interrupted", id |-> pending] >>
    /\ executed' = IF Bug = "rerun_after_crash" THEN [executed EXCEPT ![pending] = @ + 1] ELSE executed
    /\ menu' = IF Bug = "menu_from_live" THEN {e \in Entries : avail[e]} ELSE menu
    /\ pending' = None
    /\ pendingTool' = "none"
    /\ UNCHANGED <<tools, reqs, epoch, avail, admitted, coveredRan, askFull, nextId, actions>>

\* A resume with nothing in flight rebuilds the tools and the menu.
Resume ==
    /\ Step /\ Idle
    /\ menu' = IF Bug = "menu_from_live" THEN {e \in Entries : avail[e]} ELSE menu
    /\ UNCHANGED <<tools, conv, reqs, epoch, avail, executed, admitted, coveredRan, askFull, pending, pendingTool, nextId>>

\* A server or custom tool goes down or comes back. fx tells the model in a
\* note at the end of the conversation.
CatalogChange(e) ==
    /\ Step /\ Idle
    /\ avail' = [avail EXCEPT ![e] = ~@]
    /\ conv' = conv \o << [k |-> "note", e |-> e, up |-> ~avail[e]] >>
    /\ menu' = IF Bug = "live_menu"
                   THEN IF avail[e] THEN menu \ {e} ELSE menu \cup {e}
                   ELSE menu
    /\ UNCHANGED <<tools, reqs, epoch, executed, admitted, coveredRan, askFull, pending, pendingTool, nextId>>

\* Compaction replaces the conversation with a summary. The conversation
\* keeps its menu: compaction is not a new conversation. The notes went with
\* the turns, so when the catalog differs from the menu, the next request
\* notes what the toolbox holds now.
Compact ==
    /\ Step /\ Idle
    /\ menu' = IF Bug = "compact_resets_menu" THEN {e \in Entries : avail[e]} ELSE menu
    /\ conv' = << [k |-> "summary"] >> \o
                IF Bug = "compact_forgets_notes" \/ \A e \in Entries : avail[e] = (e \in menu')
                THEN << >>
                ELSE << [k |-> "state", up |-> avail] >>
    /\ epoch' = epoch + 1
    /\ UNCHANGED <<tools, reqs, avail, executed, admitted, coveredRan, askFull, pending, pendingTool, nextId>>

\* The run's bound is spent and nothing is in flight: the behavior ends.
Done ==
    /\ actions = MaxActions /\ Idle
    /\ UNCHANGED vars

Next ==
    \/ Send
    \/ \E e \in Entries : Open(e)
    \/ \E t \in Runnable, h \in HookAnswers, c \in BOOLEAN, f \in BOOLEAN :
           \E s \in Decide(h, c, f) : Run(t, h, c, f, s)
    \/ Finish
    \/ CrashAndResume
    \/ Resume
    \/ \E e \in Live : CatalogChange(e)
    \/ Compact
    \/ Done

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
IsPrefix(s, t) == Len(s) <= Len(t) /\ SubSeq(t, 1, Len(s)) = s

\* Every request sends the same tools: nothing is ever added to them.
ToolsFixed == \A i \in DOMAIN reqs : reqs[i].tools = BaseTools

\* Every request sends the same menu, whatever the catalog does.
MenuFixed == \A i \in DOMAIN reqs : reqs[i].menu = InitMenu

\* What request r tells the model about entry e: the newest note about it,
\* else whether the menu lists it.
Says(r, i, e) == (r.conv[i].k = "note" /\ r.conv[i].e = e) \/ r.conv[i].k = "state"
Believed(r, e) ==
    LET says == {i \in DOMAIN r.conv : Says(r, i, e)}
    IN IF says = {} THEN e \in r.menu
       ELSE LET last == CHOOSE i \in says : \A j \in says : j <= i
            IN IF r.conv[last].k = "note" THEN r.conv[last].up ELSE r.conv[last].up[e]

\* Every request tells the model what the catalog can serve when it is sent,
\* across compactions too.
Informed == \A i \in DOMAIN reqs : \A e \in Entries : Believed(reqs[i], e) = reqs[i].avail[e]

\* Between compactions, every request is the one before it plus new items at
\* the end, so the provider reads all of the earlier request from its cache.
PrefixStable ==
    \A i \in 1..(Len(reqs) - 1) :
        reqs[i].epoch = reqs[i + 1].epoch =>
            /\ reqs[i + 1].tools = reqs[i].tools
            /\ reqs[i + 1].menu = reqs[i].menu
            /\ IsPrefix(reqs[i].conv, reqs[i + 1].conv)

\* A run reaches the real tool only after its permission check allowed it.
RunNeedsAdmission == \A id \in Ids : executed[id] > 0 => id \in admitted

\* No call reaches the real tool twice, a crash included.
AtMostOnce == \A id \in Ids : executed[id] <= 1

\* A run that permission allows, of a tool the catalog can serve, succeeds,
\* whether or not anything was opened first, so compaction strands nothing.
RunWorksWhenAllowed ==
    \A i \in DOMAIN conv :
        (conv[i].k = "result" /\ conv[i].allowed /\ conv[i].avail) => conv[i].ok

\* A call that a configured deny covers never runs, unless the session is in
\* full access, which the policy documents as bypassing configured rules.
ConfiguredDenyWins == ~coveredRan

\* A hook's ask never reaches full access: the call falls through to the
\* configured rules and the prompt (tool_admission.zig:1574-1582).
HookAskNeverFullAccess == ~askFull

=============================================================================
