---- MODULE MixedBuilds ----
\* fx processes running an older build beside this one, sharing one profile
\* and one MCP server's login (src/core/mcp_host/credentials.zig, the store's
\* location; runtime.zig restoreCredentials, tryRefresh and saveCredential).
\*
\* Two documents can hold the login:
\*   v2  `credentials-v2.json`, Keychain item FX_MCP_OAUTH_CREDENTIALS_V2. An
\*       older build reads and writes it. Builds from before version 2 of the
\*       document read only version 1: a version-2 document reads as empty,
\*       so their next write replaces it with version 1 and their own login.
\*   v3  `credentials-v3.json`, FX_MCP_OAUTH_CREDENTIALS_V3, which only this
\*       build opens.
\* `Loc` is where this build keeps its logins and `Copy` whether it carries
\* the v2 login over; the code has Loc = "v3" and Copy = FALSE.
\*
\* A login is a token chain: "old", which an older build signed in to before
\* the update, and "new", which this build signs in to. Each holder keeps the
\* copy of the chain's tokens it last had: the older processes (one side, as
\* they never read the store again after they start), this build's
\* processes, and each document. A refresh token works once (Plain, WorkOS;
\* RFC 9700 4.14.2): a refresh rotates the chain, so every other copy is
\* retired, and a retired one sent again is refused; with RevokeOnReplay that
\* ends the chain. Under the refresh lock this build takes a newer saved copy
\* in place of refreshing (tryRefresh), and a refused copy is removed only if
\* the document still holds it (removeIfSame). An older build refreshes from
\* memory and, refused, removes the login whatever the document holds.
EXTENDS Naturals

CONSTANTS RevokeOnReplay

Loc == "v3"
Copy == FALSE

Chains == {"old", "new"}
None == "none"
Holders == {"older", "this", "v2", "v3"}

