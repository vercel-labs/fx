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
\*     "mcpServers", a name that is already there) come first, and so does one
\*     for a file nested past `json_depth.max_depth`: the edit writes the whole
\*     file back, and the JSON writer aborts well before the depth a file can
\*     reach, so fx never renders such a file. The reader has no such limit.
\*   - src/core/mcp/project_config.zig: the reader. An entry it skips is of a
\*     class below; a misspelled key is one `scanSuspiciousProfileKeys` finds.
\*     The scan the reader runs at load gives up on a big file (more than 64
\*     top-level keys, or 64 entries under one key); the scan an edit runs
\*     reads every key.
\*   - src/core/mcp_host/verbs.zig add, remove: print the refusal and exit 1. A remove that
\*     finds no entry exits 1 with "No MCP server named ..." and leaves the file as it was; when
\*     the profile's misspelled servers key holds a server by that name, it adds one line that
\*     names the key and the fix ("hinted"). It reads the key with the scan an edit runs, which
\*     reads every key, and writes nothing.
\*
\* File states. "ok" is JSON the reader loads, "deep" is the same nested past
\* the limit an edit writes back, and "broken" is not JSON, or repeats a key.
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
\* reads the file outside the lock. fx uses neither design: the load scan gives up
\* on a big file, and a dry run misses a key that another fx adds before the write.
EXTENDS Naturals, FiniteSets

CONSTANTS
    Names,        \* server names
    Classes,      \* the entry classes a command can save
    Checked,      \* BOOLEAN: add runs the reader on the new entry
    KeyScan,      \* "none", "bounded" or "complete": what the profile's keys are checked with
    GuardRemove,  \* BOOLEAN: remove checks the key too
    Atomic        \* BOOLEAN: the reader check and the write are one step under the lock

Files == {"profile", "project"}
\* What the profile's misspelled servers key holds: no such key, a server that is not one of Names, or the
\* server of that name.
NoTypo == "no-typo"
OtherTypo == "other"
HeldValues == Names \cup {NoTypo, OtherTypo}
NoEntry == "none"
Entries == Classes \cup {NoEntry}
FileStates == {"absent", "ok", "deep", "broken"}
NoPend == [none |-> TRUE]

