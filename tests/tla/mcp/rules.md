# MCP-v2 client rules

Every client-side rule from the MCP specification that the MCP-v2 engine
(`src/mcp/`) follows, with the ID that the models in this folder and the
drivers in `../drivers/mcp/` cite.

- **Level:** MUST, MUST NOT, SHOULD, SHOULD NOT, MAY, or INFO (a behavior to
  handle, not a keyword).
- **Source:** the specification version and page, such as
  `2026-07-28_basic_index` for the Basic page of the 2026-07-28 version, and the
  section.
- **Unit:** the part of the engine that owns the rule, as in `catalog.json`.

## Wire format (WIRE)

| ID | Level | Rule | Source | Unit |
| --- | --- | --- | --- | --- |
| WIRE-01 | MUST | A request id is a string or integer, never null, and unique among in-flight requests | `2026-07-28_basic_index` §Requests | U01, U02 |
| WIRE-02 | MUST | Notifications have no id, and the client never responds to one | `2026-07-28_basic_index` §Notifications | U01 |
| WIRE-03 | MUST | Every 2026 request carries `_meta` keys `io.modelcontextprotocol/protocolVersion` and `io.modelcontextprotocol/clientCapabilities` (`{}` means none). Without them the server returns `-32602` (HTTP 400) | `2026-07-28_basic_index` §_meta | U01, U04 |
| WIRE-04 | SHOULD | Send `io.modelcontextprotocol/clientInfo` on every request | `2026-07-28_basic_index` §_meta | U01 |
| WIRE-05 | INFO | `io.modelcontextprotocol/logLevel` is optional and deprecated. Without it the server sends no `notifications/message` | `2026-07-28_changelog` | U01 |
| WIRE-06 | MUST | A `progressToken` is a string or integer, unique across active requests | `2026-07-28_basic_patterns_progress` §Progress Flow | U01, U02 |
| WIRE-07 | MUST | A missing `resultType` means `complete`. An unknown value is invalid | `2026-07-28_basic_index` §ResultType | U01 |
| WIRE-08 | SHOULD NOT | Base behavior or security on `serverInfo` | `2026-07-28_basic_index` §_meta; `2026-07-28_server_discover` | U01, U12 |
| WIRE-09 | MUST | Assign no meaning to codes `-32000` to `-32019`, except `-32002`. SHOULD accept `-32002` from legacy servers | `2026-07-28_basic_index` §Error Codes | U01 |
| WIRE-10 | MUST | Local errors such as timeouts must not be mistakable for errors from the server | `2026-07-28_basic_index` §Error Codes | U01, U02 |
| WIRE-11 | MUST | If the other side lacks an extension, revert to core behavior or reject the request | `2026-07-28_basic_versioning` §Extension Negotiation | U04 |
| WIRE-12 | MUST | Support JSON Schema 2020-12 as the default dialect. MUST NOT auto-fetch a network `$ref`. SHOULD bound composition keywords | `2026-07-28_basic_index` §JSON Schema Usage | U05 |
| WIRE-13 | INFO | Pre-release servers may still send `-32001`, `-32003`, and `-32004` for header mismatch, missing capability, and unsupported version | `2026-07-28_changelog` | U04 |
| WIRE-14 | MUST | Never emit a code from -32020 to -32099 that the spec does not define, and use defined codes only with their meaning. SHOULD NOT use -32000 to -32019 at all | `2026-07-28_basic_index` §Error Codes | U01 |

## Version detection (VER)

