------------------------- MODULE NetProxyCallers -------------------------
(*
Which caller names a proxy failure in the text it shows. A connection that
failed at the proxy leaves its sentence on the thread that opened it
(src/core/shared/net_proxy_io.zig: beginOpen, noteOpenFailure), and the caller
that shows an error text takes it: takeRequestFailure for an error that
net_proxy.isProxyFailureError lists, takeHeldFailure for a caller that knows
its failure was a transport failure. NetProxy.tla says what a request shows
once it has taken a sentence; this model says who takes one.

One caller makes one request and fails:
  ask      the model request, which names the proxy
  version  a Grok client version lookup (src/gateway/provider_versions.zig),
           which ends `fx ask` with error.ProviderVersionUnavailable
  upgrade  a request of `fx upgrade` (src/core/upgrade/upgrade_helpers.zig):
           the latest version, the archive, or its checksum
  fetch    a web_fetch call (src/tools/web/fetch.zig transportFailureBody),
           which dials the proxy itself (src/tools/web/http_fetch.zig
           connectThroughProxy) and puts the sentence in the tool's error
The request ran with the proxy variables set or unset, and failed at the proxy
(the proxy was down or refused the CONNECT) or elsewhere (the server answered
an error, or a body did not parse). A request cannot fail at a proxy that is not
set. An earlier request on the same thread may have left a sentence of its own
behind (stale), which only matters when a proxy is set.

web_fetch tries the addresses its host resolved to in order, and each one that
fails at the proxy holds a sentence of its own. When a later address opens its
tunnel, the request goes on and fails elsewhere (the server stays silent or
resets the connection), and the sentence of the earlier address is still held
(earlier): a fetch whose error name the claim lists would show it for a failure
that is not the proxy's. Only web_fetch dials more than one address of a name
itself; the model request reaches the proxy through one handle address per name
(net_proxy_io.zig connectIp) and has no later address.

A failure at the proxy has a name, the error the dial returned when the platform
gave its own: the proxy answered an error ("answered"), the connect was refused
("refused", as Linux's poll and macOS's std.Io connect say it), the connect came
back as error.UnexpectedClose ("unexpected_close": macOS polls a refused
non-blocking connect as HUP alone, so web_fetch's own dialer cannot read the
cause), or any other name ("other": a proxy host name that does not resolve, a
descriptor limit, and so on). A caller takes the held sentence only for an error
that net_proxy.isProxyFailureError lists (takeRequestFailure), and clears it for
any other. The answer of a proxy and a refused connect are on the list;
"unexpected_close" and "other" are not.

The caller shows its text: "proxy" when the text names the proxy, "default"
when it is the caller's fixed text.

The constants switch the mechanisms on and off:
  VersionClaims        error.ProviderVersionUnavailable is an error the claim
                       accepts, so the version lookup takes its sentence (FALSE
                       is fx before this change)
  UpgradeClaims        fx upgrade keeps the error of the request that failed and
                       takes its sentence, instead of fixed text (FALSE is fx
                       before this change)
  FetchStepNames       web_fetch's dial returns, for any failure at the proxy, an
                       error the claim lists, whatever name the platform gave
                       (net_proxy.proxyFailureError); FALSE is web_fetch before
                       this change, which returned the platform's own name. The
                       other callers dial through net_proxy_io.connectIp, which
                       already maps by step.
  ListsUnexpectedClose the claim's list also holds error.UnexpectedClose, as a
                       fix by name would: it covers the macOS answer and no
                       other name
  ClearsAtStart        every request clears a sentence an earlier one left when
                       it starts (beginOpen)
  FetchClears          when web_fetch's dial clears the sentence it holds
                       (src/tools/web/http_fetch.zig connectThroughProxy):
                         "never"      a later address that opens its tunnel keeps
                                      the sentence of an earlier one (web_fetch
                                      before its dial cleared it)
                         "on_open"    the dial clears it when the tunnel opens,
                                      and holds only the sentence of a failure of
                                      its own (the design)
                         "on_return"  the dial clears it on every return,
                                      failures included, as a deferred clear
                                      would, so a failure at the proxy is not shown
  NamesWithoutFailure  a caller names the proxy when none is set, as one that
                       prints a fixed proxy sentence would
*)
EXTENDS Naturals

CONSTANTS VersionClaims, UpgradeClaims, FetchStepNames, ListsUnexpectedClose,
          ClearsAtStart, NamesWithoutFailure, FetchClears

Callers == {"ask", "version", "upgrade", "fetch"}
Proxies == {"set", "unset"}
Causes == {"at_proxy", "elsewhere"}
\* "none" is the name of a request that did not fail at the proxy.
Names == {"none", "answered", "refused", "unexpected_close", "other"}
Texts == {"unread", "default", "proxy"}

