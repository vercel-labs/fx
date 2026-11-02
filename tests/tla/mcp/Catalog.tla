---- MODULE Catalog ----
\* U05 tool catalog, client side, one server. Rules: CAT-01..CAT-05, CAT-11,
\* MRTR-07.
\*
\* The host needs the server's tool list (a model turn is starting). A fresh
\* cached list is served at once. Otherwise one listing runs, page by page,
\* and everyone who needed the list meanwhile gets its result. The list is
\* cached as one unit: it is fresh only if no invalidation happened
\* since the listing started, and, on a modern server, if no page had a
\* zero TTL. A modern list also goes stale when its TTL runs out. A legacy
\* list stays fresh until an invalidation or a new process.
\*
\* Each modern page is fresh for its own TTL from its own arrival, so a page
\* whose TTL runs out before the listing ends leaves the list stale at once
\*.
\*
\* Pages are bounded: a listing stops after MaxPages pages, and an
\* invalid cursor restarts it from the beginning once. Failed listings never
\* touch the cache, and their waiters get the last list listed, if
\* there is one, still stale, so the next need lists again. Tool
\* contents (validity, duplicate names) are data, checked by the Zig tests,
\* not here.
EXTENDS Naturals

CONSTANTS
    MaxPages,      \* pages per listing (100 in fx)
    MaxGen,        \* invalidations, bounds the state space
    MaxProcesses

ASSUME MaxPages \in Nat \ {0} /\ MaxGen \in Nat /\ MaxProcesses \in Nat \ {0}

VARIABLES
    era,           \* the current process's era: "none" before the first, "modern", "legacy"
    process,       \* the server process generation
    gen,           \* invalidation generation (list_changed, call errors, new process)
    cache,         \* the current list: "none", "fresh", or "stale"
    cacheGen,      \* the generation the current list was listed under
    cachedZero,    \* the current list had a page with a zero TTL
    cachedLapsed,  \* a page of the current list had expired when it was listed
    listing,       \* "idle" or "fetching"
    startGen,      \* gen when the running listing started (or restarted)
    page,          \* pages received in the running listing
    restarts,      \* restarts of the running listing after an invalid cursor
    zeroTtl,       \* a page of the running listing had a zero TTL
    lapsed,        \* a page of the running listing has expired
    pending,       \* the page request in flight: "none", "first", or "next"
    waiting,       \* someone is waiting for the running listing
    answer,        \* what the last listing to end gave its waiters: "none"
                   \* yet, a "list", the "lastGood" list after a failure, or
                   \* a "failure"
    \* Ghost variables for the safety properties.
    servedStale,   \* a need was served from a list that wasn't fresh and current
    extraFetch     \* a listing started while one was running

vars == <<era, process, gen, cache, cacheGen, cachedZero, cachedLapsed, listing,
          startGen, page, restarts, zeroTtl, lapsed, pending, waiting, answer,
          servedStale, extraFetch>>

listingVars == <<listing, startGen, page, restarts, zeroTtl, lapsed, pending, waiting, answer>>

Init ==
    /\ era = "none"
    /\ process = 0
    /\ gen = 0
    /\ cache = "none"
    /\ cacheGen = 0
    /\ cachedZero = FALSE
    /\ cachedLapsed = FALSE
    /\ listing = "idle"
    /\ startGen = 0
    /\ page = 0
    /\ restarts = 0
    /\ zeroTtl = FALSE
    /\ lapsed = FALSE
    /\ pending = "none"
    /\ waiting = FALSE
    /\ answer = "none"
    /\ servedStale = FALSE
    /\ extraFetch = FALSE

\* Mark the current list stale and move to a new generation.
Invalidated ==
    /\ gen' = gen + 1
    /\ cache' = IF cache = "fresh" THEN "stale" ELSE cache

\* Environment: a server process starts, after era detection (U04). The
\* previous process's requests already ended as lost (U03), so no listing
\* is running. A new process may be a new server version.
ProcessStarted(e) ==
    /\ process < MaxProcesses
    /\ gen < MaxGen
    /\ listing = "idle"
    /\ process' = process + 1
    /\ era' = e
    /\ Invalidated
    /\ UNCHANGED <<cacheGen, cachedZero, cachedLapsed, listingVars, servedStale, extraFetch>>

