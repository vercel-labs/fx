---- MODULE ErrorData ----
\* What a failed tools/call's error `data` becomes on its way to the model
\* (findings.md D2). A server explains a refusal in the error's `data`, such as
\* which arguments broke its schema. The engine reads it (`wire.Failure.data`),
\* the host copies the failure (`copyCall`, src/core/mcp_host/runtime.zig), and
\* the model's text is written from the copy (`render`,
\* src/core/mcp_host/model.zig).
\*
\* One answer is one step. The data's `kind` is none (a missing data), null,
\* unreadable (the host cannot read it safely: it is not UTF-8, not JSON, or
\* nested past the depth limit, so it is left out), or text. `size` is a text's
\* compact JSON bytes (more than the cap for data too long to read). What the
\* model's text holds of the data is `form`: nothing, the
\* whole compact text, or a cut. A cut is one JSON string literal: its quotes,
\* then the first `prefix` bytes of the data written with `extra` bytes of
\* escapes (a quote or a backslash costs 1 more, a control byte 5 more), then a
\* marker. So the bytes of the data in the text are `Shown`: `size` for the
\* whole text, and 2 + prefix + extra for a cut. `held` is the most bytes the
\* host kept of the data before the cut, and `logged` says that a trace or log
\* line carried the data. `split` says the cut fell inside a character.
\*   Carry "data": the host keeps the data, bounded, as the code does after the change.
\*   Carry "drop": it keeps only the code and the message, as the code did before.
\* A -32042 answer is the user's to answer (UrlRetry.tla): its data is left out,
\* and so are a null data and an unreadable one. None changes what the model was told.
\*
\* The bound, in the model, the code (`data_cap` in runtime.zig), and the fuzz
\* law (`mcp_error_data`): the whole text is at most Cap bytes; a cut's quotes
\* and escaped prefix are at most Cap bytes, and the marker is more, at most
\* MaxMarker bytes; and a cut keeps as much as fits, up to the cost of one
\* character (MaxChar, 6: a control byte written as \u0007).
EXTENDS Integers

CONSTANTS
    Cap,        \* the cap on the data in the text, in bytes (8192 in fx)
    MaxSize,    \* the biggest data text tried
    MaxChar,    \* the most bytes one character costs when written (6)
    Carry       \* "data" or "drop"

ASSUME Cap \in Nat /\ Cap >= 8
ASSUME MaxSize \in Nat /\ MaxChar \in Nat /\ MaxChar >= 2
ASSUME Carry \in {"data", "drop"}

Codes == {"invalid_params", "url_required"}
Kinds == {"none", "null", "unreadable", "text"}

VARIABLES seen, code, kind, size, form, prefix, extra, marked, held, split, logged
vars == <<seen, code, kind, size, form, prefix, extra, marked, held, split, logged>>

Carried(c, k) == Carry = "data" /\ c = "invalid_params" /\ k = "text"

\* What the code may keep of a cut: a prefix of the data, whose escapes cost `e` more bytes,
\* so that its quotes and escaped form fit the cap, and one more character would not.
Cuts(n, p, e) ==
    /\ p <= n
    /\ e <= 5 * p
    /\ 2 + p + e <= Cap
    /\ 2 + p + e + MaxChar > Cap

TypeOK ==
    /\ seen \in BOOLEAN
    /\ code \in Codes
    /\ kind \in Kinds
    /\ size \in 0..MaxSize
    /\ form \in {"none", "whole", "cut"}
    /\ prefix \in 0..MaxSize
    /\ extra \in 0..(5 * MaxSize)
    /\ marked \in BOOLEAN
    /\ held \in 0..MaxSize
    /\ split \in BOOLEAN
    /\ logged \in BOOLEAN

Init ==
    /\ seen = FALSE /\ code = "invalid_params" /\ kind = "none" /\ size = 0
    /\ form = "none" /\ prefix = 0 /\ extra = 0 /\ marked = FALSE
    /\ held = 0 /\ split = FALSE /\ logged = FALSE

\* `p` and `e` are what the code kept of a cut; they matter only for a cut.
Answer(c, k, n, p, e) ==
    /\ seen' = TRUE
    /\ code' = c /\ kind' = k /\ size' = n
    /\ IF ~Carried(c, k) \/ n <= Cap
       THEN /\ prefix' = IF Carried(c, k) THEN n ELSE 0
            /\ extra' = 0
       ELSE /\ Cuts(n, p, e)
            /\ prefix' = p
            /\ extra' = e
    /\ form' = IF ~Carried(c, k) THEN "none" ELSE IF n <= Cap THEN "whole" ELSE "cut"
    /\ marked' = (Carried(c, k) /\ n > Cap)
    /\ held' = IF ~Carried(c, k) THEN 0 ELSE IF n <= Cap THEN n ELSE 2 + p + e
    /\ split' = FALSE
    /\ logged' = FALSE

Next ==
    \E c \in Codes, k \in Kinds, n \in 0..MaxSize, p \in 0..MaxSize, e \in 0..(5 * MaxSize) :
        /\ (k = "text" => n >= 1)
        /\ (k # "text" => n = 0)
        /\ Answer(c, k, n, p, e)

Spec == Init /\ [][Next]_vars

\* Stated for users. Data a server gives with an error reaches the model: whole
\* when it fits the cap, and otherwise cut, with a marker that says so.
ErrorDataReachesModel ==
    (seen /\ code = "invalid_params" /\ kind = "text") =>
        IF size <= Cap
        THEN form = "whole" /\ prefix = size /\ ~marked
        ELSE form = "cut" /\ marked

\* What the model was told stays what it was: no data, null data and a -32042's data add nothing.
Unchanged ==
    (seen /\ (code = "url_required" \/ kind # "text")) =>
        form = "none" /\ prefix = 0 /\ extra = 0 /\ ~marked

\* The bound on what the model sees: the whole text is at most Cap bytes, and a cut's quotes and
\* escaped prefix are at most Cap bytes, before the marker.
Bounded ==
    seen =>
        /\ (form = "whole" => prefix <= Cap)
        /\ (form = "cut" => 2 + prefix + extra <= Cap)

\* A cut keeps as much as fits: one more character would not.
KeepsMost == (seen /\ form = "cut") => 2 + prefix + extra + MaxChar > Cap

\* The host never keeps more than the cap of it, even for the moment of the cut.
HeldBounded == seen => held <= Cap

\* The cut falls where a character ends.
CutOnBoundary == seen => ~split

\* The data is the server's to give the model, and no log line carries it.
NoDataInLogs == seen => ~logged
====
