---- MODULE FieldRead ----
\* The engine reading one field of a JSON object by name (U01,
\* src/mcp/protocol/wire.zig objectFields).
\*
\* A server writes each member name plain or with JSON escapes: `isError` and
\* `is\u0045rror` are one name once decoded, and `std.json`, which core and the
\* ACP projection use, reads both spellings as that name. The engine is the
\* only reader of some fields (`isError`, `resultType`, `id`, `requestState`,
\* `ttlMs`, `nextCursor`, `instructions`). Until now it skipped a name written
\* with an escape, as if the server had left the field out.
\*
\* One read looks at one asked field in one object:
\*   plain    members whose name is the field, written plain
\*   escaped  members whose name is the field once decoded, written with an
\*            escape
\*   other    members written with an escape whose decoded name is not the
\*            field, such as `x\u0000id` for `id`
\*   flag     the field's boolean value, as for `isError`
\* KeyRead is how the engine compares a name: "decoded" decodes it first, "raw"
\* is the code before the fix.
\*
\* Rules:
\*   AgreeOrRefused   the engine refuses the object, or reads the field as
\*                    std.json reads it: absent, once, or twice
\*   DupRefused       a name written twice, however it is spelled, is refused
\*   ReportedAsSaid   the value the engine reports for the field is the value
\*                    the server wrote, so a tool result the server marked
\*                    isError is not shown as a success
EXTENDS Naturals

CONSTANTS KeyRead, MaxMembers

ASSUME KeyRead \in {"decoded", "raw"}
ASSUME MaxMembers \in Nat

VARIABLES plain, escaped, other, flag, engineView, stdView, refused, read

vars == <<plain, escaped, other, flag, engineView, stdView, refused, read>>

Views == {"absent", "value", "dup"}

ViewOf(n) == IF n = 0 THEN "absent" ELSE IF n = 1 THEN "value" ELSE "dup"

\* How many members the engine counts for the field.
EngineCount(p, e, o) == p + (IF KeyRead = "decoded" THEN e ELSE 0)

EngineView(p, e, o) == ViewOf(EngineCount(p, e, o))

TypeOK ==
    /\ plain \in 0..MaxMembers
    /\ escaped \in 0..MaxMembers
    /\ other \in 0..MaxMembers
    /\ flag \in BOOLEAN
    /\ engineView \in Views
    /\ stdView \in Views
    /\ refused \in BOOLEAN
    /\ read \in BOOLEAN

Init ==
    /\ plain = 0
    /\ escaped = 0
    /\ other = 0
    /\ flag = FALSE
    /\ engineView = "absent"
    /\ stdView = "absent"
    /\ refused = FALSE
    /\ read = FALSE

\* One read of an object with these members.
Read(p, e, o, fl) ==
    /\ plain' = p
    /\ escaped' = e
    /\ other' = o
    /\ flag' = fl
    /\ engineView' = EngineView(p, e, o)
    /\ stdView' = ViewOf(p + e)
    /\ refused' = (EngineView(p, e, o) = "dup")
    /\ read' = TRUE

Next == \E p, e, o \in 0..MaxMembers, fl \in BOOLEAN : Read(p, e, o, fl)

Spec == Init /\ [][Next]_vars

EngineReported == IF engineView = "value" THEN flag ELSE FALSE
StdReported == IF stdView = "value" THEN flag ELSE FALSE

AgreeOrRefused == read => (refused \/ engineView = stdView)

DupRefused == read => (stdView = "dup" => refused)

ReportedAsSaid == read => (refused \/ EngineReported = StdReported)
====
