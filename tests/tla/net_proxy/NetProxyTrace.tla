--------------------------- MODULE NetProxyTrace ---------------------------
(*
Trace validation: whether NetProxy can produce what the built fx did.

tests/tla/drivers/net_proxy/driver.ts runs zig-out/bin/fx through a local
proxy that answers one way, such as a 102 before its 200 or no answer at all
because it is down, and writes what it saw as NetProxyObserved, a module with
one record:
  target  the target the request went to ("routed": an https host NO_PROXY
          does not name)
  answer  what the proxy did, in the model's words
  phase   "sent" when the request went through the tunnel to the provider,
          "failed" when no request reached it
  shown   what the failed request said when it ended: "proxy" when its error
          names the proxy, "none" when it does not, "unread" when it did not
          end
  notice  what the retry notices said: "proxy" when they name the proxy and
          keep their wait part ("next try in", "retrying"), "proxy_cut" when
          they name it but lost the wait part, "generic" when they do not name
          it, "unread" when there were none

The observation is ACCEPTED when TLC violates NotObserved, which holds in a
state exactly when the model reached what fx did. A completed search means
REJECTED: the model, run with the constants the driver passes, cannot do that.
*)
EXTENDS NetProxy, NetProxyObserved

Matches(o) ==
    \E c \in Conns:
        /\ target[c] = o.target
        /\ answer[c] = o.answer
        /\ phase[c] = o.phase
        /\ shown[c] = o.shown
        /\ notice[c] = o.notice

\* Sentinel: violated exactly when the model can produce the observation.
NotObserved == ~Matches(Observed)
=============================================================================
