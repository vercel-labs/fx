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
The request ran with the proxy variables set or unset, and failed at the proxy
(the proxy was down or refused the CONNECT) or elsewhere (the server answered
an error, or a body did not parse). A request cannot fail at a proxy that is not
set. An earlier request on the same thread may have left a sentence of its own
behind (stale), which only matters when a proxy is set.

The caller shows its text: "proxy" when the text names the proxy, "default"
when it is the caller's fixed text.

The constants switch the mechanisms on and off:
  VersionClaims        error.ProviderVersionUnavailable is an error the claim
                       accepts, so the version lookup takes its sentence (FALSE
                       is fx before this change)
  UpgradeClaims        fx upgrade keeps the error of the request that failed and
                       takes its sentence, instead of fixed text (FALSE is fx
                       before this change)
  ClearsAtStart        every request clears a sentence an earlier one left when
                       it starts (beginOpen)
  NamesWithoutFailure  a caller names the proxy when none is set, as one that
                       prints a fixed proxy sentence would
*)
EXTENDS Naturals

CONSTANTS VersionClaims, UpgradeClaims, ClearsAtStart, NamesWithoutFailure

Callers == {"ask", "version", "upgrade"}
Proxies == {"set", "unset"}
Causes == {"at_proxy", "elsewhere"}
Texts == {"unread", "default", "proxy"}

VARIABLES caller, proxy, cause, stale, text

vars == <<caller, proxy, cause, stale, text>>

TypeOK ==
    /\ caller \in Callers
    /\ proxy \in Proxies
    /\ cause \in Causes
    /\ stale \in BOOLEAN
    /\ text \in Texts

Init ==
    /\ caller \in Callers
    /\ proxy \in Proxies
    /\ cause \in Causes
    /\ stale \in BOOLEAN
    \* Nothing fails at a proxy that is not set, and nothing is left behind by it.
    /\ (cause = "at_proxy") => (proxy = "set")
    /\ stale => (proxy = "set")
    /\ text = "unread"

AtProxy == proxy = "set" /\ cause = "at_proxy"

\* What this thread holds when the caller reads: the sentence of its own failed
\* connect, or, when nothing clears it at the start of a request, one an earlier
\* request left behind.
Holds ==
    \/ AtProxy
    \/ proxy = "set" /\ stale /\ ~ClearsAtStart

CallerClaims(c) ==
    CASE c = "version" -> VersionClaims
      [] c = "upgrade" -> UpgradeClaims
      [] OTHER -> TRUE

\* The caller shows its text.
Show ==
    /\ text = "unread"
    /\ text' = IF CallerClaims(caller) /\ (Holds \/ (NamesWithoutFailure /\ proxy = "unset"))
                 THEN "proxy"
                 ELSE "default"
    /\ UNCHANGED <<caller, proxy, cause, stale>>

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

\* With no proxy set, no caller names one: its text stays what it is today.
NoProxyKeepsDefault ==
    proxy = "unset" => text # "proxy"

\* With a proxy set, a caller names it only for its own failure at the proxy,
\* never for a sentence an earlier request left behind.
OwnFailureOnly ==
    (proxy = "set" /\ text = "proxy") => cause = "at_proxy"
=============================================================================
