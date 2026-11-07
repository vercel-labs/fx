---------------------------- MODULE NetProxy ----------------------------
(*
How fx routes a connection when the proxy variables are set, and which
request reports a proxy failure. The route, the CONNECT exchange, and the
failure log are src/core/shared/net_proxy.zig; src/core/shared/net_proxy_io.zig
installs them in the process Io through io_mod.setIo; web_fetch tunnels to the
address it admitted in src/tools/web/http_fetch.zig; the gateway claims a
failure for its own request in src/gateway/client.zig.

Two connections run at once. Each has a target:
  routed         an https host that no NO_PROXY entry names
  bypass         a host NO_PROXY names, which goes direct
  fetch_public   a web_fetch URL whose local DNS answer is public
  fetch_private  a web_fetch URL whose local DNS answer is private
The proxy requires credentials and answers each CONNECT with 200 (ok),
407 (auth), 503 (refused), bytes that are not HTTP (garbage), or nothing
before the caller's deadline (silent).

The wire records what fx sends and where:
  hop   "direct" (straight to the host) or "proxy"
  kind  "connect" (the CONNECT head), "tls" (a request inside TLS to the
        host), or "plain" (a request in plain text, with its headers)
  dest  "target", or "private" for a private web_fetch address

A CONNECT that fails leaves one record in the failure log, for its own
target. A failed request then reports: it shows the proxy text only when it
claims a record, and a claim uses the record up. got is the target the
claimed record names.

The constants switch the mechanisms on and off:
  UseProxy         fx reads the proxy variables at all (FALSE is fx today)
  AuthOnConnect    Proxy-Authorization rides on CONNECT
  TlsAfterConnect  TLS to the host runs inside the tunnel
  NoFallback       a failed CONNECT fails the connection
  SharedFlag       std's one supports_connect flag decides every route
  PinFetchIp       web_fetch checks the local answer and CONNECTs to that IP
  DetailMode       "own_target": a request claims an unclaimed record for its
                   own target, and only when its own failure came from the
                   proxy; "global": any request reads the last record, as a
                   process-wide last error would
*)
EXTENDS Naturals, FiniteSets

CONSTANTS UseProxy, AuthOnConnect, TlsAfterConnect, NoFallback, SharedFlag, PinFetchIp, DetailMode

Conns == {"a", "b"}
Targets == {"routed", "bypass", "fetch_public", "fetch_private"}
Answers == {"ok", "auth", "refused", "garbage", "silent"}
Phases == {"idle", "routed", "connect_sent", "answered", "open", "sent", "failed"}
Routes == {"none", "direct", "tunnel", "forward"}
Shown == {"unread", "none", "proxy"}

VARIABLES target, phase, route, answer, wire, supports, records, claimed, shown, got

vars == <<target, phase, route, answer, wire, supports, records, claimed, shown, got>>

Record(c, hop, kind, dest) == [c |-> c, hop |-> hop, kind |-> kind, dest |-> dest]

\* Where a tunnel for c ends: web_fetch by name lets the proxy resolve a
\* private name; a pinned IP never reaches one, because the private answer
\* is refused before any connection.
Dest(c) == IF target[c] = "fetch_private" THEN "private" ELSE "target"

\* The failure came from the proxy: it answered the CONNECT, and not with 200.
FailedAtProxy(c) == phase[c] = "failed" /\ answer[c] \notin {"none", "ok"}

TypeOK ==
    /\ target \in [Conns -> Targets]
    /\ phase \in [Conns -> Phases]
    /\ route \in [Conns -> Routes]
    /\ answer \in [Conns -> Answers \cup {"none"}]
    /\ supports \in BOOLEAN
    /\ records \subseteq Conns
    /\ claimed \subseteq records
    /\ shown \in [Conns -> Shown]
    /\ got \in [Conns -> Targets \cup {"none"}]

Init ==
    /\ target \in [Conns -> Targets]
    /\ phase = [c \in Conns |-> "idle"]
    /\ route = [c \in Conns |-> "none"]
    /\ answer = [c \in Conns |-> "none"]
    /\ wire = {}
    /\ supports = TRUE
    /\ records = {}
    /\ claimed = {}
    /\ shown = [c \in Conns |-> "unread"]
    /\ got = [c \in Conns |-> "none"]

\* The route decision. In the design it is a pure function of the immutable
\* snapshot and the host; with SharedFlag it also reads std's shared flag.
Lookup(c) ==
    /\ phase[c] = "idle"
    /\ \/ /\ target[c] = "fetch_private"
          /\ PinFetchIp
          \* web_fetch refuses a private local answer before any connection.
          /\ phase' = [phase EXCEPT ![c] = "failed"]
          /\ UNCHANGED route
       \/ /\ ~(target[c] = "fetch_private" /\ PinFetchIp)
          /\ LET r == IF ~UseProxy \/ target[c] = "bypass" THEN "direct"
                      ELSE IF SharedFlag /\ ~supports THEN "forward"
                      ELSE "tunnel"
             IN route' = [route EXCEPT ![c] = r]
          /\ phase' = [phase EXCEPT ![c] = "routed"]
    /\ UNCHANGED <<target, answer, wire, supports, records, claimed, shown, got>>

SendConnect(c) ==
    /\ phase[c] = "routed"
    /\ route[c] = "tunnel"
    /\ wire' = wire \cup {Record(c, "proxy", "connect", Dest(c))}
    /\ phase' = [phase EXCEPT ![c] = "connect_sent"]
    /\ UNCHANGED <<target, route, answer, supports, records, claimed, shown, got>>

