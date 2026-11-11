---- MODULE ConfigEdit ----
\* How `fx mcp add` and `fx mcp remove` edit ~/.fx/mcp.json (the profile) and
\* a project's .mcp.json, and what fx's reader then loads from the result.
\*
\* Code:
\*   - src/core/mcp_host/config_file.zig update: under the profile lock, read
\*     the file, make the pure edit (`add`, `remove`), run the reader on the
\*     text it would write, and write only when the reader loads the new entry
\*     and the profile's servers key isn't misspelled. A refusal writes
\*     nothing. The existing refusals (a file that isn't JSON, both "mcp" and
\*     "mcpServers", a name that is already there) come first.
\*   - src/core/mcp/project_config.zig: the reader. An entry it skips is of a
\*     class below; a misspelled key is one `scanSuspiciousProfileKeys` finds.
\*     The scan the reader runs at load gives up on a big file (more than 64
\*     top-level keys, or 64 entries under one key); the scan an edit runs
\*     reads every key.
\*   - src/core/mcp_host/verbs.zig add, remove: print the refusal and exit 1.
\*
\* Entry classes. "ok" loads from either file. "bad" is skipped from either: a
\* URL that isn't https or loopback http with a port, a user name in the URL, a
\* reserved or duplicate header, a malformed ${ }. "auth" is an Authorization
\* header, which the profile skips and .mcp.json loads. An unset ${VAR} is not
\* a class: the reader holds that server back until the variable is set, and
\* add still saves it.
\*
\* The switches. Checked, KeyScan = "complete", GuardRemove and Atomic = TRUE
\* are that code. The code before it ran no reader check (Checked = FALSE) and
\* never read the profile's keys (KeyScan = "none"). "bounded" is the load
\* scan used for an edit, and Atomic = FALSE a dry run before `update`, which
\* reads the file outside the lock; both are designs the person ruled out.
EXTENDS Naturals, FiniteSets

CONSTANTS
    Names,        \* server names
    Classes,      \* the entry classes a command can save
    Checked,      \* BOOLEAN: add runs the reader on the new entry
    KeyScan,      \* "none", "bounded" or "complete": what the profile's keys are checked with
    GuardRemove,  \* BOOLEAN: remove checks the key too
    Atomic        \* BOOLEAN: the reader check and the write are one step under the lock

Files == {"profile", "project"}
NoEntry == "none"
Entries == Classes \cup {NoEntry}
FileStates == {"absent", "ok", "broken"}
NoPend == [none |-> TRUE]

VARIABLES
    st,         \* each file: "absent", "ok", or "broken" (not JSON, or repeats a key)
    typo,       \* the profile has a key that looks like a misspelled servers key, holding servers
    both,       \* the profile has both "mcp" and "mcpServers"
    big,        \* the profile is past the load scan's bound: over 64 top-level keys, or 64 entries under a key
    ent,        \* each file's servers: the entry's class, or NoEntry
    added,      \* ghost: the names an add saved to each file and nothing has changed since
    pend,       \* the dry-run design's verdict, between its check and its write
    last,       \* ghost: how the last step ended: "none", "added", "removed", "refused", "missing", "tamper"
    same,       \* ghost: the last step left the file's bytes as they were
    others,     \* ghost: the last step changed no entry but the one it named
    wroteTypo   \* ghost: an add or remove wrote a profile whose servers key was misspelled

vars == <<st, typo, both, big, ent, added, pend, last, same, others, wroteTypo>>

Loads(f, c) == c = "ok" \/ (c = "auth" /\ f = "project")

