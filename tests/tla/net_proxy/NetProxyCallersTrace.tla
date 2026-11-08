----------------------- MODULE NetProxyCallersTrace -----------------------
(*
Trace validation for NetProxyCallers: whether the model can produce what the
built fx showed when one request failed.

tests/tla/drivers/net_proxy/driver.ts runs zig-out/bin/fx through one request
that fails, such as a Grok version lookup behind a proxy that is down, and
writes what it saw as NetProxyCallersObserved, a module with one record:
  caller  "version" (`fx ask` on a Grok sign-in, ended by its version lookup) or
          "upgrade" (`fx upgrade`)
  proxy   "set" when the run had a proxy variable, else "unset"
  cause   "at_proxy" when the failed request failed at the proxy, else
          "elsewhere"
  text    "proxy" when the error text names the proxy, "default" when it is the
          caller's fixed text

The observation is ACCEPTED when TLC violates NotObserved, and REJECTED when
the search completes, as in NetProxyTrace.
*)
EXTENDS NetProxyCallers, NetProxyCallersObserved

Matches(o) ==
    /\ text # "unread"
    /\ caller = o.caller
    /\ proxy = o.proxy
    /\ cause = o.cause
    /\ text = o.text

\* Sentinel: violated exactly when the model can produce the observation.
NotObserved == ~Matches(ObservedCallers)
=============================================================================