StartListing ==
    /\ listing' = "fetching"
    /\ startGen' = gen
    /\ page' = 0
    /\ restarts' = 0
    /\ zeroTtl' = FALSE
    /\ lapsed' = FALSE
    /\ pending' = "first"
    /\ waiting' = TRUE
    /\ UNCHANGED answer

\* The host needs the tool list.
Need ==
    /\ era # "none"
    /\ IF listing = "fetching"
          THEN /\ waiting' = TRUE
               /\ UNCHANGED <<listing, startGen, page, restarts, zeroTtl, lapsed, pending, answer, servedStale, extraFetch>>
       ELSE IF cache = "fresh"
          THEN /\ servedStale' = (servedStale \/ cacheGen # gen)
               /\ UNCHANGED <<listingVars, extraFetch>>
       ELSE /\ StartListing
            /\ extraFetch' = (extraFetch \/ listing = "fetching")
            /\ UNCHANGED servedStale
    /\ UNCHANGED <<era, process, gen, cache, cacheGen, cachedZero, cachedLapsed>>

\* The listing ends with a list, delivered to everyone waiting. It is cached
\* as fresh only if nothing was invalidated since it started and, on a
\* modern server, no page had a zero TTL (CAT-04) and none has expired
\*.
Finish(z, l) ==
    /\ listing' = "idle"
    /\ pending' = "none"
    /\ waiting' = FALSE
    /\ answer' = "list"
    /\ cache' = IF startGen = gen /\ (era = "legacy" \/ (~z /\ ~l)) THEN "fresh" ELSE "stale"
    /\ cacheGen' = startGen
    /\ cachedZero' = z
    /\ cachedLapsed' = l
    /\ UNCHANGED <<startGen, restarts>>

\* A complete page. `more`: it has a nextCursor (an empty string is a
\* cursor, CAT-01). `ttlZero`: its ttlMs is 0, absent, or negative (CAT-04).
\* `lapse`: on a modern server, an earlier page of this listing has expired
\* by the time this one arrives. Legacy pages have no TTL.
PageReceived(more, ttlZero, lapse) ==
    /\ pending # "none"
    /\ lapse => (era = "modern" /\ page > 0)
    /\ LET p == page + 1
           z == zeroTtl \/ ttlZero
           l == lapsed \/ lapse
       IN IF more /\ p < MaxPages
             THEN /\ page' = p /\ zeroTtl' = z /\ lapsed' = l /\ pending' = "next"
                  /\ UNCHANGED <<listing, startGen, restarts, waiting, answer, cache, cacheGen,
                                 cachedZero, cachedLapsed>>
          ELSE /\ page' = p /\ zeroTtl' = z /\ lapsed' = l
               /\ Finish(z, l)
    /\ UNCHANGED <<era, process, gen, servedStale, extraFetch>>

\* The listing failed: everyone waiting gets the last list listed, if there
\* is one, or the failure. The cache is untouched, so a stale list
\* stays stale and the next need lists again.
Failed ==
    /\ listing' = "idle"
    /\ pending' = "none"
    /\ waiting' = FALSE
    /\ answer' = IF cache = "none" THEN "failure" ELSE "lastGood"

\* -32602 for a continuation page: drop the pages so far and list again from
\* the beginning, once (CAT-02).
InvalidCursor ==
    /\ pending = "next"
    /\ IF restarts = 0
          THEN /\ restarts' = 1
               /\ startGen' = gen
               /\ page' = 0
               /\ zeroTtl' = FALSE
               /\ lapsed' = FALSE
               /\ pending' = "first"
               /\ UNCHANGED <<listing, waiting, answer>>
          ELSE /\ Failed
               /\ UNCHANGED <<startGen, page, restarts, zeroTtl, lapsed>>
    /\ UNCHANGED <<era, process, gen, cache, cacheGen, cachedZero, cachedLapsed, servedStale, extraFetch>>

