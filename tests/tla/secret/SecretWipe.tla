----------------------------- MODULE SecretWipe -----------------------------
(***************************************************************************)
(* How fx hands memory that held a secret back to the allocator under it  *)
(* (`src/core/auth/secret.zig` Wiping, its callers in `src/core/auth/`,   *)
(* and the API key copy in `src/napi_core_main.zig`).                     *)
(*                                                                         *)
(* A secret is an access or refresh token, a device code, an              *)
(* authorization code, a PKCE verifier, or an API key. fx holds one in    *)
(* blocks of six kinds:                                                    *)
(*                                                                         *)
(*   parse   a node of the arena std.json fills when it parses a reply or *)
(*           an auth file into std.json.Value. The arena gives every node *)
(*           back with rawFree when the parse is freed.                    *)
(*   writer  the buffer of a std.Io.Writer.Allocating that builds a       *)
(*           request body or a saved session, or of an ArrayList that     *)
(*           reads an auth file. It grows by remap, or by alloc, copy,    *)
(*           and free; toOwnedSlice shrinks it to its length and hands it *)
(*           out; deinit gives it back with rawFree, also on an error.    *)
(*   reply   the stdout buffer std.process.run fills when fx reads a     *)
(*           saved login back from the macOS Keychain                     *)
(*           (`src/core/hosts/native_keychain.zig` loadFromChild and      *)
(*           runMcpKeychainChild). It grows as the child's reply arrives, *)
(*           by remap or by alloc, copy, and free; toOwnedSlice shrinks   *)
(*           it to the reply and hands the result out as an answer; a    *)
(*           failed or cancelled run gives it back with rawFree.          *)
(*   copy    a token fx owns, such as one duped out of a reply or a       *)
(*           writer's result, released with secret.zeroAndFree.           *)
(*   answer  the reply a Keychain read returns, released with             *)
(*           secret.zeroAndFree by its caller.                            *)
(*   napi    the API key libfx copies out of JavaScript, released when    *)
(*           its runtime is destroyed or fails to construct.               *)
(*                                                                         *)
(* Under fx is libc: free takes a block back as it is, and a realloc that *)
(* moves a block takes the old one back as it is. `leaks` counts the      *)
(* blocks libc got back with secret bytes in them, by how; `held` counts  *)
(* the blocks that held a secret when fx gave them back.                  *)
(*                                                                         *)
(* Policy "wiping" is the design. Every parse, writer, and Keychain reply *)
(* that may hold a secret allocates through secret.Wiping, whose free     *)
(* wipes the block before it delegates, and whose remap and resize        *)
(* succeed only for growth in place, so a move or a shrink is an alloc,   *)
(* a copy, and a wiped free. The API key is released with zeroAndFree.     *)
(* NoSecretReleased must hold.                                             *)
(*                                                                         *)
(* Policy "head" is the design before the Keychain read joined it: every  *)
(* parse and writer is wrapped, and the Keychain reply keeps the caller's *)
(* allocator, so a realloc that moves it gives the old block back as it   *)
(* is.                                                                     *)
(*                                                                         *)
(* Policy "today" is fx before secret.Wiping: parses, writers, and        *)
(* replies use the caller's allocator, so rawFree and realloc give        *)
(* secrets back as they are, and the API key is released with a plain     *)
(* free. Each "mutation-*" policy plants one defect in the design;        *)
(* check.sh lists them.                                                    *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    Blocks,     \* heap blocks a run may use, such as {1, 2}
    Policy,     \* "wiping", "head", "today", or one of the mutations below
    MaxEvents   \* bound on the blocks given back, so TLC finishes

Policies == {
    "wiping", "head", "today",
    "mutation-free-no-wipe",      \* Wiping.free delegates without wiping
    "mutation-remap-moves",       \* Wiping.remap lets libc's realloc move a block
    "mutation-shrink-keeps-tail", \* Wiping.resize lets a block shrink in place
    "mutation-parse-unwrapped",   \* a parse keeps the caller's allocator
    "mutation-writer-unwrapped",  \* a writer keeps the caller's allocator
    "mutation-reply-plain-free",  \* a Keychain reply is wrapped, but its answer is freed plainly
    "mutation-napi-plain-free"    \* the API key is released with a plain free
}

ASSUME Policy \in Policies

WrapParse == Policy \notin {"today", "mutation-parse-unwrapped"}
WrapWriter == Policy \notin {"today", "mutation-writer-unwrapped"}
WrapReply == Policy \notin {"today", "head"}
WipeOnFree == Policy # "mutation-free-no-wipe"
InPlaceOnly == Policy # "mutation-remap-moves"
WipeTailOnShrink == Policy # "mutation-shrink-keeps-tail"
ZeroAnswer == Policy # "mutation-reply-plain-free"
ZeroNapiKey == Policy \notin {"today", "mutation-napi-plain-free"}

Kinds == {"parse", "writer", "reply", "copy", "answer", "napi"}
\* The kinds of block that grow, shrink, and give back as a buffer.
Buffers == {"writer", "reply"}
Ways == {"free", "move"}

VARIABLES
    owner,   \* [Blocks -> {"libc"} \cup Kinds]: who holds each block
    wrapped, \* [Blocks -> BOOLEAN]: the block came through secret.Wiping
    body,    \* [Blocks -> BOOLEAN]: secret bytes within the block's length
    tail,    \* [Blocks -> BOOLEAN]: secret bytes past its length
    held,    \* blocks given back that held a secret, wiped or not
    leaks    \* [Ways -> Nat]: blocks libc got back holding a secret

vars == <<owner, wrapped, body, tail, held, leaks>>

TypeOK ==
    /\ owner \in [Blocks -> {"libc"} \cup Kinds]
    /\ wrapped \in [Blocks -> BOOLEAN]
    /\ body \in [Blocks -> BOOLEAN]
    /\ tail \in [Blocks -> BOOLEAN]
    /\ held \in Nat
    /\ leaks \in [Ways -> Nat]

Init ==
    /\ owner = [b \in Blocks |-> "libc"]
    /\ wrapped = [b \in Blocks |-> FALSE]
    /\ body = [b \in Blocks |-> FALSE]
    /\ tail = [b \in Blocks |-> FALSE]
    /\ held = 0
    /\ leaks = [w \in Ways |-> 0]

Holds(b) == body[b] \/ tail[b]

\* fx gives block b back to libc `way`, and libc sees a secret in it when
\* `seen` holds.
GiveBack(b, way, seen) ==
    /\ owner' = [owner EXCEPT ![b] = "libc"]
    /\ wrapped' = [wrapped EXCEPT ![b] = FALSE]
    /\ body' = [body EXCEPT ![b] = FALSE]
    /\ tail' = [tail EXCEPT ![b] = FALSE]
    /\ held' = IF Holds(b) THEN held + 1 ELSE held
    /\ leaks' = IF seen THEN [leaks EXCEPT ![way] = @ + 1] ELSE leaks

\* A free through the allocator the block came from: secret.Wiping wipes
\* the whole block first, the caller's allocator does not.
Free(b) == GiveBack(b, "free", Holds(b) /\ ~(wrapped[b] /\ WipeOnFree))

Take(b, kind, wrap, secret) ==
    /\ owner[b] = "libc"
    /\ owner' = [owner EXCEPT ![b] = kind]
    /\ wrapped' = [wrapped EXCEPT ![b] = wrap]
    /\ body' = [body EXCEPT ![b] = secret]
    /\ UNCHANGED <<tail, held, leaks>>

-----------------------------------------------------------------------------
\* std.json parses a reply or an auth file: each node it fills holds a copy
\* of every string, the secrets included.
ParseNode(b) == Take(b, "parse", WrapParse, TRUE)

\* parsed.deinit(): the arena gives each node back with rawFree.
ParseFree(b) ==
    /\ owner[b] = "parse"
    /\ Free(b)

\* A writer starts empty, then writes a secret into its buffer.
WriterOpen(b) == Take(b, "writer", WrapWriter, FALSE)

\* std.process.run reads a Keychain child's stdout into a buffer that starts
\* empty and takes the secret as the child prints it.
ReplyOpen(b) == Take(b, "reply", WrapReply, FALSE)

BufferWrite(b) ==
    /\ owner[b] \in Buffers
    /\ body' = [body EXCEPT ![b] = TRUE]
    /\ UNCHANGED <<owner, wrapped, tail, held, leaks>>

\* The writer rewinds over bytes it wrote, as
\* Writer.Allocating.shrinkRetainingCapacity can, so they sit past its length.
WriterRewind(b) ==
    /\ owner[b] = "writer"
    /\ body[b]
    /\ tail' = [tail EXCEPT ![b] = TRUE]
    /\ UNCHANGED <<owner, wrapped, body, held, leaks>>

\* The buffer outgrows its block, and its bytes move to block c. Through
\* secret.Wiping a remap stays in place, so this never happens there.
\* Otherwise remap reaches libc's realloc, which moves the bytes and takes
\* the old block back as it is.
BufferGrowByRealloc(b, c) ==
    /\ owner[b] \in Buffers
    /\ owner[c] = "libc"
    /\ ~(wrapped[b] /\ InPlaceOnly)
    /\ owner' = [owner EXCEPT ![b] = "libc", ![c] = owner[b]]
    /\ wrapped' = [wrapped EXCEPT ![b] = FALSE, ![c] = wrapped[b]]
    /\ body' = [body EXCEPT ![b] = FALSE, ![c] = body[b]]
    /\ tail' = [tail EXCEPT ![b] = FALSE, ![c] = tail[b]]
    /\ held' = IF Holds(b) THEN held + 1 ELSE held
    /\ leaks' = IF Holds(b) THEN [leaks EXCEPT !["move"] = @ + 1] ELSE leaks

\* Allocating.ensureTotalCapacityPrecise when remap fails: a new block, a
\* copy of the written bytes, and a free of the old one.
BufferGrowByCopy(b, c) ==
    /\ owner[b] \in Buffers
    /\ owner[c] = "libc"
    /\ owner' = [owner EXCEPT ![b] = "libc", ![c] = owner[b]]
    /\ wrapped' = [wrapped EXCEPT ![b] = FALSE, ![c] = wrapped[b]]
    /\ body' = [body EXCEPT ![b] = FALSE, ![c] = body[b]]
    /\ tail' = [tail EXCEPT ![b] = FALSE, ![c] = FALSE]
    /\ held' = IF Holds(b) THEN held + 1 ELSE held
    /\ leaks' = IF Holds(b) /\ ~(wrapped[b] /\ WipeOnFree)
                THEN [leaks EXCEPT !["free"] = @ + 1] ELSE leaks

\* toOwnedSlice shrinks the block to the written length and hands it to the
\* caller. secret.Wiping refuses the shrink, so the kept bytes are copied
\* into a block of their own and the old one is wiped and freed: nothing is
\* left past the length. A writer's result is a copy; a Keychain reply's is
\* an answer.
BufferTake(b) ==
    /\ owner[b] \in Buffers
    /\ owner' = [owner EXCEPT ![b] = IF owner[b] = "reply" THEN "answer" ELSE "copy"]
    /\ tail' = IF wrapped[b] /\ WipeTailOnShrink THEN [tail EXCEPT ![b] = FALSE] ELSE tail
    /\ UNCHANGED <<wrapped, body, held, leaks>>

\* deinit, from a defer or from an errdefer when a write fails, or when a
\* Keychain read ends in an error or is cancelled.
BufferDeinit(b) ==
    /\ owner[b] \in Buffers
    /\ Free(b)

\* The caller of a Keychain read releases its answer with secret.zeroAndFree,
\* which overwrites the slice, so only bytes past its length can reach libc.
\* mutation-reply-plain-free releases it with a plain free.
AnswerRelease(b) ==
    /\ owner[b] = "answer"
    /\ GiveBack(b, "free", IF ZeroAnswer THEN tail[b] ELSE Holds(b))

\* A token fx owns, duped out of a reply.
CopyOwn(b) == Take(b, "copy", FALSE, TRUE)

\* secret.zeroAndFree overwrites the slice, then frees the block: only bytes
\* past the slice's length can reach libc.
CopyRelease(b) ==
    /\ owner[b] = "copy"
    /\ GiveBack(b, "free", tail[b])

\* libfx copies the API key out of JavaScript for a runtime.
NapiCopy(b) == Take(b, "napi", FALSE, TRUE)

\* Runtime.deinit, or createRuntime's errdefer when a later step fails.
NapiRelease(b) ==
    /\ owner[b] = "napi"
    /\ GiveBack(b, "free", Holds(b) /\ ~ZeroNapiKey)

Next ==
    \/ \E b \in Blocks:
        \/ ParseNode(b) \/ ParseFree(b)
        \/ WriterOpen(b) \/ ReplyOpen(b) \/ BufferWrite(b) \/ WriterRewind(b)
        \/ BufferTake(b) \/ BufferDeinit(b)
        \/ CopyOwn(b) \/ CopyRelease(b) \/ AnswerRelease(b)
        \/ NapiCopy(b) \/ NapiRelease(b)
    \/ \E b, c \in Blocks:
        /\ b # c
        /\ (BufferGrowByRealloc(b, c) \/ BufferGrowByCopy(b, c))

Spec == Init /\ [][Next]_vars

Bounded == held <= MaxEvents

-----------------------------------------------------------------------------
\* libc never gets back a block that holds a secret.
NoSecretReleased == leaks["free"] = 0 /\ leaks["move"] = 0

\* The part of NoSecretReleased a growing buffer can break by itself: libc's
\* realloc moves a block that holds a secret and takes the old one back as it
\* is.
NoSecretMoved == leaks["move"] = 0

\* Witness: the model does give back blocks that held a secret, so
\* NoSecretReleased does not hold for want of any. Must be violated.
NoSecretEverHeld == held = 0
=============================================================================
