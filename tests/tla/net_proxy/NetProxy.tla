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
407 (auth), 503 (refused), bytes that are not HTTP (garbage), nothing before
the caller's deadline (silent), an interim head such as 102 and then 200
(interim), or 101 and then 200 (switching). A proxy that cannot be reached
at all is the answer dead.

The wire records what fx sends and where:
  hop   "direct" (straight to the host) or "proxy"
  kind  "connect" (the CONNECT head), "tls" (a request inside TLS to the
        host), or "plain" (a request in plain text, with its headers)
  dest  "target", or "private" for a private web_fetch address

A CONNECT that fails leaves one record in the failure log, for its own
target. A failure that fx does not retry (407, garbage, 101) ends the request,
which reports: it shows the proxy text only when it claims a record, and a
claim uses the record up. got is the target the claimed record names. A
failure that fx retries (a dead proxy, a 5xx answer, no answer) shows a retry
notice instead, which names the proxy the same way: notice is what the notice
says, and ngot the target the claimed record names. A notice has 95 bytes, and
it must keep its wait part ("next try in", "retrying") as well as name the
proxy; "proxy_cut" is a notice that named the proxy and lost the wait part.

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
  InterimMode      how an interim head before the final answer is read.
                   "skip_not_101": 1xx heads other than 101 are skipped and
                   the final answer decides (RFC 9110 section 15.2); "refuse":
                   any 1xx ends the CONNECT as a refusal; "skip_all": 101 is
                   skipped too
  NoticeMode       what a retry notice says. "own_target": it claims a record
                   as DetailMode does and names the proxy; "generic": it says
                   only that the network is down; "global": it reads any record
  NoticeForm       how a notice names the proxy. "short": host:port and the
                   cause in at most 48 bytes, the host cut with an ellipsis, so
                   the wait part always fits; "full": the whole sentence, which
                   leaves no room for the wait part when it is long, as a 502's
                   sentence is; "short_uncut": a short form whose host is not cut
  LongHost         the proxy's host name is as long as a host name can be (253
                   bytes), so any sentence or uncut host fills the status text
*)
EXTENDS Naturals, FiniteSets

CONSTANTS UseProxy, AuthOnConnect, TlsAfterConnect, NoFallback, SharedFlag, PinFetchIp, DetailMode,
          InterimMode, NoticeMode, NoticeForm, LongHost

Conns == {"a", "b"}
Targets == {"routed", "bypass", "fetch_public", "fetch_private"}
Answers == {"ok", "auth", "refused", "garbage", "silent", "interim", "switching", "dead"}
Phases == {"idle", "routed", "connect_sent", "answered", "open", "sent", "failed"}
Routes == {"none", "direct", "tunnel", "forward"}
Shown == {"unread", "none", "proxy"}
Notices == {"unread", "generic", "proxy", "proxy_cut"}

VARIABLES target, phase, route, answer, wire, supports, records, claimed, shown, got, notice, ngot

vars == <<target, phase, route, answer, wire, supports, records, claimed, shown, got, notice, ngot>>

Record(c, hop, kind, dest) == [c |-> c, hop |-> hop, kind |-> kind, dest |-> dest]

\* Where a tunnel for c ends: web_fetch by name lets the proxy resolve a
\* private name; a pinned IP never reaches one, because the private answer
\* is refused before any connection.
Dest(c) == IF target[c] = "fetch_private" THEN "private" ELSE "target"

\* The failure came from the proxy: it answered the CONNECT, and not with 200.
FailedAtProxy(c) == phase[c] = "failed" /\ answer[c] \notin {"none", "ok"}

\* fx retries what may pass on its own: a dead proxy, a 5xx answer, and no
\* answer. Every other failure ends the request.
Retryable(a) == a \in {"refused", "silent", "dead"}

