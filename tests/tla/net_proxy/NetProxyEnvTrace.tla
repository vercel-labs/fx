------------------------- MODULE NetProxyEnvTrace -------------------------
(*
Trace validation for NetProxyEnv: whether the model can produce what the built
fx did with a proxy URL of one host class.

tests/tla/drivers/net_proxy/driver.ts runs zig-out/bin/fx with HTTPS_PROXY set
to a URL of one class and writes what it saw as NetProxyEnvObserved, a module
with one record:
  cls       the host class of the URL ("underscore": http://squid_proxy:3128)
  accepted  whether fx took the URL as a proxy and tried to connect to it
  reason    "none" when it did, else the reason its refusal named

The observation is ACCEPTED when TLC violates NotObserved, and REJECTED when
the search completes, as in NetProxyTrace.
*)
EXTENDS NetProxyEnv, NetProxyEnvObserved

Matches(o) ==
    /\ parsed
    /\ cls = o.cls
    /\ accepted = o.accepted
    /\ reason = o.reason

\* Sentinel: violated exactly when the model can produce the observation.
NotObserved == ~Matches(ObservedEnv)
=============================================================================