VARIABLES
    st,         \* each file: "absent", "ok", "deep" (readable, nested past the edit's limit), or "broken" (not JSON, or repeats a key)
    held,       \* the profile's key that looks like a misspelled servers key: what it holds (HeldValues)
    both,       \* the profile has both "mcp" and "mcpServers"
    big,        \* the profile is past the load scan's bound: over 64 top-level keys, or 64 entries under a key
    ent,        \* each file's servers: the entry's class, or NoEntry
    added,      \* ghost: the names an add saved to each file and nothing has changed since
    pend,       \* the dry-run design's verdict, between its check and its write
    last,       \* ghost: how the last step ended: "none", "added", "removed", "refused", "missing", "tamper"
    same,       \* ghost: the last step left the file's bytes as they were
    others,     \* ghost: the last step changed no entry but the one it named
    wroteTypo,  \* ghost: an add or remove wrote a profile whose servers key was misspelled
    wroteDeep,  \* ghost: an add or remove rendered a file nested past the limit, where the JSON writer aborts
    heldHit     \* ghost: the last remove that found no entry was for a name the misspelled key holds

vars == <<st, held, both, big, ent, added, pend, last, same, others, wroteTypo, wroteDeep, heldHit>>

\* The profile has a key that looks like a misspelled servers key, holding servers.
typo == held # NoTypo

Loads(f, c) == c = "ok" \/ (c = "auth" /\ f = "project")

\* What `fx mcp list` shows from file f: nothing from a file the reader can't read.
LoadedNames(f) ==
    IF st[f] \in {"ok", "deep"} THEN {n \in Names : ent[f][n] # NoEntry /\ Loads(f, ent[f][n])} ELSE {}

\* The edit finds the misspelled key.
KeyBlocks == typo /\ (KeyScan = "complete" \/ (KeyScan = "bounded" /\ ~big))

\* Refusals `update` already had, from the file as it is.
BaseRefused(f, n) == st[f] \in {"broken", "deep"} \/ (f = "profile" /\ both) \/ ent[f][n] # NoEntry

\* Refusals the reader's check adds, from the file as it is.
ReaderRefused(f, c) == (Checked /\ ~Loads(f, c)) \/ (f = "profile" /\ KeyBlocks)

TypeOK ==
    /\ st \in [Files -> FileStates]
    /\ held \in HeldValues
    /\ both \in BOOLEAN
    /\ big \in BOOLEAN
    /\ ent \in [Files -> [Names -> Entries]]
    /\ added \in [Files -> SUBSET Names]
    /\ pend = NoPend \/ pend \in [f : Files, n : Names, c : Classes, reader : BOOLEAN]
    /\ last \in {"none", "added", "removed", "refused", "missing", "hinted", "tamper"}
    /\ same \in BOOLEAN
    /\ others \in BOOLEAN
    /\ wroteTypo \in BOOLEAN
    /\ wroteDeep \in BOOLEAN
    /\ heldHit \in BOOLEAN

\* Any starting files. A file that isn't readable holds no servers, and only a
\* readable profile has the keys the flags describe.
Init ==
    /\ st \in [Files -> FileStates]
    /\ ent \in [Files -> [Names -> Entries]]
    /\ held \in HeldValues
    /\ both \in BOOLEAN
    /\ big \in BOOLEAN
    /\ \A f \in Files : st[f] \notin {"ok", "deep"} => \A n \in Names : ent[f][n] = NoEntry
    /\ st["profile"] \notin {"ok", "deep"} => ~typo /\ ~both /\ ~big
    /\ added = [f \in Files |-> {}]
    /\ pend = NoPend
    /\ last = "none"
    /\ same = TRUE
    /\ others = TRUE
    /\ wroteTypo = FALSE
    /\ wroteDeep = FALSE
    /\ heldHit = FALSE

\* The end of an add: refused, or written.
AddStep(f, n, c, refused) ==
    /\ IF refused
       THEN /\ UNCHANGED <<st, ent, added, wroteTypo, wroteDeep>>
            /\ last' = "refused"
            /\ same' = TRUE
       ELSE /\ st' = [st EXCEPT ![f] = "ok"]
            /\ ent' = [ent EXCEPT ![f][n] = c]
            /\ added' = [added EXCEPT ![f] = added[f] \cup {n}]
            /\ wroteTypo' = (wroteTypo \/ (f = "profile" /\ typo))
            /\ wroteDeep' = (wroteDeep \/ st[f] = "deep")
            /\ last' = "added"
            /\ same' = FALSE
    /\ others' = \A m \in Names \ {n} : ent'[f][m] = ent[f][m]
    /\ UNCHANGED <<held, both, big, heldHit>>

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
    /\ UNCHANGED <<st, held, both, big, ent, added, last, same, others, wroteTypo, wroteDeep, heldHit>>

AddCommit ==
    /\ ~Atomic
    /\ pend # NoPend
    /\ AddStep(pend.f, pend.n, pend.c, BaseRefused(pend.f, pend.n) \/ pend.reader)
    /\ pend' = NoPend

\* The profile's misspelled key holds a server by the name `n`. A remove that finds no entry in `f` says so
\* with one more line, and only then.
HintFor(f, n) == f = "profile" /\ held = n

\* `fx mcp remove`: it finds the name by reading the file, and writes only
\* when the name is there. A file it can't read, or that has both "mcp" and
\* "mcpServers", holds no name it can find: it says "No MCP server named",
\* and, when the profile's misspelled key holds that name, where it is. A
\* deep file is read like any other, so it does hold the name, and the edit
\* refuses it.
Remove(f, n) ==
    /\ pend = NoPend
    /\ IF st[f] \notin {"ok", "deep"} \/ ent[f][n] = NoEntry \/ (f = "profile" /\ both)
       THEN /\ last' = IF HintFor(f, n) THEN "hinted" ELSE "missing"
            /\ heldHit' = HintFor(f, n)
            /\ same' = TRUE
            /\ others' = TRUE
            /\ UNCHANGED <<st, ent, added, wroteTypo, wroteDeep>>
       ELSE IF st[f] = "deep"
            THEN /\ last' = "refused"
                 /\ same' = TRUE
                 /\ others' = TRUE
                 /\ UNCHANGED <<heldHit>>
                 /\ UNCHANGED <<st, ent, added, wroteTypo, wroteDeep>>
       ELSE IF f = "profile" /\ GuardRemove /\ KeyBlocks
            THEN /\ last' = "refused"
                 /\ same' = TRUE
                 /\ others' = TRUE
                 /\ UNCHANGED <<heldHit>>
                 /\ UNCHANGED <<st, ent, added, wroteTypo, wroteDeep>>
            ELSE /\ ent' = [ent EXCEPT ![f][n] = NoEntry]
                 /\ added' = [added EXCEPT ![f] = {m \in added[f] : ent'[f][m] # NoEntry}]
                 /\ wroteTypo' = (wroteTypo \/ (f = "profile" /\ typo))
                 /\ wroteDeep' = (wroteDeep \/ st[f] = "deep")
                 /\ last' = "removed"
                 /\ same' = FALSE
                 /\ others' = \A m \in Names \ {n} : ent'[f][m] = ent[f][m]
                 /\ UNCHANGED <<st, heldHit>>
    /\ UNCHANGED <<held, both, big, pend>>

\* Something that doesn't take the lock changes a file between fx's commands:
\* a person's editor, a script, a git checkout.
Edited(f) ==
    /\ added' = [added EXCEPT ![f] = {}]
    /\ last' = "tamper"
    /\ same' = TRUE
    /\ others' = TRUE

TypoAppears(h) ==
    /\ st["profile"] = "ok"
    /\ ~typo
    /\ h # NoTypo
    /\ held' = h
    /\ Edited("profile")
    /\ UNCHANGED <<st, both, big, ent, pend, wroteTypo, wroteDeep, heldHit>>

TypoFixed ==
    /\ typo
    /\ held' = NoTypo
    /\ Edited("profile")
    /\ UNCHANGED <<st, both, big, ent, pend, wroteTypo, wroteDeep, heldHit>>

Grows ==
    /\ st["profile"] = "ok"
    /\ ~big
    /\ big' = TRUE
    /\ Edited("profile")
    /\ UNCHANGED <<st, held, both, ent, pend, wroteTypo, wroteDeep, heldHit>>

BothAppear ==
    /\ st["profile"] = "ok"
    /\ ~both
    /\ both' = TRUE
    /\ Edited("profile")
    /\ UNCHANGED <<st, held, big, ent, pend, wroteTypo, wroteDeep, heldHit>>

BothMerged ==
    /\ both
    /\ both' = FALSE
    /\ Edited("profile")
    /\ UNCHANGED <<st, held, big, ent, pend, wroteTypo, wroteDeep, heldHit>>

\* A hand-written entry, of any class, in a file that is readable or missing.
HandEntry(f, n, c) ==
    /\ st[f] \in {"absent", "ok"}
    /\ st' = [st EXCEPT ![f] = "ok"]
    /\ ent' = [ent EXCEPT ![f][n] = c]
    /\ Edited(f)
    /\ UNCHANGED <<held, both, big, pend, wroteTypo, wroteDeep, heldHit>>

\* A person's editor nests a readable file past the limit an edit writes back, or flattens it again.
Deepens(f) ==
    /\ st[f] = "ok"
    /\ st' = [st EXCEPT ![f] = "deep"]
    /\ Edited(f)
    /\ UNCHANGED <<held, both, big, ent, pend, wroteTypo, wroteDeep, heldHit>>

Flattens(f) ==
    /\ st[f] = "deep"
    /\ st' = [st EXCEPT ![f] = "ok"]
    /\ Edited(f)
    /\ UNCHANGED <<held, both, big, ent, pend, wroteTypo, wroteDeep, heldHit>>

\* The file stops being JSON, is repaired to an empty one, or is deleted.
Breaks(f) ==
    /\ st[f] # "broken"
    /\ st' = [st EXCEPT ![f] = "broken"]
    /\ ent' = [ent EXCEPT ![f] = [n \in Names |-> NoEntry]]
    /\ held' = IF f = "profile" THEN NoTypo ELSE held
    /\ both' = IF f = "profile" THEN FALSE ELSE both
    /\ big' = IF f = "profile" THEN FALSE ELSE big
    /\ Edited(f)
    /\ UNCHANGED <<pend, wroteTypo, wroteDeep, heldHit>>

Repairs(f) ==
    /\ st[f] = "broken"
    /\ st' = [st EXCEPT ![f] = "ok"]
    /\ Edited(f)
    /\ UNCHANGED <<held, both, big, ent, pend, wroteTypo, wroteDeep, heldHit>>

Deletes(f) ==
    /\ st[f] # "absent"
    /\ st' = [st EXCEPT ![f] = "absent"]
    /\ ent' = [ent EXCEPT ![f] = [n \in Names |-> NoEntry]]
    /\ held' = IF f = "profile" THEN NoTypo ELSE held
    /\ both' = IF f = "profile" THEN FALSE ELSE both
    /\ big' = IF f = "profile" THEN FALSE ELSE big
    /\ Edited(f)
    /\ UNCHANGED <<pend, wroteTypo, wroteDeep, heldHit>>

Next ==
    \/ \E f \in Files, n \in Names, c \in Classes : Add(f, n, c) \/ AddCheck(f, n, c)
    \/ AddCommit
    \/ \E f \in Files, n \in Names : Remove(f, n)
    \/ (\E h \in HeldValues \ {NoTypo} : TypoAppears(h)) \/ TypoFixed \/ Grows \/ BothAppear \/ BothMerged
    \/ \E f \in Files, n \in Names, c \in Classes : HandEntry(f, n, c)
    \/ \E f \in Files : Deepens(f) \/ Flattens(f)
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

\* No add or remove renders a file nested past the limit: the JSON writer aborts there, so fx would
\* crash on a file that a cloned repository can supply. `src/core/mcp_host/config_file.zig` `requireShallow`.
NoWriteOfDeep == ~wroteDeep

\* A remove that finds no entry says where the name is when the profile's misspelled key holds a server by
\* that name, and says nothing more when it does not.
HintMatchesHeldName == last \in {"missing", "hinted"} => ((last = "hinted") <=> heldHit)

\* An add or remove changes only the entry it names.
OthersKept == last \in {"added", "removed"} => others
====