| ID | Level | Rule | Source | Unit |
| --- | --- | --- | --- | --- |
| VER-01 | SHOULD | On `-32022`, pick a mutually supported version from `data.supported` and retry, or surface an error if there is none | `2026-07-28_basic_versioning` §Protocol Version Negotiation | U04 |
| VER-02 | MAY | Call `server/discover` before any other request | `2026-07-28_basic_versioning` §Protocol Version Negotiation | U04 |
| VER-03 | SHOULD | A dual-era stdio client probes with `server/discover`. The fallback MUST NOT depend on one specific error code. After a recognized modern error, don't fall back to `initialize` | `2026-07-28_basic_transports_stdio` §Backward Compatibility | U04 |
| VER-04 | SHOULD | Over HTTP, inspect the body of a 400 before falling back | `2026-07-28_basic_transports_streamable-http` §Backward Compatibility | U04, U06 |
| VER-05 | SHOULD | Cache the detected era per process (stdio) or origin (HTTP). MAY persist it. Re-probe if the cached assumption fails | `2026-07-28_basic_versioning` §Backward Compatibility | U04 |
| VER-06 | MUST | Legacy: `initialize` is the first request, and SHOULD offer the latest supported version | `2025-11-25_basic_lifecycle` §Initialization | U04 |
| VER-07 | MUST | Legacy: send `notifications/initialized` after the `initialize` result | `2025-11-25_basic_lifecycle` §Initialization | U04 |
| VER-08 | SHOULD NOT | Legacy: send requests other than ping before the `initialize` response | `2025-11-25_basic_lifecycle` §Initialization | U04 |
| VER-09 | SHOULD | Legacy: disconnect if the returned version isn't supported. Use only negotiated capabilities | `2025-11-25_basic_lifecycle` §Version Negotiation | U04 |
| VER-10 | INFO | A modern-only server should name its supported versions in its error to `initialize` | `2026-07-28_basic_versioning` §Backward Compatibility | U04 |

## stdio (STDIO)

| ID | Level | Rule | Source | Unit |
| --- | --- | --- | --- | --- |
| STDIO-01 | MUST | Write one UTF-8 JSON-RPC message per line, with no embedded newlines and nothing that isn't MCP | `2026-07-28_basic_transports_stdio` (intro); `2026-07-28_basic_transports_index` §Messages | U03 |
| STDIO-02 | MUST NOT | In the 2026 era, write responses to the server | `2026-07-28_basic_transports_stdio` §Sending Messages | U03 |
| STDIO-03 | MUST | Route subscription notifications by `_meta["io.modelcontextprotocol/subscriptionId"]` | `2026-07-28_basic_transports_stdio` §Receiving Messages | U03, U10 |
| STDIO-04 | MUST | Cancel with `notifications/cancelled` | `2026-07-28_basic_transports_stdio` §Cancellation | U02, U03 |
| STDIO-05 | SHOULD NOT | Treat stderr output as an error | `2026-07-28_basic_transports_stdio` (intro) | U03 |
| STDIO-06 | SHOULD | Shut down by closing stdin, waiting, then SIGTERM, then SIGKILL | `2026-07-28_basic_transports_stdio` §Shutdown | U03 |
| STDIO-07 | SHOULD | Restart after a crash. In-flight requests are lost but can be retried | `2026-07-28_basic_transports_stdio` §Unexpected Termination | U03, U12 |
| STDIO-08 | SHOULD NOT | Tie a server process's lifetime to one task or conversation | `2026-07-28_basic_index` §Statelessness | U12 |
| STDIO-09 | MUST | Legacy: answer the server's requests (for example ping and elicitation) | `2025-11-25_basic_lifecycle` §Initialization; `2025-11-25_basic_transports` §stdio | U03, U11 |
| STDIO-10 | INFO | A 2026 server never writes requests to stdout; the client must not answer one | `2026-07-28_basic_transports_stdio` §Receiving Messages | U03 |
| STDIO-11 | MUST | Messages are UTF-8 | `2026-07-28_basic_transports_index` §Messages | U01, U03 |

## New-spec HTTP (HTTP)

