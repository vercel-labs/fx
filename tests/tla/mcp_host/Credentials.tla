---- MODULE Credentials ----
\* fx's MCP-v2 credential store (src/core/mcp_host/credentials.zig), file
\* backend (FX_DISABLE_KEYCHAIN=1; the Keychain backend reads and writes the
\* same document through native_keychain).
\*
\* One document, `~/.fx/mcp-credentials/credentials-v2.json`:
\*   {"version":1, "servers":[{name,url,credential}]}
\* Every operation holds the directory's advisory lock (Store.lock), so each
\* is atomic here, and reads the document first (Store.read): a missing file
\* is empty; one that doesn't parse, or whose version isn't 1, is unreadable,
\* and nothing writes over it: get finds no login, and put and remove
\* fail. A read writes nothing. v1's logins (mcp_auth_store.zig) are never
\* taken over: v1 and MCP-v2 refreshing one login apart, neither seeing
\* the other's saves, would sign it out.
\* Operations: get (config.resolve -> Runtime.savedCredential, for every
\* HTTP server, whenever a host starts: `fx mcp list`, `fx ask`, the shell),
\* put (a `credential` event after a sign-in or refresh), remove (logout:
\* runtime.zig `.logout`; verbs.zig remove and logout).
\*
\* Entries are names: each scenario gives each server one URL. An older fx's
\* `imported_v1` flag and `v1-imported` note are ignored.
EXTENDS Naturals, FiniteSets

CONSTANTS
    Names,         \* HTTP servers
    Faults,        \* environment faults allowed: SUBSET {"unreadable", "repair", "delete", "v1login"}
    InitKinds,     \* SUBSET {"absent", "ok", "unreadable"}
    InitEntries,   \* entries an initial document may hold
    InitV1         \* v1's logins at the start may be any subset of these

Kinds == {"absent", "ok", "unreadable"}

VARIABLES
    kind,        \* the document: missing, readable, or unreadable
    entries,     \* what it holds (an unreadable one still holds it, for a reader that can read it)
    v1,          \* v1's logins (mcp_auth_store.zig), never changed by MCP-v2
    loggedOut,   \* ghost: names signed out of and not signed in to since
    kept,        \* ghost: names signed in to and not signed out of since
    taken,       \* ghost: a write added a v1 login no sign-in here made
    overwritten  \* ghost: an unreadable document was written over

vars == <<kind, entries, v1, loggedOut, kept, taken, overwritten>>

TypeOK ==
    /\ kind \in Kinds
    /\ entries \subseteq Names
    /\ v1 \subseteq Names
    /\ loggedOut \subseteq Names
    /\ kept \subseteq Names
    /\ taken \in BOOLEAN /\ overwritten \in BOOLEAN

Init ==
    /\ kind \in InitKinds
    /\ entries \in (IF kind = "absent" THEN {{}} ELSE SUBSET InitEntries)
    /\ v1 \in SUBSET InitV1
    /\ loggedOut = {}
    /\ kept = entries
    /\ taken = FALSE /\ overwritten = FALSE

\* Store.read: what this fx reads.
Unread == kind = "unreadable"
SavedEntries == IF kind = "ok" THEN entries ELSE {}

\* Store.write of `e`; `fresh` is a name signed in to by this operation.
Write(e, fresh) ==
    /\ kind' = "ok"
    /\ entries' = e
    /\ taken' = (taken \/ ((e \ (SavedEntries \cup {fresh})) \cap v1) # {})
    /\ overwritten' = (overwritten \/ Unread)

Same == UNCHANGED <<kind, entries, taken, overwritten>>

\* Store.get, from config.resolve when a host starts. An unreadable document
\* gives no login and stays as it is.
Get ==
    /\ Same
    /\ UNCHANGED <<v1, loggedOut, kept>>

\* Store.put after a sign-in (or a refresh) of `n`. It fails on an
\* unreadable document, so the sign-in isn't saved.
Put(n) ==
    /\ ~Unread
    /\ Write(SavedEntries \cup {n}, n)
    /\ loggedOut' = loggedOut \ {n}
    /\ kept' = kept \cup {n}
    /\ UNCHANGED v1

\* Store.remove on logout of `n`: written when it had `n`. It fails on an
\* unreadable document, so `n` stays.
Remove(n) ==
    /\ ~Unread
    /\ IF n \in SavedEntries THEN Write(SavedEntries \ {n}, "") ELSE Same
    /\ loggedOut' = loggedOut \cup {n}
    /\ kept' = kept \ {n}
    /\ UNCHANGED v1

\* Environment: the document stops being readable by this fx (a newer fx
\* wrote another version, a hand edit, a damaged file); what it holds stays.
Unreadable ==
    /\ "unreadable" \in Faults /\ kind = "ok"
    /\ kind' = "unreadable"
    /\ UNCHANGED <<entries, v1, loggedOut, kept, taken, overwritten>>

\* Environment: it is readable again (fixed by hand, or saved as version 1
\* again), holding what it held.
Repair ==
    /\ "repair" \in Faults /\ kind = "unreadable"
    /\ kind' = "ok"
    /\ UNCHANGED <<entries, v1, loggedOut, kept, taken, overwritten>>

\* Environment: the user deletes the document, and with it what it kept.
Delete ==
    /\ "delete" \in Faults /\ kind # "absent"
    /\ kind' = "absent" /\ entries' = {}
    /\ kept' = {}
    /\ UNCHANGED <<v1, loggedOut, taken, overwritten>>

\* Environment: a sign-in with the v1 engine (FX_MCP_ENGINE unset).
V1Login(n) ==
    /\ "v1login" \in Faults /\ n \notin v1
    /\ v1' = v1 \cup {n}
    /\ UNCHANGED <<kind, entries, loggedOut, kept, taken, overwritten>>

Next ==
    \/ Get
    \/ \E n \in Names : Put(n) \/ Remove(n) \/ V1Login(n)
    \/ Unreadable
    \/ Repair
    \/ Delete

Spec == Init /\ [][Next]_vars

\* ---- Safety ----

\* MCP-v2 never takes a v1 login; each server signs in on its own.
NoV1LoginTaken == ~taken

\* What was signed in to, and not signed out of since, is kept.
SignedInKept == kind = "ok" => kept \subseteq entries

\* A login signed out of stays out of a readable document until the next
\* sign-in.
LogoutStays == kind = "ok" => loggedOut \cap entries = {}

\* An unreadable document is never written over.
UnreadableNeverOverwritten == ~overwritten
====