\* What `fx mcp list` shows from file f: nothing from a file the reader can't read.
LoadedNames(f) ==
    IF st[f] = "ok" THEN {n \in Names : ent[f][n] # NoEntry /\ Loads(f, ent[f][n])} ELSE {}

\* The edit finds the misspelled key.
KeyBlocks == typo /\ (KeyScan = "complete" \/ (KeyScan = "bounded" /\ ~big))

\* Refusals `update` already had, from the file as it is.
BaseRefused(f, n) == st[f] = "broken" \/ (f = "profile" /\ both) \/ ent[f][n] # NoEntry

\* Refusals the reader's check adds, from the file as it is.
ReaderRefused(f, c) == (Checked /\ ~Loads(f, c)) \/ (f = "profile" /\ KeyBlocks)

TypeOK ==
    /\ st \in [Files -> FileStates]
    /\ typo \in BOOLEAN
    /\ both \in BOOLEAN
    /\ big \in BOOLEAN
    /\ ent \in [Files -> [Names -> Entries]]
    /\ added \in [Files -> SUBSET Names]
    /\ pend = NoPend \/ pend \in [f : Files, n : Names, c : Classes, reader : BOOLEAN]
    /\ last \in {"none", "added", "removed", "refused", "missing", "tamper"}
    /\ same \in BOOLEAN
    /\ others \in BOOLEAN
    /\ wroteTypo \in BOOLEAN

\* Any starting files. A file that isn't "ok" holds no servers, and only an
\* "ok" profile has the keys the flags describe.
Init ==
    /\ st \in [Files -> FileStates]
    /\ ent \in [Files -> [Names -> Entries]]
    /\ typo \in BOOLEAN
    /\ both \in BOOLEAN
    /\ big \in BOOLEAN
    /\ \A f \in Files : st[f] # "ok" => \A n \in Names : ent[f][n] = NoEntry
    /\ st["profile"] # "ok" => ~typo /\ ~both /\ ~big
    /\ added = [f \in Files |-> {}]
    /\ pend = NoPend
    /\ last = "none"
    /\ same = TRUE
    /\ others = TRUE
    /\ wroteTypo = FALSE

\* The end of an add: refused, or written.
AddStep(f, n, c, refused) ==
    /\ IF refused
       THEN /\ UNCHANGED <<st, ent, added, wroteTypo>>
            /\ last' = "refused"
            /\ same' = TRUE
       ELSE /\ st' = [st EXCEPT ![f] = "ok"]
            /\ ent' = [ent EXCEPT ![f][n] = c]
            /\ added' = [added EXCEPT ![f] = added[f] \cup {n}]
            /\ wroteTypo' = (wroteTypo \/ (f = "profile" /\ typo))
            /\ last' = "added"
            /\ same' = FALSE
    /\ others' = \A m \in Names \ {n} : ent'[f][m] = ent[f][m]
    /\ UNCHANGED <<typo, both, big>>

\* `fx mcp add`: lock, read, edit, reader check, write, as one step.
Add(f, n, c) ==
    /\ Atomic
    /\ pend = NoPend
    /\ AddStep(f, n, c, BaseRefused(f, n) \/ ReaderRefused(f, c))
    /\ UNCHANGED pend

\* The dry-run design: the reader's check, read outside the lock, and then
\* `update`, which has only the refusals it always had.
AddCheck(f, n, c) ==
    /\ ~Atomic
    /\ pend = NoPend
    /\ pend' = [f |-> f, n |-> n, c |-> c, reader |-> ReaderRefused(f, c)]
    /\ UNCHANGED <<st, typo, both, big, ent, added, last, same, others, wroteTypo>>

AddCommit ==
    /\ ~Atomic
    /\ pend # NoPend
    /\ AddStep(pend.f, pend.n, pend.c, BaseRefused(pend.f, pend.n) \/ pend.reader)
    /\ pend' = NoPend

\* `fx mcp remove`: it finds the name by reading the file, and writes only
\* when the name is there. A file it can't read, or that has both "mcp" and
\* "mcpServers", holds no name it can find: it says "No MCP server named".
Remove(f, n) ==
    /\ pend = NoPend
    /\ IF st[f] # "ok" \/ ent[f][n] = NoEntry \/ (f = "profile" /\ both)
       THEN /\ last' = "missing"
            /\ same' = TRUE
            /\ others' = TRUE
            /\ UNCHANGED <<st, ent, added, wroteTypo>>
       ELSE IF f = "profile" /\ GuardRemove /\ KeyBlocks
            THEN /\ last' = "refused"
                 /\ same' = TRUE
                 /\ others' = TRUE
                 /\ UNCHANGED <<st, ent, added, wroteTypo>>
            ELSE /\ ent' = [ent EXCEPT ![f][n] = NoEntry]
                 /\ added' = [added EXCEPT ![f] = {m \in added[f] : ent'[f][m] # NoEntry}]
                 /\ wroteTypo' = (wroteTypo \/ (f = "profile" /\ typo))
                 /\ last' = "removed"
                 /\ same' = FALSE
                 /\ others' = \A m \in Names \ {n} : ent'[f][m] = ent[f][m]
                 /\ UNCHANGED st
    /\ UNCHANGED <<typo, both, big, pend>>

\* Something that doesn't take the lock changes a file between fx's commands:
\* a person's editor, a script, a git checkout.
Edited(f) ==
    /\ added' = [added EXCEPT ![f] = {}]
    /\ last' = "tamper"
    /\ same' = TRUE
    /\ others' = TRUE

TypoAppears ==
    /\ st["profile"] = "ok"
    /\ ~typo
    /\ typo' = TRUE
    /\ Edited("profile")
    /\ UNCHANGED <<st, both, big, ent, pend, wroteTypo>>

TypoFixed ==
    /\ typo
    /\ typo' = FALSE
    /\ Edited("profile")
    /\ UNCHANGED <<st, both, big, ent, pend, wroteTypo>>

Grows ==
    /\ st["profile"] = "ok"
    /\ ~big
    /\ big' = TRUE
    /\ Edited("profile")
    /\ UNCHANGED <<st, typo, both, ent, pend, wroteTypo>>

BothAppear ==
    /\ st["profile"] = "ok"
    /\ ~both
    /\ both' = TRUE
    /\ Edited("profile")
    /\ UNCHANGED <<st, typo, big, ent, pend, wroteTypo>>

BothMerged ==
    /\ both
    /\ both' = FALSE
    /\ Edited("profile")
    /\ UNCHANGED <<st, typo, big, ent, pend, wroteTypo>>

\* A hand-written entry, of any class, in a file that is readable or missing.
HandEntry(f, n, c) ==
    /\ st[f] \in {"absent", "ok"}
    /\ st' = [st EXCEPT ![f] = "ok"]
    /\ ent' = [ent EXCEPT ![f][n] = c]
    /\ Edited(f)
    /\ UNCHANGED <<typo, both, big, pend, wroteTypo>>

\* The file stops being JSON, is repaired to an empty one, or is deleted.
Breaks(f) ==
    /\ st[f] # "broken"
    /\ st' = [st EXCEPT ![f] = "broken"]
    /\ ent' = [ent EXCEPT ![f] = [n \in Names |-> NoEntry]]
    /\ typo' = IF f = "profile" THEN FALSE ELSE typo
    /\ both' = IF f = "profile" THEN FALSE ELSE both
    /\ big' = IF f = "profile" THEN FALSE ELSE big
    /\ Edited(f)
    /\ UNCHANGED <<pend, wroteTypo>>

Repairs(f) ==
    /\ st[f] = "broken"
    /\ st' = [st EXCEPT ![f] = "ok"]
    /\ Edited(f)
    /\ UNCHANGED <<typo, both, big, ent, pend, wroteTypo>>

Deletes(f) ==
    /\ st[f] # "absent"
    /\ st' = [st EXCEPT ![f] = "absent"]
    /\ ent' = [ent EXCEPT ![f] = [n \in Names |-> NoEntry]]
    /\ typo' = IF f = "profile" THEN FALSE ELSE typo
    /\ both' = IF f = "profile" THEN FALSE ELSE both
    /\ big' = IF f = "profile" THEN FALSE ELSE big
    /\ Edited(f)
    /\ UNCHANGED <<pend, wroteTypo>>

Next ==
    \/ \E f \in Files, n \in Names, c \in Classes : Add(f, n, c) \/ AddCheck(f, n, c)
    \/ AddCommit
    \/ \E f \in Files, n \in Names : Remove(f, n)
    \/ TypoAppears \/ TypoFixed \/ Grows \/ BothAppear \/ BothMerged
    \/ \E f \in Files, n \in Names, c \in Classes : HandEntry(f, n, c)
    \/ \E f \in Files : Breaks(f) \/ Repairs(f) \/ Deletes(f)

Spec == Init /\ [][Next]_vars

\* An add that succeeded is followed by a load that holds the entry: fx never
\* says "Added" for a server it then skips.
AddedIsLoaded == \A f \in Files : \A n \in added[f] : n \in LoadedNames(f)

\* A command that refuses leaves the file's bytes as they were.
RefusedLeavesFile == last = "refused" => same

\* No add or remove writes a profile whose servers key looks misspelled, whatever
\* the file's size.
NoRewriteOfMisspelled == ~wroteTypo

\* An add or remove changes only the entry it names.
OthersKept == last \in {"added", "removed"} => others
====