| ID | Level | Rule | Source | Unit |
| --- | --- | --- | --- | --- |
| HTTP-01 | MUST | Each message is a new POST with `Accept` listing `application/json` and `text/event-stream`. The body is one request or notification, never a response. Support both JSON and SSE replies | `2026-07-28_basic_transports_streamable-http` §Sending Messages | U06 |
| HTTP-02 | MUST | Every POST carries `MCP-Protocol-Version`, equal to the `_meta` version | `2026-07-28_basic_transports_streamable-http` §Protocol Version Header | U06 |
| HTTP-03 | MUST | `Mcp-Method` equals `method`. `Mcp-Name` equals `params.name` or `params.uri` for `tools/call`, `resources/read`, and `prompts/get` | `2026-07-28_basic_transports_streamable-http` §Standard Request Headers | U06 |
| HTTP-04 | MUST | Send each `x-mcp-header` argument as `Mcp-Param-{Name}`: strings as-is, integers in decimal, booleans as `true` or `false`. Omit it when the value is null or absent | `2026-07-28_basic_transports_streamable-http` §Custom Headers, §Client Behavior | U06 |
| HTTP-05 | MUST | Wrap header values as `=?base64?…?=` when they have characters outside 0x20–0x7E (except tab), leading or trailing whitespace, or already look like that form. This includes `Mcp-Name` | `2026-07-28_basic_transports_streamable-http` §Value Encoding | U06 |
| HTTP-06 | MUST | Exclude tools whose `x-mcp-header` is invalid: empty, not a token, containing CR or LF, a case-insensitive duplicate, on a non-primitive or `number` property, or on a property not reachable only through `properties`. SHOULD warn | `2026-07-28_basic_transports_streamable-http` §Schema Extension; `2026-07-28_server_tools` §x-mcp-header | U05, U06 |
| HTTP-07 | INFO | Header names compare case-insensitively. Values are case-sensitive | `2026-07-28_basic_transports_streamable-http` §Case Sensitivity | U06 |
| HTTP-08 | INFO | Closing a stream cancels that request | `2026-07-28_basic_transports_streamable-http` §Cancellation | U06 |
| HTTP-09 | MUST | If a stream breaks before the response, re-issue the request with a new id | `2026-07-28_changelog` (item 9); `2026-07-28_basic_transports_streamable-http` §Receiving Messages | U06 |
| HTTP-10 | MUST NOT | In 2026, send `Mcp-Session-Id`, GET, DELETE, or `Last-Event-ID` | `2026-07-28_basic_transports_streamable-http` §Earlier Streamable HTTP Revisions | U06 |
| HTTP-11 | INFO | Ignore SSE comment lines starting with `:` | `2026-07-28_basic_transports_streamable-http` §Receiving Messages | U06 |
| HTTP-12 | INFO | A 403 for a bad `Origin` is not an auth problem. A 404 with `-32601` means the method isn't implemented | `2026-07-28_basic_transports_streamable-http` §Security, §Protocol Version Header | U06, U09 |
| HTTP-13 | INFO | Close a request's stream once its final answer is in, even when the server leaves it open: nothing more comes for it, and an open one holds a connection | `2026-07-28_basic_transports_streamable-http` §Receiving Messages ("The final JSON-RPC response SHOULD terminate the stream") | U06 |

## 2025 HTTP sessions (LHTTP)

| ID | Level | Rule | Source | Unit |
| --- | --- | --- | --- | --- |
| LHTTP-01 | MUST | After `initialize`, send `Mcp-Session-Id` on every request if the server assigned one | `2025-11-25_basic_transports` §Session Management | U07 |
| LHTTP-02 | MUST | A 404 on a request that carried a session id means: send a new `initialize` without the session id | `2025-11-25_basic_transports` §Session Management | U07 |
| LHTTP-03 | SHOULD | DELETE the session when done. A 405 is acceptable | `2025-11-25_basic_transports` §Session Management | U07 |
| LHTTP-04 | MUST | Send `MCP-Protocol-Version` with the negotiated version on later requests | `2025-11-25_basic_transports` §Protocol Version Header | U07 |
| LHTTP-05 | MUST | Respect the SSE `retry` value. SHOULD resume with GET and `Last-Event-ID`. SHOULD NOT treat a disconnect as cancellation | `2025-11-25_basic_transports` §Sending Messages, §Resumability and Redelivery | U07 |
| LHTTP-06 | MUST | A GET stream sends `Accept: text/event-stream`. A 405 means the server offers none | `2025-11-25_basic_transports` §Listening | U07 |
| LHTTP-07 | INFO | POSTed notifications and responses get 202. A request's SSE stream may carry server requests before the response | `2025-11-25_basic_transports` §Sending Messages | U07 |
| LHTTP-08 | INFO | Over 2025 HTTP, cancel by POSTing `notifications/cancelled`. A disconnect is not a cancellation (LHTTP-05) | `2025-11-25_basic_transports` §Sending Messages; `2025-11-25_basic_utilities_cancellation` §Cancellation Flow | U07 |
| LHTTP-09 | MUST | Session ids are visible ASCII (0x21 to 0x7E); clients handle them securely | `2025-11-25_basic_transports` §Session Management | U07 |
| LHTTP-10 | INFO | Over 2025 HTTP, close a request's stream once its answer is in, even when the server leaves it open. A disconnect is not a cancellation (LHTTP-05), so this cancels nothing | `2025-11-25_basic_transports` §Sending Messages to the Server ("After the JSON-RPC response has been sent, the server SHOULD terminate the SSE stream") | U07 |