\* Any other end of a page request: an error (including -32602 on the first
\* page), input_required (MRTR-07: never cached), a malformed result, a
\* timeout, or a lost connection. The listing fails: an answer that failed
\* is never cached, and its waiters may get the last list.
PageFailed ==
    /\ pending # "none"
    /\ Failed
    /\ UNCHANGED <<era, process, gen, cache, cacheGen, cachedZero, cachedLapsed, startGen,
                   page, restarts, zeroTtl, lapsed, servedStale, extraFetch>>

\* list_changed, a tools/call answered -32601 or -32602, or the
\* host. The list goes stale at once (CAT-05).
Invalidate ==
    /\ gen < MaxGen
    /\ Invalidated
    /\ UNCHANGED <<era, process, cacheGen, cachedZero, cachedLapsed, listingVars, servedStale, extraFetch>>

\* A modern list's TTL ran out (CAT-04). Legacy lists have no TTL.
Expired ==
    /\ cache = "fresh"
    /\ era = "modern"
    /\ cache' = "stale"
    /\ UNCHANGED <<era, process, gen, cacheGen, cachedZero, cachedLapsed, listingVars, servedStale, extraFetch>>

Answer == (\E m, z, l \in BOOLEAN : PageReceived(m, z, l)) \/ InvalidCursor \/ PageFailed

Next ==
    \/ \E e \in {"modern", "legacy"} : ProcessStarted(e)
    \/ Need
    \/ Answer
    \/ Invalidate
    \/ Expired

\* Every page request ends (U02 EveryRequestEnds), so the server's answers are
\* weakly fair.
Spec == Init /\ [][Next]_vars /\ WF_vars(Answer)

TypeOK ==
    /\ era \in {"none", "modern", "legacy"}
    /\ process \in 0..MaxProcesses
    /\ gen \in 0..MaxGen
    /\ cache \in {"none", "fresh", "stale"}
    /\ cacheGen \in 0..MaxGen
    /\ cachedZero \in BOOLEAN
    /\ cachedLapsed \in BOOLEAN
    /\ listing \in {"idle", "fetching"}
    /\ startGen \in 0..MaxGen
    /\ page \in 0..MaxPages
    /\ restarts \in 0..1
    /\ zeroTtl \in BOOLEAN
    /\ lapsed \in BOOLEAN
    /\ pending \in {"none", "first", "next"}
    /\ waiting \in BOOLEAN
    /\ answer \in {"none", "list", "lastGood", "failure"}
    /\ servedStale \in BOOLEAN
    /\ extraFetch \in BOOLEAN

\* A fresh list was listed in the current generation: no answer from before
\* an invalidation is ever cached as fresh.
CacheCurrent == cache = "fresh" => cacheGen = gen

\* A need is served from the cache only when the list is fresh and current.
NoStaleServe == ~servedStale

\* On a modern server, a list with a zero-TTL page is never cached (CAT-04).
ZeroTtlNotCached == (cache = "fresh" /\ era = "modern") => ~cachedZero

\* On a modern server, a list with a page that expired before the listing
\* ended is never cached.
LapsedNotCached == (cache = "fresh" /\ era = "modern") => ~cachedLapsed

\* A failed listing hands its waiters the failure only when no list was ever
\* listed: otherwise they get the last one.
LastGoodOnFailure == answer = "failure" => cache = "none"

\* The last list handed over after a failure is still stale, so the next need
\* lists again instead of being served it from the cache.
FallbackRetries == (answer = "lastGood" /\ listing = "idle") => cache = "stale"

\* At most one listing at a time; later needs join it.
OneListing == ~extraFetch

\* A listing never asks for more than MaxPages pages.
PagesBounded == page <= MaxPages /\ (pending # "none" => page < MaxPages)

\* A listing runs only while someone waits for it, and waiting implies a listing.
WaitingMeansListing == waiting <=> listing = "fetching"

\* Everyone who needs the list gets an answer.
EveryNeedAnswered == waiting ~> ~waiting
====
