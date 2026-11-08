#!/bin/sh
# Model-check how fx routes a connection when the proxy variables are set,
# which request reports a proxy failure, and what it reads from the
# environment and keeps (NetProxy.tla and NetProxyEnv.tla;
# src/core/shared/net_proxy.zig and net_proxy_io.zig), with TLC, and require
# each config's expected verdict.
#
# NetProxy.tla, the connections. net-proxy.cfg is the design and must pass.
# net-proxy-today.cfg is fx before the connector, which ignores the proxy and
# connects directly (NoDirectWhenRouted). net-proxy-std.cfg is
# std.http.Client's own proxy path on Zig 0.17 (initDefaultProxies): no TLS
# after CONNECT, no Proxy-Authorization on CONNECT, and a shared
# supports_connect flag that one failed CONNECT turns into plain-text
# forwarding (NoPlainRequest). net-proxy-refuses-interim.cfg and
# net-proxy-generic-notice.cfg are the connector as first written: any 1xx head
# ends the CONNECT as a refusal (InterimOpens), and a retried failure says only
# that the network is down (RetryNoticeNamesProxy). net-proxy-full-notice.cfg is
# the connector as pushed before the short notice: the retry notice carries the
# whole sentence, which a 502's is too long to fit beside "next try in" and
# "retrying" in the 95 bytes of a status text (NoticeKeepsWait). The design
# shortens the notice to host:port and the cause in at most 48 bytes, cutting a
# 253-byte host, and passes with LongHost = TRUE. Each net-proxy-mutation-*.cfg
# plants one defect, and the rule it names must catch it:
#
#   fallback-on-failure    a failed CONNECT retries as a forward request      NoPlainRequest
#   no-tls-after-connect   the request goes into the tunnel without TLS       NoPlainRequest
#   fetch-by-name          web_fetch CONNECTs by name, not the admitted IP    NoPrivateReach
#   shared-detail          any request reads a process-wide last failure      DetailBelongsToFailingConnect
#   skip-switching         a 101 is skipped as if it were interim             SwitchingRefused
#   shared-notice          a retry notice reads another request's failure     NoticeNamesOwnTarget
#   short-uncut            the short notice does not cut a 253-byte host      NoticeKeepsWait
#
# NetProxyEnv.tla, the environment. net-proxy-env.cfg is the design and must
# pass. The configs without a mutation name are the connector as first
# written, one law each: the proxy host and the NO_PROXY text are slices of
# the environment, so a changed environment reaches them (HostStable,
# NoProxyStable); an uppercase HTTP_PROXY is used when REQUEST_METHOD is set
# (NoCgiUpper); a proxy host with an underscore is refused (UnderscoreAccepted);
# every refusal says the same thing (RefusalNamesRealReason).
#
#   guard-lower            the CGI guard also ignores http_proxy              LowerStillApplies
#   guard-https            the CGI guard also ignores HTTPS_PROXY             HttpsIgnoresCgi
#   accept-bang            a host with a character no host has is accepted    BadInputRefused
#
# NetProxyCallers.tla, who names a proxy failure in the text it shows.
# net-proxy-callers.cfg is the design and must pass: the model request, a Grok
# version lookup, and a request of fx upgrade each name the proxy whose failure
# ended them, and no caller names a proxy when none is set. The configs
# without a mutation name are fx before the callers took the sentence, one law
# each: error.ProviderVersionUnavailable is not an error the claim accepts, so
# the version lookup shows fixed text (VersionNamesProxy); fx upgrade turns
# every request error into fixed text (UpgradeNamesProxy).
#
#   mutation-stale        a request does not clear what an earlier one left      OwnFailureOnly
#   mutation-fixed-text   a caller prints a proxy sentence with no proxy set     NoProxyKeepsDefault
#
# tests/tla/drivers/net_proxy/driver.ts walks net_proxy.zig along the first two
# models' state graphs, and runs the built fx through a proxy that sends 102
# before its 200, a proxy that is down, a proxy host with an underscore, a Grok
# version lookup, and fx upgrade, with TLC checking what it saw against the
# design.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu
cd "$(dirname "$0")"
. ../lib/tlc.sh
tlc_verdicts "$@" <<'VERDICTS'
NetProxy net-proxy -
NetProxy net-proxy-today NoDirectWhenRouted
NetProxy net-proxy-std NoPlainRequest
NetProxy net-proxy-refuses-interim InterimOpens
NetProxy net-proxy-generic-notice RetryNoticeNamesProxy
NetProxy net-proxy-full-notice NoticeKeepsWait
NetProxy net-proxy-mutation-fallback-on-failure NoPlainRequest
NetProxy net-proxy-mutation-no-tls-after-connect NoPlainRequest
NetProxy net-proxy-mutation-fetch-by-name NoPrivateReach
NetProxy net-proxy-mutation-shared-detail DetailBelongsToFailingConnect
NetProxy net-proxy-mutation-skip-switching SwitchingRefused
NetProxy net-proxy-mutation-shared-notice NoticeNamesOwnTarget
NetProxy net-proxy-mutation-short-uncut NoticeKeepsWait
NetProxyEnv net-proxy-env -
NetProxyEnv net-proxy-env-borrowed-host HostStable
NetProxyEnv net-proxy-env-borrowed-no-proxy NoProxyStable
NetProxyEnv net-proxy-env-no-guard NoCgiUpper
NetProxyEnv net-proxy-env-refuses-underscore UnderscoreAccepted
NetProxyEnv net-proxy-env-generic-reasons RefusalNamesRealReason
NetProxyEnv net-proxy-env-mutation-guard-lower LowerStillApplies
NetProxyEnv net-proxy-env-mutation-guard-https HttpsIgnoresCgi
NetProxyEnv net-proxy-env-mutation-accept-bang BadInputRefused
NetProxyCallers net-proxy-callers -
NetProxyCallers net-proxy-callers-no-version VersionNamesProxy
NetProxyCallers net-proxy-callers-no-upgrade UpgradeNamesProxy
NetProxyCallers net-proxy-callers-mutation-stale OwnFailureOnly
NetProxyCallers net-proxy-callers-mutation-fixed-text NoProxyKeepsDefault
VERDICTS