\* Whether an answer opens the tunnel. A 1xx head other than 101 is interim:
\* the final answer that follows it decides, and the proxy sends 200.
Opens(a) ==
    \/ a = "ok"
    \/ (a = "interim" /\ InterimMode # "refuse")
    \/ (a = "switching" /\ InterimMode = "skip_all")

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
    /\ notice \in [Conns -> Notices]
    /\ ngot \in [Conns -> Targets \cup {"none"}]

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
    /\ notice = [c \in Conns |-> "unread"]
    /\ ngot = [c \in Conns |-> "none"]

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
    /\ UNCHANGED <<target, answer, wire, supports, records, claimed, shown, got, notice, ngot>>

SendConnect(c) ==
    /\ phase[c] = "routed"
    /\ route[c] = "tunnel"
    /\ wire' = wire \cup {Record(c, "proxy", "connect", Dest(c))}
    /\ phase' = [phase EXCEPT ![c] = "connect_sent"]
    /\ UNCHANGED <<target, route, answer, supports, records, claimed, shown, got, notice, ngot>>

\* The proxy needs credentials: without them it can only answer 407.
ProxyAnswers(c, a) ==
    /\ phase[c] = "connect_sent"
    /\ AuthOnConnect \/ a \in {"auth", "dead"}
    /\ answer' = [answer EXCEPT ![c] = a]
    /\ phase' = [phase EXCEPT ![c] = "answered"]
    /\ UNCHANGED <<target, route, wire, supports, records, claimed, shown, got, notice, ngot>>

TunnelOpens(c) ==
    /\ phase[c] = "answered"
    /\ Opens(answer[c])
    /\ phase' = [phase EXCEPT ![c] = "open"]
    /\ UNCHANGED <<target, route, answer, wire, supports, records, claimed, shown, got, notice, ngot>>

\* A CONNECT that did not answer 200. The design fails the connection and
\* logs one record for it. std clears supports_connect unless the answer was
\* a 5xx and retries the same request as a plain-text forward-proxy request.
TunnelFails(c) ==
    /\ phase[c] = "answered"
    /\ ~Opens(answer[c])
    /\ IF NoFallback
         THEN /\ phase' = [phase EXCEPT ![c] = "failed"]
              /\ records' = records \cup {c}
              /\ UNCHANGED <<route, supports>>
         ELSE /\ phase' = [phase EXCEPT ![c] = "routed"]
              /\ route' = [route EXCEPT ![c] = "forward"]
              /\ supports' = IF SharedFlag THEN answer[c] = "refused" ELSE supports
              /\ UNCHANGED records
    /\ UNCHANGED <<target, answer, wire, claimed, shown, got, notice, ngot>>

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

SendStep(c) == Send(c) /\ UNCHANGED <<target, route, answer, supports, records, claimed, shown, got, notice, ngot>>

\* A failed request decides what it shows. With "own_target" it claims an
\* unclaimed record for its own target, and only when its own failure came
\* from the proxy; the claim uses the record up. With "global" it reads
\* whatever was logged last and leaves it for the next reader.
Report(c) ==
    /\ phase[c] = "failed"
    /\ ~Retryable(answer[c])
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
    /\ UNCHANGED <<target, phase, route, answer, wire, supports, records, notice, ngot>>

\* A notice that names the proxy loses its wait part when what it says does not
\* fit the 95 bytes beside it: the full sentence of a 502 never fits, and with a
\* 253-byte host nothing but a cut host does.
Cuts(c) ==
    \/ NoticeForm = "full" /\ (answer[c] = "refused" \/ LongHost)
    \/ NoticeForm = "short_uncut" /\ LongHost

NamedNotice(c) == IF Cuts(c) THEN "proxy_cut" ELSE "proxy"

NamesProxy(n) == n \in {"proxy", "proxy_cut"}

\* A failed connect that fx retries shows a retry notice. With "own_target"
\* the notice claims an unclaimed record for its own target, as a report does,
\* and names the proxy; with "generic" it says only that the network is down;
\* with "global" it reads whatever was logged and leaves it for the next
\* reader.
Notify(c) ==
    /\ phase[c] = "failed"
    /\ Retryable(answer[c])
    /\ notice[c] = "unread"
    /\ IF NoticeMode = "generic"
         THEN /\ notice' = [notice EXCEPT ![c] = "generic"]
              /\ UNCHANGED <<claimed, ngot>>
         ELSE IF NoticeMode = "own_target"
           THEN LET mine == {r \in records \ claimed : target[r] = target[c]}
                IN IF mine # {}
                     THEN \E r \in mine:
                            /\ claimed' = claimed \cup {r}
                            /\ notice' = [notice EXCEPT ![c] = NamedNotice(c)]
                            /\ ngot' = [ngot EXCEPT ![c] = target[r]]
                     ELSE /\ notice' = [notice EXCEPT ![c] = "generic"]
                          /\ UNCHANGED <<claimed, ngot>>
           ELSE IF records # {}
                  THEN \E r \in records:
                         /\ notice' = [notice EXCEPT ![c] = NamedNotice(c)]
                         /\ ngot' = [ngot EXCEPT ![c] = target[r]]
                         /\ UNCHANGED claimed
                  ELSE /\ notice' = [notice EXCEPT ![c] = "generic"]
                       /\ UNCHANGED <<claimed, ngot>>
    /\ UNCHANGED <<target, phase, route, answer, wire, supports, records, shown, got>>

Next ==
    \E c \in Conns:
        \/ Lookup(c)
        \/ SendConnect(c)
        \/ \E a \in Answers: ProxyAnswers(c, a)
        \/ TunnelOpens(c)
        \/ TunnelFails(c)
        \/ SendStep(c)
        \/ Report(c)
        \/ Notify(c)

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

\* Each logged failure is shown at most once, in a report or a retry notice:
\* reading it clears it.
DetailReadOnce ==
    Cardinality({c \in Conns : shown[c] = "proxy" \/ NamesProxy(notice[c])}) <= Cardinality(records)

\* Clearing never loses a failure: a request whose connect failed at the
\* proxy and has reported shows the proxy text.
DetailNotLost ==
    \A c \in Conns: (FailedAtProxy(c) /\ shown[c] # "unread") => shown[c] = "proxy"

\* An interim head (100 to 199, but not 101) before the final answer never
\* fails the CONNECT: a client must parse one or more 1xx responses before a
\* final one (RFC 9110 section 15.2).
InterimOpens ==
    \A c \in Conns: answer[c] = "interim" => phase[c] # "failed"

\* A 101 is not interim: it switches protocols, so it never opens the tunnel.
SwitchingRefused ==
    \A c \in Conns: answer[c] = "switching" => phase[c] \notin {"open", "sent"}

\* A retry notice for a failure at the proxy names the proxy. Without it a
\* person who mistyped HTTPS_PROXY is told the network is down.
RetryNoticeNamesProxy ==
    \A c \in Conns:
        (FailedAtProxy(c) /\ Retryable(answer[c]) /\ notice[c] # "unread") => NamesProxy(notice[c])

\* Only a request whose own connect failed at the proxy, and that fx retries,
\* shows proxy text in a notice.
NoticeBelongsToFailingConnect ==
    \A c \in Conns: NamesProxy(notice[c]) => (FailedAtProxy(c) /\ Retryable(answer[c]))

\* A notice that names the proxy names its own target.
NoticeNamesOwnTarget ==
    \A c \in Conns: NamesProxy(notice[c]) => ngot[c] = target[c]

\* A retry notice that names the proxy still says when the next try is, or that
\* fx is retrying. The proxy sentence must not push the wait out of the status
\* text, whatever the answer and however long the proxy's host name is.
NoticeKeepsWait ==
    \A c \in Conns: notice[c] # "proxy_cut"
=============================================================================
