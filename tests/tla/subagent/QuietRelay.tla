------------------------------ MODULE QuietRelay ------------------------------
(***************************************************************************)
(* A subagent's quiet shell command, relayed to its parent.                *)
(*                                                                         *)
(* A shell wait that ends at the quiet crossing (fix 1: quiet_notice.zig,  *)
(* tests/tla/managed_execution/QuietWait.tla) carries the crossing on its  *)
(* result. fx then posts one note from that subagent to its parent's       *)
(* mailbox (noteChildQuiet in src/core/subagent/tool_host.zig, raised by   *)
(* agent_adapter.zig for fx ask and ACP, and by app_worker_runtime.zig for *)
(* the interactive app), and the note wakes the parent's subagent wait     *)
(* (waitForMail).                                                          *)
(*                                                                         *)
(* A quiet spell is the time from a command's latest output until its next *)
(* output. Each spell crosses at most once; output starts the next spell.  *)
(* A later wait in the same spell gets the notice again, without a         *)
(* crossing, and is never relayed. The relay runs after the result exists:  *)
(* it checks that the subagent is still open, then posts, so a close can   *)
(* come before the check, which drops the note, or between the check and  *)
(* the post, which the post does not see; the host holds no lock across   *)
(* the post (the app's sink takes its own). A note the full mailbox       *)
(* refuses is dropped. Each drop writes a debug_trace line.               *)
(*                                                                         *)
(* The parent's wait registers as the waiter first, then checks the        *)
(* mailbox, then blocks; a post or a close wakes a registered waiter.      *)
(*                                                                         *)
(* Bug plants one defect; check.sh names the rule that must catch it:      *)
(*   relay_late_notice  a later notice in the same spell is relayed        *)
(*   relay_after_close  the relay skips its check of a closed subagent     *)
(*   silent_drop        a note the full mailbox refuses is not logged      *)
(*   no_cap             a note is posted past the mailbox bound            *)
(*   check_first        the wait checks the mailbox before it registers    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Children, MaxSpells, Cap, Bug

Bugs == {"none", "relay_late_notice", "relay_after_close", "silent_drop", "no_cap", "check_first"}
ASSUME Bug \in Bugs
\* The trace configs use fx's own queue bound, 64 (agent_frame.queue_cap).
ASSUME MaxSpells \in 1..4 /\ Cap \in 1..64

Spells == 1..MaxSpells

VARIABLES
    open,       \* [Children -> BOOLEAN]: not closed
    spell,      \* [Children -> Spells]: the command's current quiet spell
    crossed,    \* [Children -> BOOLEAN]: the current spell has crossed
    pending,    \* [Children -> 0..MaxSpells]: a result whose note is not yet posted, by spell; 0 none
    checked,    \* [Children -> BOOLEAN]: the pending note passed its check
    checkedOpen, \* [Children -> BOOLEAN]: the check saw the subagent open
    crossings,  \* [Children -> SUBSET Spells]: the spells that crossed
    relays,     \* [Children -> [Spells -> 0..3]]: notes posted, by spell
    logged,     \* [Children -> SUBSET Spells]: spells whose note was dropped with a log line
    lost,       \* [Children -> SUBSET Spells]: spells whose note was dropped with no log line
    postedClosed, \* a note was posted whose check saw its subagent closed
    mailbox,    \* Seq of [from |-> c, spell |-> s]: notes the parent has not read
    parent      \* "busy", "registered", "checked", "blocked", "woken"

vars == <<open, spell, crossed, pending, checked, checkedOpen, crossings, relays, logged, lost, postedClosed, mailbox, parent>>

Note == [from: Children, spell: Spells]

TypeOK ==
    /\ open \in [Children -> BOOLEAN]
    /\ spell \in [Children -> Spells]
    /\ crossed \in [Children -> BOOLEAN]
    /\ pending \in [Children -> 0..MaxSpells]
    /\ checked \in [Children -> BOOLEAN]
    /\ checkedOpen \in [Children -> BOOLEAN]
    /\ crossings \in [Children -> SUBSET Spells]
    /\ relays \in [Children -> [Spells -> 0..3]]
    /\ logged \in [Children -> SUBSET Spells]
    /\ lost \in [Children -> SUBSET Spells]
    /\ postedClosed \in BOOLEAN
    /\ mailbox \in Seq(Note)
    /\ parent \in {"busy", "registered", "checked", "blocked", "woken"}

Init ==
    /\ open = [c \in Children |-> TRUE]
    /\ spell = [c \in Children |-> 1]
    /\ crossed = [c \in Children |-> FALSE]
    /\ pending = [c \in Children |-> 0]
    /\ checked = [c \in Children |-> FALSE]
    /\ checkedOpen = [c \in Children |-> FALSE]
    /\ crossings = [c \in Children |-> {}]
    /\ relays = [c \in Children |-> [s \in Spells |-> 0]]
    /\ logged = [c \in Children |-> {}]
    /\ lost = [c \in Children |-> {}]
    /\ postedClosed = FALSE
    /\ mailbox = <<>>
    /\ parent = "busy"

AnyOpen == \E c \in Children : open[c]

\* The parent's state after a post or a close: a registered or blocked
\* waiter wakes. A waiter that only checked, without registering, does not.
Woken(p) == IF p \in {"registered", "blocked"} THEN "woken" ELSE p

-----------------------------------------------------------------------------
\* The subagent's command.

\* A wait ends at the crossing; its result carries the crossing.
Cross(c) ==
    /\ open[c]
    /\ ~crossed[c]
    /\ pending[c] = 0
    /\ crossed' = [crossed EXCEPT ![c] = TRUE]
    /\ crossings' = [crossings EXCEPT ![c] = @ \cup {spell[c]}]
    /\ pending' = [pending EXCEPT ![c] = spell[c]]
    /\ UNCHANGED <<checked, checkedOpen, open, spell, relays, logged, lost, postedClosed, mailbox, parent>>

\* A later wait in the same spell gets the notice again. Only the planted
\* bug makes a note of it.
LateNotice(c) ==
    /\ Bug = "relay_late_notice"
    /\ open[c]
    /\ crossed[c]
    /\ pending[c] = 0
    /\ relays[c][spell[c]] < 3
    /\ pending' = [pending EXCEPT ![c] = spell[c]]
    /\ UNCHANGED <<checked, checkedOpen, open, spell, crossed, crossings, relays, logged, lost, postedClosed, mailbox, parent>>

\* Output ends the spell; the next one can cross again.
Output(c) ==
    /\ open[c]
    /\ spell[c] < MaxSpells
    /\ spell' = [spell EXCEPT ![c] = @ + 1]
    /\ crossed' = [crossed EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<checked, checkedOpen, open, pending, crossings, relays, logged, lost, postedClosed, mailbox, parent>>

\* fx's check of a crossing result: a closed subagent's note is dropped.
RelayCheck(c) ==
    /\ pending[c] # 0
    /\ ~checked[c]
    /\ IF ~open[c] /\ Bug # "relay_after_close"
       THEN /\ logged' = [logged EXCEPT ![c] = @ \cup {pending[c]}]
            /\ pending' = [pending EXCEPT ![c] = 0]
            /\ UNCHANGED <<checked, checkedOpen>>
       ELSE /\ checked' = [checked EXCEPT ![c] = TRUE]
            /\ checkedOpen' = [checkedOpen EXCEPT ![c] = open[c]]
            /\ UNCHANGED <<logged, pending>>
    /\ UNCHANGED <<open, spell, crossed, crossings, relays, lost, postedClosed, mailbox, parent>>

\* fx posts the checked note, or drops it when the mailbox is full.
RelayPost(c) ==
    LET s == pending[c]
        fullDrop == Len(mailbox) >= Cap /\ Bug # "no_cap"
    IN
    /\ s # 0
    /\ checked[c]
    /\ pending' = [pending EXCEPT ![c] = 0]
    /\ checked' = [checked EXCEPT ![c] = FALSE]
    /\ IF fullDrop
       THEN /\ IF Bug = "silent_drop"
               THEN /\ lost' = [lost EXCEPT ![c] = @ \cup {s}]
                    /\ UNCHANGED logged
               ELSE /\ logged' = [logged EXCEPT ![c] = @ \cup {s}]
                    /\ UNCHANGED lost
            /\ UNCHANGED <<relays, postedClosed, mailbox, parent>>
       ELSE /\ mailbox' = Append(mailbox, [from |-> c, spell |-> s])
            /\ relays' = [relays EXCEPT ![c][s] = @ + 1]
            /\ postedClosed' = (postedClosed \/ ~checkedOpen[c])
            /\ parent' = Woken(parent)
            /\ UNCHANGED <<logged, lost>>
    /\ UNCHANGED <<open, spell, crossed, crossings, checkedOpen>>

\* Main closes the subagent. A crossing result may still wait for its relay.
\* The child's work ends, which wakes a registered waiter.
Close(c) ==
    /\ open[c]
    /\ open' = [open EXCEPT ![c] = FALSE]
    /\ parent' = Woken(parent)
    /\ UNCHANGED <<checked, checkedOpen, spell, crossed, pending, crossings, relays, logged, lost, postedClosed, mailbox>>

-----------------------------------------------------------------------------
\* The parent.

\* setWaiter, then the check, then the block (waitForMail).
Register ==
    /\ parent = "busy"
    /\ Bug # "check_first"
    /\ parent' = "registered"
    /\ UNCHANGED <<checked, checkedOpen, open, spell, crossed, pending, crossings, relays, logged, lost, postedClosed, mailbox>>

Check ==
    /\ parent = "registered"
    /\ parent' = IF Len(mailbox) > 0 \/ ~AnyOpen THEN "woken" ELSE "blocked"
    /\ UNCHANGED <<checked, checkedOpen, open, spell, crossed, pending, crossings, relays, logged, lost, postedClosed, mailbox>>

\* The planted bug: check first, register and block after.
CheckFirst ==
    /\ Bug = "check_first"
    /\ parent = "busy"
    /\ parent' = IF Len(mailbox) > 0 \/ ~AnyOpen THEN "woken" ELSE "checked"
    /\ UNCHANGED <<checked, checkedOpen, open, spell, crossed, pending, crossings, relays, logged, lost, postedClosed, mailbox>>

BlockLate ==
    /\ parent = "checked"
    /\ parent' = "blocked"
    /\ UNCHANGED <<checked, checkedOpen, open, spell, crossed, pending, crossings, relays, logged, lost, postedClosed, mailbox>>

\* The woken wait returns, and the parent's next step reads the mail.
Read ==
    /\ parent = "woken"
    /\ parent' = "busy"
    /\ mailbox' = <<>>
    /\ UNCHANGED <<checked, checkedOpen, open, spell, crossed, pending, crossings, relays, logged, lost, postedClosed>>

\* A busy parent reads waiting mail at its next step.
ReadBusy ==
    /\ parent = "busy"
    /\ Len(mailbox) > 0
    /\ mailbox' = <<>>
    /\ UNCHANGED <<checked, checkedOpen, open, spell, crossed, pending, crossings, relays, logged, lost, postedClosed, parent>>

Next ==
    \/ \E c \in Children : Cross(c) \/ LateNotice(c) \/ Output(c) \/ RelayCheck(c) \/ RelayPost(c) \/ Close(c)
    \/ Register \/ Check \/ CheckFirst \/ BlockLate \/ Read \/ ReadBusy

Fairness ==
    /\ \A c \in Children : WF_vars(RelayCheck(c)) /\ WF_vars(RelayPost(c))
    /\ WF_vars(Check)
    /\ WF_vars(BlockLate)
    /\ WF_vars(Read)
    /\ WF_vars(ReadBusy)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Rules.

\* One note per quiet spell, at most.
OnePerSpell == \A c \in Children : \A s \in Spells : relays[c][s] <= 1

\* A note only for a spell that crossed.
OnlyCrossings == \A c \in Children : \A s \in Spells : relays[c][s] > 0 => s \in crossings[c]

\* Every posted note was checked while its subagent was open. A close
\* between the check and the post still lets that one note through.
NoRelayAfterClose == ~postedClosed

\* Every crossing is relayed, still on its way, or dropped with a log line.
EveryCrossingAccounted ==
    \A c \in Children : \A s \in crossings[c] :
        relays[c][s] > 0 \/ s \in logged[c] \/ pending[c] = s

\* The mailbox holds no more than its bound.
MailboxBounded == Len(mailbox) <= Cap

\* A blocked wait never sleeps on mail it could read.
NoSleepOnMail == parent = "blocked" => Len(mailbox) = 0

\* A blocked wait always has a subagent that can still wake it.
BlockedOnlyWhileOpen == parent = "blocked" => AnyOpen

\* Every note the parent gets is read.
MailRead == Len(mailbox) > 0 ~> Len(mailbox) = 0
=============================================================================