## Requests, cancellation, and progress (REQ)

| ID | Level | Rule | Source | Unit |
| --- | --- | --- | --- | --- |
| REQ-01 | MUST | Cancel only requests the client issued and believes are still in flight | `2026-07-28_basic_patterns_cancellation` §Behavior Requirements | U02 |
| REQ-02 | SHOULD | Ignore a response that arrives after cancelling. MUST handle the race between cancel and response | `2026-07-28_basic_patterns_cancellation` §Behavior Requirements, §Timing | U02 |
| REQ-03 | SHOULD | Set a timeout on every request and cancel when it expires. MAY reset it on progress, but keep a hard maximum | `2026-07-28_basic_patterns_cancellation` §Timeouts; `2026-07-28_server_tools` §Security | U02 |
| REQ-04 | INFO | Progress values increase. Process progress only for tokens of in-flight requests | `2026-07-28_basic_patterns_progress` §Progress Flow | U02 |
| REQ-05 | SHOULD | Ignore invalid cancellation notifications: unknown ids, completed requests, and malformed ones. A server never validly cancels a client-issued request: in 2026 servers send `notifications/cancelled` only to end a `subscriptions/listen` stream, and in 2025 only for requests they issued | `2026-07-28_basic_patterns_cancellation` (intro), §Error Handling; `2025-11-25_basic_utilities_cancellation` §Behavior Requirements | U02, U10 |
| REQ-06 | MUST NOT | (2025) Cancel the `initialize` request, on any transport | `2025-11-25_basic_utilities_cancellation` §Behavior Requirements | U02, U04 |

## Input-required rounds (MRTR)

| ID | Level | Rule | Source | Unit |
| --- | --- | --- | --- | --- |
| MRTR-01 | MUST | Accept `input_required` only for `tools/call`, `prompts/get`, and `resources/read` | `2026-07-28_basic_patterns_mrtr` §Supported Requests | U08 |
| MRTR-02 | MUST | Fulfil every entry in `inputRequests` before retrying. With none, MAY retry immediately | `2026-07-28_basic_patterns_mrtr` §Client Requirements | U08 |
| MRTR-03 | MUST | The retry has a new id, the same method and params, and `inputResponses` with exactly the keys of `inputRequests` | `2026-07-28_basic_patterns_mrtr` §Client Requirements; `schema-2026-07-28.ts` `InputResponseRequestParams` | U08 |
| MRTR-04 | MUST | Echo `requestState` byte for byte without inspecting it, and omit it if the server sent none | `2026-07-28_basic_patterns_mrtr` §Client Requirements | U08 |
| MRTR-05 | MUST NOT | Reuse `inputResponses` or `requestState` on parallel requests | `2026-07-28_basic_patterns_mrtr` §Client Requirements | U08 |
| MRTR-06 | INFO | The server may return `input_required` again, with no limit | `2026-07-28_basic_patterns_mrtr` §Server Requirements | U08 |
| MRTR-07 | MUST | Never cache `input_required` results or MRTR retries | `2026-07-28_server_utilities_caching` §Cache Key | U05, U08 |

## Tools, paging, and cache (CAT)

