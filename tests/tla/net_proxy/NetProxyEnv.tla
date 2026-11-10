-------------------------- MODULE NetProxyEnv --------------------------
(*
What fx reads from the environment, and what it keeps. net_proxy.parse
(src/core/shared/net_proxy.zig) reads the proxy variables once, at the first
connection by host name, into a snapshot; net_proxy_io.zig keeps it for the
life of the process. The host program may change the environment after that:
the libfx addon runs inside Node.js, which owns it, and libc then reuses or
frees the strings an earlier read pointed at.

The environment:
  rm   REQUEST_METHOD, which a CGI server sets
  up   uppercase HTTP_PROXY      lo   lowercase http_proxy
  hs   HTTPS_PROXY
  ph   the proxy host HTTPS_PROXY names (p1 or p2)
  np   whether NO_PROXY lists the internal host ("lists") or not ("omits")
  cls  the host class of the proxy URL fx parses:
         letters      http://squid-proxy:3128
         underscore   http://squid_proxy:3128
         bang         http://bad_host!:3128
         no_host      http:///path
         bad_port     http://proxy:99999

The snapshot is taken by Snap. The host program may then change ph or np
(SetHost, SetNoProxy). Each connection decides its route from what the
snapshot holds (Route), and the model records in obs what each decision gave:
  http      which variable gave the proxy for a plain http connection to an
            external host ("none", "upper" for HTTP_PROXY, "lower")
  host      the proxy an https connection to an external host tunnels through
            ("none" when it goes direct)
  internal  the route of an https connection to the internal host NO_PROXY
            may list ("direct" or "tunnel")

The constants switch the mechanisms on and off:
  Guard              what a set REQUEST_METHOD ignores. "upper_only": the
                     uppercase HTTP_PROXY, as Go's httpproxy does, because a
                     CGI server turns a request header "Proxy:" into
                     HTTP_PROXY (httpoxy). "none": nothing, as fx did before.
                     "all_http" also ignores http_proxy, and "all" also
                     ignores HTTPS_PROXY.
  BorrowHost         the snapshot keeps a slice of the environment's string
                     for the proxy host, so a changed environment reaches it
  BorrowNoProxy      the snapshot keeps slices of the NO_PROXY string
  AcceptsUnderscore  a proxy host with an underscore is a host (docker-compose
                     service names have them)
  AcceptsBang        a proxy host with a character no host name has is a host
  NamesReasons       a refusal names its real reason
*)
EXTENDS Naturals, FiniteSets

CONSTANTS Guard, BorrowHost, BorrowNoProxy, AcceptsUnderscore, AcceptsBang, NamesReasons

Flags == {"unset", "set"}
Hosts == {"p1", "p2"}
NoProxyValues == {"lists", "omits"}
Classes == {"letters", "underscore", "bang", "no_host", "bad_port"}
Reasons == {"none", "unreadable", "no_host", "bad_host", "bad_port"}

VARIABLES rm, up, lo, hs, ph, np, cls,
          snapped, s_http, s_https, s_host, s_np,
          obs, parsed, accepted, reason

vars == <<rm, up, lo, hs, ph, np, cls, snapped, s_http, s_https, s_host, s_np, obs, parsed, accepted, reason>>

TypeOK ==
    /\ rm \in Flags /\ up \in Flags /\ lo \in Flags /\ hs \in Flags
    /\ ph \in Hosts /\ np \in NoProxyValues /\ cls \in Classes
    /\ snapped \in BOOLEAN
    /\ s_http \in {"none", "upper", "lower"}
    /\ s_https \in {"none", "set"}
    /\ s_host \in Hosts \cup {"none"}
    /\ s_np \in NoProxyValues \cup {"none"}
    /\ parsed \in BOOLEAN /\ accepted \in BOOLEAN /\ reason \in Reasons

Init ==
    /\ rm \in Flags /\ up \in Flags /\ lo \in Flags /\ hs \in Flags
    /\ ph \in Hosts /\ np \in NoProxyValues /\ cls \in Classes
    /\ snapped = FALSE
    /\ s_http = "none" /\ s_https = "none" /\ s_host = "none" /\ s_np = "none"
    /\ obs = {}
    /\ parsed = FALSE /\ accepted = FALSE /\ reason = "none"

\* What a set REQUEST_METHOD makes fx ignore.
Cgi == rm = "set"
UpperIgnored == Cgi /\ Guard \in {"upper_only", "all_http", "all"}
LowerIgnored == Cgi /\ Guard \in {"all_http", "all"}
HttpsIgnored == Cgi /\ Guard = "all"

