--------------------------- MODULE ClipboardTraces ---------------------------
(***************************************************************************)
(* Sample runs for TraceClipboardRead, which check.sh requires to be       *)
(* accepted or rejected. The driver writes its own ClipboardTraces.tla,    *)
(* with DriverTrace, next to a copy of the specs for each run it checks.   *)
(***************************************************************************)

\* Ctrl+V, typing while osascript runs, a refused second Ctrl+V, the image.
ImageTrace == <<
    [name |-> "Press", key |-> "paste"], [name |-> "Paste", seen |-> "reading"],
    [name |-> "Press", key |-> "text"], [name |-> "Read"],
    [name |-> "Press", key |-> "paste"], [name |-> "Paste", seen |-> "busy"],
    [name |-> "ChildExits", result |-> "image"], [name |-> "Collect", seen |-> "inserted"]
>>

\* A hung osascript stops at the deadline, and the next paste reads again.
TimeoutTrace == <<
    [name |-> "Press", key |-> "paste"], [name |-> "Paste", seen |-> "reading"],
    [name |-> "TimeOut"], [name |-> "Collect", seen |-> "timed_out"],
    [name |-> "Press", key |-> "paste"], [name |-> "Paste", seen |-> "reading"],
    [name |-> "ChildExits", result |-> "no_image"], [name |-> "Collect", seen |-> "no_image"]
>>

\* /quit during a read: osascript is killed, then fx exits.
QuitTrace == <<
    [name |-> "Press", key |-> "paste"], [name |-> "Paste", seen |-> "reading"],
    [name |-> "Press", key |-> "quit"], [name |-> "Quit"],
    [name |-> "CancelKill"], [name |-> "Exit"]
>>

\* fx before this change: a paste shows nothing while osascript runs.
SilentPasteTrace == <<
    [name |-> "Press", key |-> "paste"], [name |-> "Paste", seen |-> "none"]
>>

\* fx before this change: a key typed while osascript runs is not read.
StalledTrace == <<
    [name |-> "Press", key |-> "paste"], [name |-> "Paste", seen |-> "reading"],
    [name |-> "Press", key |-> "text"], [name |-> "Stalled"]
>>
=============================================================================
