--------------------------- MODULE ConfiguredCatalog ---------------------------
(***************************************************************************)
(* The model list of a custom model connection                             *)
(* (src/gateway/chat_completions.zig fetch_catalog, loaded by              *)
(* src/core/app/model_cache_runtime.zig and                                *)
(* src/core/gateway/gateway_provider.zig).                                 *)
(*                                                                         *)
(* A connection always lists the models its settings declare. When its     *)
(* settings turn `fetch_models` on, fx also asks the server for its list   *)
(* (GET {base_url}/models) and adds what the server lists. The request is  *)
(* bounded by the connection's timeout, a failure falls back to the        *)
(* declared models with one line, and a reply for a connection the person  *)
(* has left never reaches the list. `fx models` prints the line on stderr; *)
(* the picker, which has no stderr, writes it to the trace log.            *)
(*                                                                         *)
(* Two connections, "a" and "b", each declare one model and serve one      *)
(* other. The server may answer with its list, fail, or never answer.      *)
(* Time counts in ticks; the deadline falls at Timeout ticks, and an       *)
(* answer that arrives at the deadline loses to it.                        *)
(*                                                                         *)
(* Bug plants one defect; check.sh names the rule that must catch each.    *)
(* "today" is fx before the change, which never asks the server.           *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS Timeout, MaxSwitches, MaxAsks, Bug

Conns == {"a", "b"}
Other(c) == IF c = "a" THEN "b" ELSE "a"
Declared(c) == {<<c, "declared">>}
Listed(c) == {<<c, "listed">>}
NoFlight == [conn |-> "none", cancelled |-> FALSE]

VARIABLES
    fetch,     \* for each connection, whether its settings turn fetch_models on
    selected,  \* the connection the person is on
    shown,     \* the models the picker and `fx models` list
    state,     \* "idle" before a load, "loading", or "ready"
    flight,    \* the request in flight, and whether the person has left it
    elapsed,   \* ticks since the request in flight was sent
    lines,     \* failure lines shown for the current list
    asked,     \* every request sent: the connection and whose token it carried
    failed,    \* the last request for the current list failed
    listed,    \* the current list holds the server's models
    switches   \* how often the person changed connection

vars == <<fetch, selected, shown, state, flight, elapsed, lines, asked, failed, listed, switches>>

InitWith(f, s) ==
    /\ fetch = f
    /\ selected = s
    /\ shown = {}
    /\ state = "idle"
    /\ flight = NoFlight
    /\ elapsed = 0
    /\ lines = 0
    /\ asked = <<>>
    /\ failed = FALSE
    /\ listed = FALSE
    /\ switches = 0

Init == \E f \in [Conns -> BOOLEAN], s \in Conns : InitWith(f, s)

\* A fresh fx process, for trace validation of several runs in a row.
Reset(f, s) ==
    /\ fetch' = f
    /\ selected' = s
    /\ shown' = {}
    /\ state' = "idle"
    /\ flight' = NoFlight
    /\ elapsed' = 0
    /\ lines' = 0
    /\ asked' = <<>>
    /\ failed' = FALSE
    /\ listed' = FALSE
    /\ switches' = 0

InFlight == flight.conn # "none"

\* fx asks the selected connection's server for its list.
Asks ==
    IF Bug = "today" THEN FALSE
    ELSE fetch[selected] \/ Bug = "probe_when_off"

Ask ==
    /\ flight' = [conn |-> selected, cancelled |-> FALSE]
    /\ elapsed' = 0
    /\ asked' = Append(asked,
          [to |-> selected,
           token |-> IF Bug = "wrong_token" /\ switches > 0 THEN Other(selected) ELSE selected])

\* The first load after launch or a change of connection. The declared
\* models are listed at once; the server's follow when it answers.
Load ==
    /\ state = "idle"
    /\ ~InFlight
    /\ shown' = Declared(selected)
    /\ IF Asks
          THEN state' = "loading" /\ Ask
          ELSE state' = "ready" /\ UNCHANGED <<flight, elapsed, asked>>
    /\ UNCHANGED <<fetch, selected, lines, failed, listed, switches>>

\* Opening the picker again asks the server again.
Refresh ==
    /\ state = "ready"
    /\ ~InFlight
    /\ Asks
    /\ Len(asked) < MaxAsks
    /\ Ask
    /\ lines' = 0
    /\ failed' = FALSE
    /\ UNCHANGED <<fetch, selected, shown, state, listed, switches>>

\* The server answers with its list before the deadline.
Lists ==
    /\ InFlight
    /\ elapsed < Timeout
    /\ flight' = NoFlight
    /\ IF flight.cancelled /\ Bug # "stale_reply"
          THEN UNCHANGED <<shown, state, listed>>
          ELSE /\ shown' = IF Bug = "drop_declared"
                              THEN Listed(flight.conn)
                              ELSE Declared(selected) \cup Listed(flight.conn)
               /\ state' = "ready"
               /\ listed' = TRUE
    /\ UNCHANGED <<fetch, selected, elapsed, lines, asked, failed, switches>>

\* The request ends without a list. The list falls back to the declared
\* models, also when the server gave its list before: a server that cannot
\* answer now does not keep its models on show.
Fail ==
    /\ flight' = NoFlight
    /\ IF flight.cancelled
          THEN UNCHANGED <<shown, state, lines, failed, listed>>
          ELSE /\ shown' = IF listed /\ Bug = "failure_keeps_list" THEN shown ELSE Declared(selected)
               /\ state' = "ready"
               /\ failed' = TRUE
               /\ listed' = FALSE
               /\ lines' = IF Bug = "silent_failure" THEN lines ELSE lines + 1
    /\ UNCHANGED <<fetch, selected, elapsed, asked, switches>>

\* The server refuses, breaks, sends something that is no list, or closes,
\* before the deadline.
Refuses == InFlight /\ elapsed < Timeout /\ Fail

Tick ==
    /\ InFlight
    /\ elapsed < Timeout
    /\ elapsed' = elapsed + 1
    /\ UNCHANGED <<fetch, selected, shown, state, flight, lines, asked, failed, listed, switches>>

Deadline == InFlight /\ elapsed >= Timeout /\ Bug # "no_deadline" /\ Fail

\* A request the person left stops and returns.
Returns ==
    /\ InFlight
    /\ flight.cancelled
    /\ flight' = NoFlight
    /\ UNCHANGED <<fetch, selected, shown, state, elapsed, lines, asked, failed, listed, switches>>

\* The person changes connection. The request in flight is cancelled.
Switch ==
    /\ switches < MaxSwitches
    /\ switches' = switches + 1
    /\ selected' = Other(selected)
    /\ shown' = {}
    /\ state' = "idle"
    /\ lines' = 0
    /\ failed' = FALSE
    /\ listed' = FALSE
    /\ flight' = IF InFlight THEN [flight EXCEPT !.cancelled = TRUE] ELSE flight
    /\ UNCHANGED <<fetch, elapsed, asked>>

Next == Load \/ Refresh \/ Lists \/ Refuses \/ Tick \/ Deadline \/ Returns \/ Switch

Spec == Init /\ [][Next]_vars /\ WF_vars(Tick) /\ WF_vars(Deadline) /\ WF_vars(Returns)

-----------------------------------------------------------------------------

TypeOK ==
    /\ fetch \in [Conns -> BOOLEAN]
    /\ selected \in Conns
    /\ shown \subseteq (Conns \X {"declared", "listed"})
    /\ state \in {"idle", "loading", "ready"}
    /\ flight \in [conn : Conns \cup {"none"}, cancelled : BOOLEAN]
    /\ elapsed \in 0..Timeout
    /\ lines \in Nat
    /\ asked \in Seq([to : Conns, token : Conns])
    /\ failed \in BOOLEAN
    /\ listed \in BOOLEAN
    /\ switches \in 0..MaxSwitches

\* A connection whose settings leave fetch_models off is never asked.
NoRequestWhenOff == \A i \in DOMAIN asked : fetch[asked[i].to]

\* A connection's token goes only to that connection.
TokenStaysWithItsConnection == \A i \in DOMAIN asked : asked[i].token = asked[i].to

\* The list never holds another connection's models.
ShownBelongsToSelected == \A id \in shown : id[1] = selected

\* The declared models are listed as soon as a load starts, and stay.
DeclaredAlwaysShown == state # "idle" => Declared(selected) \subseteq shown

\* A connection with fetch_models on is asked.
FetchOnAsks ==
    (state # "idle" /\ fetch[selected]) => \E i \in DOMAIN asked : asked[i].to = selected

\* Once the server answered, its models are listed.
ServerModelsListed == listed => Listed(selected) \subseteq shown

\* Without the server's list, the list is exactly the declared models.
FallbackIsDeclared == (state = "ready" /\ ~listed) => shown = Declared(selected)

\* A failure shows one line, and nothing else does.
FailureSaysSo == lines = (IF failed THEN 1 ELSE 0)

\* A request never outlives its deadline.
RequestSettles == [](InFlight => <>(~InFlight))
=============================================================================