\* The proxy needs credentials: without them it can only answer 407.
ProxyAnswers(c, a) ==
    /\ phase[c] = "connect_sent"
    /\ AuthOnConnect \/ a = "auth"
    /\ answer' = [answer EXCEPT ![c] = a]
    /\ phase' = [phase EXCEPT ![c] = "answered"]
    /\ UNCHANGED <<target, route, wire, supports, records, claimed, shown, got>>

TunnelOpens(c) ==
    /\ phase[c] = "answered"
    /\ answer[c] = "ok"
    /\ phase' = [phase EXCEPT ![c] = "open"]
    /\ UNCHANGED <<target, route, answer, wire, supports, records, claimed, shown, got>>

\* A CONNECT that did not answer 200. The design fails the connection and
\* logs one record for it. std clears supports_connect unless the answer was
\* a 5xx and retries the same request as a plain-text forward-proxy request.
TunnelFails(c) ==
    /\ phase[c] = "answered"
    /\ answer[c] # "ok"
    /\ IF NoFallback
         THEN /\ phase' = [phase EXCEPT ![c] = "failed"]
              /\ records' = records \cup {c}
              /\ UNCHANGED <<route, supports>>
         ELSE /\ phase' = [phase EXCEPT ![c] = "routed"]
              /\ route' = [route EXCEPT ![c] = "forward"]
              /\ supports' = IF SharedFlag THEN answer[c] = "refused" ELSE supports
              /\ UNCHANGED records
    /\ UNCHANGED <<target, answer, wire, claimed, shown, got>>

Send(c) ==
    \/ /\ phase[c] = "routed"
       /\ route[c] = "direct"
       /\ wire' = wire \cup {Record(c, "direct", "tls", Dest(c))}
       /\ phase' = [phase EXCEPT ![c] = "sent"]
    \/ /\ phase[c] = "routed"
       /\ route[c] = "forward"
       /\ wire' = wire \cup {Record(c, "proxy", "plain", Dest(c))}
       /\ phase' = [phase EXCEPT ![c] = "sent"]
    \/ /\ phase[c] = "open"
       /\ wire' = wire \cup {Record(c, "proxy", IF TlsAfterConnect THEN "tls" ELSE "plain", Dest(c))}
       /\ phase' = [phase EXCEPT ![c] = "sent"]

SendStep(c) == Send(c) /\ UNCHANGED <<target, route, answer, supports, records, claimed, shown, got>>

\* A failed request decides what it shows. With "own_target" it claims an
\* unclaimed record for its own target, and only when its own failure came
\* from the proxy; the claim uses the record up. With "global" it reads
\* whatever was logged last and leaves it for the next reader.
Report(c) ==
    /\ phase[c] = "failed"
    /\ shown[c] = "unread"
    /\ IF DetailMode = "own_target"
         THEN LET mine == {r \in records \ claimed : target[r] = target[c]}
              IN IF answer[c] \notin {"none", "ok"} /\ mine # {}
                   THEN \E r \in mine:
                          /\ claimed' = claimed \cup {r}
                          /\ shown' = [shown EXCEPT ![c] = "proxy"]
                          /\ got' = [got EXCEPT ![c] = target[r]]
                   ELSE /\ shown' = [shown EXCEPT ![c] = "none"]
                        /\ UNCHANGED <<claimed, got>>
         ELSE IF records # {}
                THEN \E r \in records:
                       /\ shown' = [shown EXCEPT ![c] = "proxy"]
                       /\ got' = [got EXCEPT ![c] = target[r]]
                       /\ UNCHANGED claimed
                ELSE /\ shown' = [shown EXCEPT ![c] = "none"]
                     /\ UNCHANGED <<claimed, got>>
    /\ UNCHANGED <<target, phase, route, answer, wire, supports, records>>

Next ==
    \E c \in Conns:
        \/ Lookup(c)
        \/ SendConnect(c)
        \/ \E a \in Answers: ProxyAnswers(c, a)
        \/ TunnelOpens(c)
        \/ TunnelFails(c)
        \/ SendStep(c)
        \/ Report(c)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* A host that NO_PROXY does not name never gets a direct connection.
NoDirectWhenRouted ==
    \A w \in wire: w.hop = "direct" => target[w.c] = "bypass"

\* No request ever leaves in plain text: its Authorization header would reach
\* the proxy and the network.
NoPlainRequest ==
    \A w \in wire: w.kind # "plain"

\* web_fetch never reaches a private address through the proxy.
NoPrivateReach ==
    \A w \in wire: w.dest # "private"

\* A connection that failed sent no request.
FailClosed ==
    \A c \in Conns: phase[c] = "failed" =>
        \A w \in wire: w.c = c => w.kind = "connect"

\* Only a request whose own connect failed at the proxy shows proxy text.
DetailBelongsToFailingConnect ==
    \A c \in Conns: shown[c] = "proxy" => FailedAtProxy(c)

\* A request that shows proxy text names its own target.
DetailNamesOwnTarget ==
    \A c \in Conns: shown[c] = "proxy" => got[c] = target[c]

\* Each logged failure is shown at most once: reading it clears it.
DetailReadOnce ==
    Cardinality({c \in Conns : shown[c] = "proxy"}) <= Cardinality(records)

\* Clearing never loses a failure: a request whose connect failed at the
\* proxy and has reported shows the proxy text.
DetailNotLost ==
    \A c \in Conns: (FailedAtProxy(c) /\ shown[c] # "unread") => shown[c] = "proxy"
=============================================================================