| ID | Level | Rule | Source | Unit |
| --- | --- | --- | --- | --- |
| CAT-01 | INFO | Cursors are opaque. `""` is not the end. A missing `nextCursor` means the end | `2026-07-28_server_utilities_pagination` | U05 |
| CAT-02 | INFO | An invalid cursor (`-32602`) means restart from the beginning and drop every cached page | `2026-07-28_server_utilities_caching` §Interaction with Pagination | U05 |
| CAT-03 | MUST | Never serve a cache entry for a different method or params. Never share `private` entries across auth contexts | `2026-07-28_server_utilities_caching` | U05 |
| CAT-04 | INFO | An entry is fresh while now < received + `ttlMs`. An absent or negative TTL is 0, and so is every legacy result | `2026-07-28_server_utilities_caching` §TTL | U05 |
| CAT-05 | SHOULD NOT | Poll on TTL. A relevant notification makes an entry stale immediately, and it's re-fetched on next access. Any polling MUST use jitter and backoff | `2026-07-28_server_utilities_caching` | U05 |
| CAT-06 | MUST | Treat tool annotations as untrusted unless the server is trusted | `2026-07-28_server_tools` §Tool | U05, U12 |
| CAT-07 | SHOULD | Validate `structuredContent` against `outputSchema` | `2026-07-28_server_tools` §Output Schema | U05 |
| CAT-08 | SHOULD | Give a result with `isError: true` to the model. MAY give protocol errors (`-32602`, `-32601`) to it | `2026-07-28_server_tools` §Error Handling | U05, U12 |
| CAT-09 | SHOULD | On `-32020`, re-list tools and then retry | `2026-07-28_basic_transports_streamable-http` §Client Behavior | U06 |
| CAT-10 | SHOULD | Resolve name clashes across servers without relying on `serverInfo.name` | `2026-07-28_server_tools` §Tool Names | U12 |
| CAT-11 | INFO | A server's tool list must not vary per connection, so it can be cached per server | `2026-07-28_server_tools` §Capabilities | U05 |
| CAT-12 | MUST | Over Streamable HTTP, drop a tool whose `x-mcp-header` values break the constraints, and SHOULD log its name and why. Other transports MAY ignore `x-mcp-header` | `2026-07-28_server_tools` §x-mcp-header | U06 |
| CAT-13 | SHOULD | Each page is cached on its own; a client that needs a consistent list SHOULD refetch it from the beginning | `2026-07-28_server_utilities_caching` §Interaction with Pagination | U05 |

## Subscriptions (SUBS)

| ID | Level | Rule | Source | Unit |
| --- | --- | --- | --- | --- |
| SUBS-01 | SHOULD | The first message for a listen is `notifications/subscriptions/acknowledged`. Check that the acknowledged filter is a subset of the requested one | `2026-07-28_basic_patterns_subscriptions` §Acknowledgment | U10 |
| SUBS-02 | MUST | Route notifications by `subscriptionId`, which equals the listen request's id | `2026-07-28_basic_patterns_subscriptions` §Receiving Notifications | U10 |
| SUBS-03 | INFO | The server ends a subscription with a result carrying the `subscriptionId`, or with `notifications/cancelled` for the listen id | `2026-07-28_basic_patterns_subscriptions` §Graceful Closure; `2026-07-28_basic_patterns_cancellation` | U10 |
| SUBS-04 | INFO | The client cancels by closing the stream (HTTP) or with `notifications/cancelled` (stdio) | `2026-07-28_basic_patterns_subscriptions` §Cancellation | U10 |
| SUBS-05 | MUST | Re-send each `subscriptions/listen` after a stdio restart | `2026-07-28_basic_patterns_subscriptions` §Graceful Closure; `2026-07-28_basic_transports_stdio` §Unexpected Termination | U03, U10 |

## Authorization (AUTH)