VARIABLES caller, proxy, cause, stale, earlier, name, text

vars == <<caller, proxy, cause, stale, earlier, name, text>>

TypeOK ==
    /\ caller \in Callers
    /\ proxy \in Proxies
    /\ cause \in Causes
    /\ stale \in BOOLEAN
    /\ earlier \in BOOLEAN
    /\ name \in Names
    /\ text \in Texts

Init ==
    /\ caller \in Callers
    /\ proxy \in Proxies
    /\ cause \in Causes
    /\ stale \in BOOLEAN
    \* Nothing fails at a proxy that is not set, and nothing is left behind by it.
    /\ (cause = "at_proxy") => (proxy = "set")
    /\ stale => (proxy = "set")
    \* An earlier address of the same request failed at the proxy and a later one
    \* opened its tunnel, so the request's own failure is elsewhere. Only web_fetch
    \* dials more than one address of a name itself.
    /\ earlier \in BOOLEAN
    /\ earlier => (caller = "fetch" /\ proxy = "set" /\ cause = "elsewhere")
    \* The thread holds one sentence at a time, so the sentence of the earlier
    \* address replaced any that an earlier request left.
    /\ earlier => ~stale
    \* Only a failure at the proxy has a name.
    /\ name \in Names
    /\ (cause = "at_proxy") <=> (name # "none")
    /\ text = "unread"

AtProxy == proxy = "set" /\ cause = "at_proxy"

\* web_fetch's dial clears on every return, so it drops the sentence of its own
\* failure too.
DialDropsOwn == caller = "fetch" /\ FetchClears = "on_return"

\* What this thread holds when the caller reads: the sentence of its own failed
\* connect; when nothing clears it at the start of a request, one an earlier
\* request left behind; or, when the dial keeps it past a tunnel that opened, one
\* an earlier address of this request left behind.
Holds ==
    \/ AtProxy /\ ~DialDropsOwn
    \/ proxy = "set" /\ stale /\ ~ClearsAtStart
    \/ proxy = "set" /\ earlier /\ FetchClears = "never"

CallerClaims(c) ==
    CASE c = "version" -> VersionClaims
      [] c = "upgrade" -> UpgradeClaims
      [] OTHER -> TRUE

\* An error the claim lists.
Listed(n) ==
    \/ n \in {"answered", "refused"}
    \/ n = "unexpected_close" /\ ListsUnexpectedClose

\* Whether the dial returns, for this caller, a name that does not depend on the
\* platform's: web_fetch's own dialer returns what the platform said unless it
\* maps by step.
StepNames(c) == IF c = "fetch" THEN FetchStepNames ELSE TRUE

\* The error a failure at the proxy ended the request with is one the claim lists.
ErrorClaimed == ~AtProxy \/ StepNames(caller) \/ Listed(name)

\* The caller shows its text.
Show ==
    /\ text = "unread"
    /\ text' = IF CallerClaims(caller) /\ ErrorClaimed /\ (Holds \/ (NamesWithoutFailure /\ proxy = "unset"))
                 THEN "proxy"
                 ELSE "default"
    /\ UNCHANGED <<caller, proxy, cause, stale, earlier, name>>

Next == Show

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* The model request names the proxy whose failure ended it.
AskNamesProxy ==
    (caller = "ask" /\ text # "unread" /\ AtProxy) => text = "proxy"

\* A version lookup that failed at the proxy names it.
VersionNamesProxy ==
    (caller = "version" /\ text # "unread" /\ AtProxy) => text = "proxy"

\* An upgrade request that failed at the proxy names it.
UpgradeNamesProxy ==
    (caller = "upgrade" /\ text # "unread" /\ AtProxy) => text = "proxy"

\* A web_fetch that failed at the proxy names it, whatever name the platform gave the
\* failed dial.
FetchNamesProxy ==
    (caller = "fetch" /\ text # "unread" /\ AtProxy) => text = "proxy"

\* With no proxy set, no caller names one: its text stays what it is today.
NoProxyKeepsDefault ==
    proxy = "unset" => text # "proxy"

\* A web_fetch whose later address opened its tunnel does not show the sentence of an
\* earlier address that failed at the proxy, for a failure of the open tunnel.
LaterAddressClears ==
    (earlier /\ text # "unread") => text # "proxy"

\* With a proxy set, a caller names it only for its own failure at the proxy,
\* never for a sentence an earlier request left behind.
OwnFailureOnly ==
    (proxy = "set" /\ text = "proxy") => cause = "at_proxy"
=============================================================================
