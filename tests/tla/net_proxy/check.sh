#!/bin/sh
# Model-check how fx routes a connection when the proxy variables are set,
# and which request reports a proxy failure (NetProxy.tla;
# src/core/shared/net_proxy.zig and net_proxy_io.zig), with TLC, and require
# each config's expected verdict.
#
# net-proxy.cfg is the design and must pass. net-proxy-today.cfg is fx before
# the connector, which ignores the proxy and connects directly
# (NoDirectWhenRouted). net-proxy-std.cfg is std.http.Client's own proxy path
# on Zig 0.17 (initDefaultProxies): no TLS after CONNECT, no
# Proxy-Authorization on CONNECT, and a shared supports_connect flag that one
# failed CONNECT turns into plain-text forwarding (NoPlainRequest). Each
# net-proxy-mutation-*.cfg plants one defect, and the rule it names must catch
# it:
#
#   fallback-on-failure    a failed CONNECT retries as a forward request      NoPlainRequest
#   no-tls-after-connect   the request goes into the tunnel without TLS       NoPlainRequest
#   fetch-by-name          web_fetch CONNECTs by name, not the admitted IP    NoPrivateReach
#   shared-detail          any request reads a process-wide last failure      DetailBelongsToFailingConnect
#
# tests/tla/drivers/net_proxy/driver.ts walks net_proxy.zig along the design's
# state graph.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu
cd "$(dirname "$0")"
. ../lib/tlc.sh
tlc_verdicts "$@" <<'VERDICTS'
NetProxy net-proxy -
NetProxy net-proxy-today NoDirectWhenRouted
NetProxy net-proxy-std NoPlainRequest
NetProxy net-proxy-mutation-fallback-on-failure NoPlainRequest
NetProxy net-proxy-mutation-no-tls-after-connect NoPlainRequest
NetProxy net-proxy-mutation-fetch-by-name NoPrivateReach
NetProxy net-proxy-mutation-shared-detail DetailBelongsToFailingConnect
VERDICTS