| ID | Level | Rule | Source | Unit |
| --- | --- | --- | --- | --- |
| AUTH-01 | SHOULD | HTTP transports follow this auth spec. stdio SHOULD NOT, and takes credentials from the environment instead | `2026-07-28_basic_authorization_index` §Protocol Requirements | U09 |
| AUTH-02 | MUST | Parse `WWW-Authenticate` and handle 401 | `2026-07-28_basic_authorization_authorization-server-discovery` §Protected Resource Metadata Discovery Requirements | U09 |
| AUTH-03 | MUST | Discover protected resource metadata (RFC 9728). Use the header's `resource_metadata` URL first. Otherwise try `/.well-known/oauth-protected-resource<path>` (skipped when the endpoint is at the root), then `/.well-known/oauth-protected-resource` | `2026-07-28_basic_authorization_authorization-server-discovery` §Protected Resource Metadata Discovery Requirements | U09 |
| AUTH-04 | MUST | The resource metadata lists at least one authorization server | `2026-07-28_basic_authorization_authorization-server-discovery` §Authorization Server Location | U09 |
| AUTH-05 | MUST | Support RFC 8414 and OIDC discovery, in order. Issuer with a path: `/.well-known/oauth-authorization-server/<path>`, then `/.well-known/openid-configuration/<path>`, then `/<path>/.well-known/openid-configuration`. Issuer without a path: `/.well-known/oauth-authorization-server`, then `/.well-known/openid-configuration` | `2026-07-28_basic_authorization_authorization-server-discovery` §Authorization Server Metadata Discovery | U09 |
| AUTH-06 | MUST | (2026) The metadata's `issuer` is identical to the issuer used to build the URL. Otherwise don't use it | `2026-07-28_basic_authorization_authorization-server-discovery` | U09 |
| AUTH-07 | MUST | Refuse to proceed if `code_challenge_methods_supported` is missing. Use S256 | `2026-07-28_basic_authorization_security-considerations` §Authorization Code Protection | U09 |
| AUTH-08 | MUST | (2026) Keep registration state per authorization server, and key stored credentials by issuer. When the issuer changes, don't reuse them and re-register. CIMD ids are portable | `2026-07-28_basic_authorization_authorization-server-discovery` §Authorization Server Location; `2026-07-28_basic_authorization_client-registration` §Authorization Server Binding | U09 |
| AUTH-09 | MUST | Have a client id before starting the flow. SHOULD try pre-registered, then CIMD, then DCR, then ask the user | `2026-07-28_basic_authorization_client-registration` (intro); `2026-07-28_basic_authorization_index` §Client Registration | U09 |
| AUTH-10 | MUST | A CIMD document is served from an HTTPS URL with a path. Its `client_id` equals the document URL, and it contains `client_id`, `client_name`, and `redirect_uris` | `2026-07-28_basic_authorization_client-registration` §Implementation Requirements | U09 |
| AUTH-11 | MUST | (2026) DCR sends `application_type` (SHOULD be `native` for a CLI) and handles rejections. DCR is deprecated | `2026-07-28_basic_authorization_client-registration` §Application Type and Redirect URI Constraints; `2026-07-28_deprecated` | U09 |
| AUTH-12 | MUST | Take scopes from the challenge, else from the resource metadata's `scopes_supported`, else omit `scope`. Assume no relationship between the two, and treat challenge scopes as authoritative | `2026-07-28_basic_authorization_index` §Scope Selection Strategy | U09 |
| AUTH-13 | MUST | (2026) Record the issuer together with the PKCE verifier and `state` before redirecting | `2026-07-28_basic_authorization_index` §Authorization Response Validation | U09 |
| AUTH-14 | MUST | (2026) Check `iss` (RFC 9207) before redeeming the code, by exact string compare with no normalization. On a mismatch, MUST NOT act on or show `error` fields | `2026-07-28_basic_authorization_index` §Authorization Response Validation | U09 |
| AUTH-15 | SHOULD | Use and verify `state` | `2026-07-28_basic_authorization_security-considerations` §Open Redirection | U09 |
| AUTH-16 | MUST | Redirect URIs are localhost or HTTPS. Authorization server endpoints are HTTPS | `2026-07-28_basic_authorization_security-considerations` §Open Redirection, §Communication Security | U09 |
| AUTH-17 | MUST | Send `resource` (the canonical server URI) in both authorization and token requests | `2026-07-28_basic_authorization_index` §Resource Parameter Implementation | U09 |
| AUTH-18 | SHOULD | Use the most specific canonical URI without a trailing slash. Accept an uppercase scheme and host | `2026-07-28_basic_authorization_index` §Canonical Server URI | U09 |
| AUTH-19 | MUST | Send the token in an `Authorization: Bearer` header on every request, never in the query string | `2026-07-28_basic_authorization_index` §Token Requirements | U09 |
| AUTH-20 | MUST NOT | Send a token not issued by this server's authorization server | `2026-07-28_basic_authorization_index` §Token Handling | U09 |
| AUTH-21 | MUST | Store tokens securely, and keep refresh tokens confidential | `2026-07-28_basic_authorization_security-considerations` §Token Theft; `2026-07-28_basic_authorization_index` §Refresh Tokens | U09, U12 |
| AUTH-22 | MUST NOT | Assume a refresh token is returned. MAY request `offline_access` only if the authorization server lists it | `2026-07-28_basic_authorization_index` §Refresh Tokens | U09 |
| AUTH-23 | SHOULD | On 403 `insufficient_scope`, step up with the union of previous and challenged scopes (2026). Limit retries and track attempts | `2026-07-28_basic_authorization_index` §Step-Up Authorization Flow | U09 |
| AUTH-24 | MUST | Follow OAuth 2.1 §7 security considerations | `2026-07-28_basic_authorization_security-considerations` (intro) | U09 |
| AUTH-25 | INFO | Public clients get rotated refresh tokens, so replace the stored one after each refresh | `2026-07-28_basic_authorization_security-considerations` §Token Theft | U09 |
| AUTH-26 | MUST | Refuse an access token that isn't 1*VSCHAR (0x20..0x7E): a token response with one fails the sign-in and nothing is saved, and a saved credential with one is ignored, so no other byte reaches `Authorization` | RFC 6749 appendix A.12 | U09 |
| AUTH-27 | MUST | A refresh answer that names an error, at 200 or a 4xx other than 429, refuses the refresh token for good: both tokens are dropped and the requests waiting need a sign-in, so the dead refresh token is never sent again. A 429, a 5xx, or no answer keeps them | RFC 6749 §5.2; Slack's `oauth.v2.user.access`, which refuses with HTTP 200 and `ok:false` | U09 |