VARIABLES
    v2kind,   \* the v2 document: "absent", "v1" or "v2"
    v2,       \* the chain the v2 document holds, or None
    v3,       \* the chain the v3 document holds, or None
    older,    \* the chain the older build's processes hold, or None
    this,     \* the chain this build's processes hold, or None
    current,  \* [Chains -> the holders whose copy is the chain's latest]
    rotated,  \* [Chains -> the side that last refreshed the chain, or None]
    alive,    \* the chains the server still takes
    \* Ghosts.
    erased,   \* an older build's write removed a login this build saved
    ended,    \* an older build's refresh ended the login this build holds
    taken     \* this build took the older build's login

vars == <<v2kind, v2, v3, older, this, current, rotated, alive, erased, ended, taken>>

TypeOK ==
    /\ v2kind \in {"absent", "v1", "v2"}
    /\ v2 \in Chains \cup {None} /\ v3 \in Chains \cup {None}
    /\ older \in Chains \cup {None} /\ this \in Chains \cup {None}
    /\ current \in [Chains -> SUBSET Holders]
    /\ rotated \in [Chains -> {"older", "this", None}]
    /\ alive \subseteq Chains
    /\ erased \in BOOLEAN /\ ended \in BOOLEAN /\ taken \in BOOLEAN

Init ==
    \* An older build signed in and saved the login as version 1.
    /\ v2kind = "v1" /\ v2 = "old"
    /\ v3 = IF Copy THEN "old" ELSE None
    /\ older = "old" /\ this = None
    /\ current = [c \in Chains |-> IF c = "old" THEN {"older", "v2"} \cup (IF Copy THEN {"v3"} ELSE {}) ELSE {}]
    /\ rotated = [c \in Chains |-> None]
    /\ alive = {"old"}
    /\ erased = FALSE /\ ended = FALSE /\ taken = FALSE

\* The document this build reads and writes, and what it holds.
Doc == IF Loc = "v3" THEN v3 ELSE v2

\* This build's write of `c`, None to remove; a v2 one is saved as version 2.
ThisWrite(c) ==
    IF Loc = "v3"
    THEN /\ v3' = c /\ UNCHANGED <<v2kind, v2>>
    ELSE /\ v2' = c /\ v2kind' = "v2" /\ UNCHANGED v3

\* An older build's write of `c`, None to remove: a version-2 document reads
\* as empty, so whatever it held goes, and it is version 1 again.
OlderWrite(c) ==
    /\ v2' = c /\ v2kind' = "v1"
    /\ erased' = (erased \/ (v2 = "new" /\ c # "new"))
    /\ UNCHANGED v3

\* A host of this build starts, or picks up a saved login: it reads its
\* document.
ThisGet ==
    /\ Loc = "v3" \/ v2kind # "absent"
    /\ this' = Doc
    /\ current' = IF Doc # None /\ Loc \in current[Doc]
                  THEN [current EXCEPT ![Doc] = @ \cup {"this"}] ELSE current
    /\ taken' = (taken \/ Doc = "old")
    /\ UNCHANGED <<v2kind, v2, v3, older, rotated, alive, erased, ended>>

\* This build signs in: a new chain, saved.
ThisSignIn ==
    /\ this' = "new"
    /\ alive' = alive \cup {"new"}
    /\ current' = [current EXCEPT !["new"] = {"this", Loc}]
    /\ rotated' = [rotated EXCEPT !["new"] = None]
    /\ ThisWrite("new")
    /\ UNCHANGED <<older, erased, ended, taken>>

\* This build signs out: the login is forgotten, and maybe revoked.
ThisLogout ==
    /\ this # None
    /\ \E gone \in {alive, alive \ {this}} : alive' = gone
    /\ this' = None
    /\ ThisWrite(None)
    /\ UNCHANGED <<older, current, rotated, erased, ended, taken>>

\* The server rotates chain `c` for side `s`, which saves its new copy in `doc`.
Rotate(s, c, doc) ==
    /\ current' = [current EXCEPT ![c] = {s, doc}]
    /\ rotated' = [rotated EXCEPT ![c] = s]

\* This build's refresh, under the login's refresh lock.
ThisRefresh ==
    LET c == this IN
    /\ c # None
    /\ IF c \in alive /\ "this" \in current[c]
       THEN /\ Rotate("this", c, Loc)
            /\ ThisWrite(c)
            /\ UNCHANGED <<older, this, alive, erased, ended, taken>>
       ELSE IF c \in alive /\ Doc = c /\ Loc \in current[c]
       \* A newer copy saved since: taken in place of a refresh.
       THEN /\ current' = [current EXCEPT ![c] = @ \cup {"this"}]
            /\ UNCHANGED <<v2kind, v2, v3, older, this, rotated, alive, erased, ended, taken>>
       \* Refused: the tokens go; the document's copy goes only if it is
       \* the one refused.
       ELSE /\ this' = None
            /\ ended' = (ended \/ (c \in alive /\ rotated[c] = "older"))
            /\ alive' = IF RevokeOnReplay /\ c \in alive THEN alive \ {c} ELSE alive
            /\ IF Doc = c /\ Loc \notin current[c] THEN ThisWrite(None) ELSE UNCHANGED <<v2kind, v2, v3>>
            /\ UNCHANGED <<older, current, rotated, erased, taken>>

\* The older build's login ends, refused or for its own reasons, and it
\* removes the login from v2 whatever v2 holds. With RevokeOnReplay a
\* retired copy sent again ends the chain for everyone holding it.
OlderEnds ==
    /\ older # None
    /\ older' = None
    /\ LET revoke == RevokeOnReplay /\ older \in alive /\ "older" \notin current[older] IN
       /\ alive' = IF revoke THEN alive \ {older} ELSE alive
       /\ ended' = (ended \/ (revoke /\ this = older))
    /\ OlderWrite(None)
    /\ UNCHANGED <<this, current, rotated, taken>>

\* The older build's refresh, from memory, never looking at the store.
OlderRefresh ==
    LET c == older IN
    /\ c # None
    /\ IF c \in alive /\ "older" \in current[c]
       THEN /\ Rotate("older", c, "v2")
            /\ OlderWrite(c)
            /\ UNCHANGED <<older, this, alive, ended, taken>>
       ELSE OlderEnds

\* The server stops taking a chain: it ran out, or was revoked elsewhere.
Expire ==
    \E c \in alive :
        /\ alive' = alive \ {c}
        /\ UNCHANGED <<v2kind, v2, v3, older, this, current, rotated, erased, ended, taken>>

Next ==
    \/ ThisGet \/ ThisSignIn \/ ThisLogout \/ ThisRefresh
    \/ OlderRefresh \/ OlderEnds \/ Expire

Spec == Init /\ [][Next]_vars

\* An older build never erases a login this build saved.
NoLoginErasedByOlder == ~erased

\* An older build's refreshes never end the login this build holds.
NoLoginEndedByOlder == ~ended

\* This build never holds the login an older build signed in to, whose tokens
\* that build keeps refreshing apart.
OlderLoginNotTaken == ~taken
====