\* Lowercase wins over uppercase, as in curl.
HttpUsed ==
    IF lo = "set" /\ ~LowerIgnored THEN "lower"
    ELSE IF up = "set" /\ ~UpperIgnored THEN "upper"
    ELSE "none"

Snap ==
    /\ ~snapped
    /\ snapped' = TRUE
    /\ s_http' = HttpUsed
    /\ s_https' = IF hs = "set" /\ ~HttpsIgnored THEN "set" ELSE "none"
    /\ s_host' = IF hs = "set" /\ ~HttpsIgnored THEN ph ELSE "none"
    /\ s_np' = np
    /\ UNCHANGED <<rm, up, lo, hs, ph, np, cls, obs, parsed, accepted, reason>>

\* The host program sets HTTPS_PROXY or NO_PROXY again, to another value.
SetHost ==
    /\ snapped
    /\ ph' \in Hosts \ {ph}
    /\ UNCHANGED <<rm, up, lo, hs, np, cls, snapped, s_http, s_https, s_host, s_np, obs, parsed, accepted, reason>>

SetNoProxy ==
    /\ snapped
    /\ np' \in NoProxyValues \ {np}
    /\ UNCHANGED <<rm, up, lo, hs, ph, cls, snapped, s_http, s_https, s_host, s_np, obs, parsed, accepted, reason>>

\* A connection decides its route. A borrowed field reads the live
\* environment, which the host program may have changed since the snapshot.
Route ==
    /\ snapped
    /\ obs' = obs \cup {[http |-> s_http,
                         host |-> IF s_https = "none" THEN "none" ELSE IF BorrowHost THEN ph ELSE s_host,
                         internal |-> IF s_https = "none" THEN "direct"
                                      ELSE IF (IF BorrowNoProxy THEN np ELSE s_np) = "lists" THEN "direct"
                                      ELSE "tunnel"]}
    /\ UNCHANGED <<rm, up, lo, hs, ph, np, cls, snapped, s_http, s_https, s_host, s_np, parsed, accepted, reason>>

\* Why fx cannot use an input, in the words of its message.
RealReason(c) ==
    CASE c = "no_host" -> "no_host"
      [] c = "bad_port" -> "bad_port"
      [] OTHER -> "bad_host"

Accepts(c) ==
    CASE c = "letters" -> TRUE
      [] c = "underscore" -> AcceptsUnderscore
      [] c = "bang" -> AcceptsBang
      [] OTHER -> FALSE

\* fx reads the proxy URL: it takes the host or refuses with a reason.
Parse ==
    /\ ~parsed
    /\ parsed' = TRUE
    /\ accepted' = Accepts(cls)
    /\ reason' = IF Accepts(cls) THEN "none"
                 ELSE IF NamesReasons THEN RealReason(cls)
                 ELSE "unreadable"
    /\ UNCHANGED <<rm, up, lo, hs, ph, np, cls, snapped, s_http, s_https, s_host, s_np, obs>>

Next == Snap \/ SetHost \/ SetNoProxy \/ Route \/ Parse

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* The proxy host a connection uses is the one the snapshot read, however the
\* environment changed since.
HostStable == \A o \in obs: o.host = s_host

\* A NO_PROXY match is decided by the list the snapshot read.
NoProxyStable ==
    \A o \in obs: o.internal = IF s_https = "none" \/ s_np = "lists" THEN "direct" ELSE "tunnel"

\* With REQUEST_METHOD set, an uppercase HTTP_PROXY is never the proxy.
NoCgiUpper == s_http = "upper" => rm = "unset"

\* The guard leaves lowercase http_proxy alone, as Go's does.
LowerStillApplies == (snapped /\ lo = "set") => s_http = "lower"

\* The guard leaves HTTPS_PROXY alone: only HTTP_PROXY is the CGI risk.
HttpsIgnoresCgi == (snapped /\ hs = "set") => s_https = "set"

\* A proxy host with an underscore is a host.
UnderscoreAccepted == (parsed /\ cls = "underscore") => accepted

\* A host no host name can be is refused.
BadInputRefused == (parsed /\ cls \in {"bang", "no_host", "bad_port"}) => ~accepted

\* A refusal names the reason it has, and not another.
RefusalNamesRealReason == (parsed /\ ~accepted) => reason = RealReason(cls)
=============================================================================