## Elicitation (ELIC)

| ID | Level | Rule | Source | Unit |
| --- | --- | --- | --- | --- |
| ELIC-01 | INFO | The capability is declared in `initialize` (2025) or in each request's `clientCapabilities` (2026) | `2025-11-25_client_elicitation` §Capabilities; `2026-07-28_client_elicitation` §Capabilities | U11 |
| ELIC-02 | MUST | A declared capability supports at least one mode. `{}` means form only. A request without `mode` is form mode | `2026-07-28_client_elicitation` §Capabilities, §Elicitation Requests | U11 |
| ELIC-03 | MUST | (2025) Return `-32602` for a mode the client didn't declare | `2025-11-25_client_elicitation` §Error Handling | U11 |
| ELIC-04 | MUST | Show which server is asking, and give clear decline and cancel options. In form mode, let the user review and edit before sending | `2026-07-28_client_elicitation` §User Interaction Model | U11, U12 |
| ELIC-05 | SHOULD | Validate form responses against the schema, and pre-fill defaults | `2026-07-28_client_elicitation` §Form Mode Security, §Requested Schema | U11 |
| ELIC-06 | MUST | URL mode: never prefetch, never open without explicit consent, show the full URL, and open it where neither the client nor the model can inspect it. SHOULD highlight the domain and warn on Punycode | `2026-07-28_client_elicitation` §Safe URL Handling | U11 |
| ELIC-07 | INFO | In URL mode, `accept` means consent, not completion. SHOULD offer manual retry and cancel | `2026-07-28_client_elicitation` §URL Mode Elicitation Requests | U11 |
| ELIC-08 | MUST | (2025) Ignore completion notifications with an unknown or already-completed `elicitationId` | `2025-11-25_client_elicitation` §Completion Notifications | U11 |
| ELIC-09 | INFO | `content` is present only on `accept` in form mode | `schema-2026-07-28.ts` `ElicitResult` | U11 |

## Security and consent (SEC)

| ID | Level | Rule | Source | Unit |
| --- | --- | --- | --- | --- |
| SEC-01 | MUST | Get the user's consent before invoking any tool. Tool descriptions are untrusted | `2026-07-28_index` §Tool Safety | U12 |
| SEC-02 | MUST | Get the user's consent before exposing user data to a server | `2026-07-28_index` §Data Privacy | U12 |

## Counts

| Group | Rules |
| --- | ---: |
| WIRE | 14 |
| VER | 10 |
| STDIO | 11 |
| HTTP | 13 |
| LHTTP | 10 |
| REQ | 6 |
| MRTR | 7 |
| CAT | 13 |
| SUBS | 5 |
| AUTH | 26 |
| ELIC | 9 |
| SEC | 2 |
| Total | 126 |
