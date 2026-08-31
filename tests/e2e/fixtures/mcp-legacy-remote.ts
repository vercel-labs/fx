export const LEGACY_REMOTE_TOOL_RESULT = "LEGACY_REMOTE_TOOL_RESULT";
export const LEGACY_SSE_TOOL_RESULT = "LEGACY_SSE_TOOL_RESULT";

export type LegacyStreamableVersion =
  | "2025-11-25"
  | "2025-06-18"
  | "2025-03-26";

export type LegacyRequest = {
  httpMethod: string;
  path: string;
  headers: Record<string, string>;
  message?: {
    id?: number;
    method?: string;
    params?: Record<string, any>;
    result?: Record<string, any>;
    error?: Record<string, any>;
  };
};

export type LegacyUrlRequiredOperation = "tools" | "resources" | "prompts";

type StreamableMode =
  | "normal"
  | "mixed_delimiters"
  | "unsafe_resume_id"
  | "resume"
  | "poll"
  | "hold_open_call"
  | "stall_call"
  | "expire_session"
  | "elicitation_form"
  | "elicitation_url"
  | "url_required_error";

export function startLegacyStreamableHttpFixture(
  version: LegacyStreamableVersion,
  options: {
    mode?: StreamableMode;
    session?: boolean;
    deleteStatus?: 204 | 405;
    invalidModernHeaderSchema?: boolean;
    rejectToolAuth?: boolean;
    listChanged?: boolean;
    features?: boolean;
    elicitationUrl?: string;
    urlRequiredOperation?: LegacyUrlRequiredOperation;
    completeBeforeElicitationResponse?: boolean;
    manualUrlCompletion?: boolean;
    initializeSse?: boolean;
    sdkDiscoveryError?:
      | "uninitialized"
      | "unsupported-version"
      | "unsupported-version-string-id";
  } = {},
) {
  const mode = options.mode ?? "normal";
  const usesSession = options.session !== false;
  const requests: LegacyRequest[] = [];
  let cancelledCalls = 0;
  let cancellationNotifications = 0;
  let deleteCalls = 0;
  let initializeCalls = 0;
  let resumeCalls = 0;
  let toolCallCalls = 0;
  let toolsListCalls = 0;
  let resourcesListCalls = 0;
  let resourceReadCalls = 0;
  let promptGetCalls = 0;
  let listenerCancellations = 0;
  const elicitationResponses: Array<Record<string, any>> = [];
  const urlCompletionQueue: Array<Record<string, unknown>> = [];
  let elicitationIssued = false;
  let urlCompletionFramesSent = 0;
  let currentToolName = "echo";
  const urlRequiredOperation = options.urlRequiredOperation ?? "tools";

  function urlRequiredResponse(id: number | undefined): Response {
    return Response.json({
      jsonrpc: "2.0",
      id,
      error: {
        code: -32042,
        message: "URL elicitation required",
        data: {
          elicitations: [{
            mode: "url",
            message: "Authorize the legacy operation",
            url: options.elicitationUrl ?? "https://example.test/authorize",
            elicitationId: "legacy-url-required-1",
          }],
        },
      },
    });
  }

  const server = Bun.serve({
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const headers = Object.fromEntries(request.headers.entries());
      if (request.method === "DELETE") {
        requests.push({
          httpMethod: request.method,
          path: url.pathname,
          headers,
        });
        deleteCalls += 1;
        return new Response(null, { status: options.deleteStatus ?? 204 });
      }
      if (request.method === "GET") {
        requests.push({
          httpMethod: request.method,
          path: url.pathname,
          headers,
        });
        resumeCalls += 1;
        if (mode === "url_required_error") {
          let active = true;
          return new Response(
            new ReadableStream({
              async start(controller) {
                const encoder = new TextEncoder();
                while (active) {
                  const notification = urlCompletionQueue.shift();
                  if (notification) {
                    controller.enqueue(encoder.encode(
                      `data: ${JSON.stringify(notification)}\n\n`,
                    ));
                  } else {
                    await Bun.sleep(5);
                  }
                }
              },
              cancel() {
                active = false;
                listenerCancellations += 1;
              },
            }),
            { headers: { "content-type": "text/event-stream" } },
          );
        }
        if (mode === "elicitation_url") {
          let active = true;
          return new Response(
            new ReadableStream({
              async start(controller) {
                const encoder = new TextEncoder();
                if (options.manualUrlCompletion) {
                  while (active) {
                    const notification = urlCompletionQueue.shift();
                    if (notification) {
                      controller.enqueue(encoder.encode(
                        `data: ${JSON.stringify(notification)}\n\n`,
                      ));
                      urlCompletionFramesSent += 1;
                    } else {
                      await Bun.sleep(5);
                    }
                  }
                  return;
                }
                const deadline = Date.now() + 5_000;
                while (
                  !(options.completeBeforeElicitationResponse
                    ? elicitationIssued
                    : elicitationResponses.length > 0) &&
                  Date.now() < deadline
                ) {
                  await Bun.sleep(10);
                }
                if (
                  !active ||
                  (options.completeBeforeElicitationResponse
                    ? !elicitationIssued
                    : elicitationResponses.length === 0)
                ) return;
                for (const elicitationId of [
                  "unknown-legacy-url",
                  "legacy-url-1",
                  "legacy-url-1",
                ]) {
                  controller.enqueue(encoder.encode(
                    `data: ${JSON.stringify({
                      jsonrpc: "2.0",
                      method: "notifications/elicitation/complete",
                      params: { elicitationId },
                    })}\n\n`,
                  ));
                  urlCompletionFramesSent += 1;
                }
              },
              cancel() {
                active = false;
                listenerCancellations += 1;
              },
            }),
            { headers: { "content-type": "text/event-stream" } },
          );
        }
        if (options.listChanged) {
          let active = true;
          return new Response(
            new ReadableStream({
              async start(controller) {
                await Bun.sleep(50);
                if (!active) return;
                currentToolName = "fresh";
                const encoder = new TextEncoder();
                controller.enqueue(encoder.encode(
                  `id: list-change-${resumeCalls}\ndata: ${JSON.stringify({
                    jsonrpc: "2.0",
                    method: "notifications/tools/list_changed",
                    params: {},
                  })}\n\n`,
                ));
                if (options.features) {
                  const deadline = Date.now() + 2_000;
                  while (resourcesListCalls === 0 && Date.now() < deadline) {
                    await Bun.sleep(10);
                  }
                  if (!active || resourcesListCalls === 0) return;
                  controller.enqueue(encoder.encode(
                    `id: resources-change-${resumeCalls}\ndata: ${JSON.stringify({
                      jsonrpc: "2.0",
                      method: "notifications/resources/list_changed",
                      params: {},
                    })}\n\n`,
                  ));
                  controller.enqueue(encoder.encode(
                    `id: prompts-change-${resumeCalls}\ndata: ${JSON.stringify({
                      jsonrpc: "2.0",
                      method: "notifications/prompts/list_changed",
                      params: {},
                    })}\n\n`,
                  ));
                }
              },
              cancel() {
                active = false;
                listenerCancellations += 1;
              },
            }),
            { headers: { "content-type": "text/event-stream" } },
          );
        }
        return sseResponse([
          {
            id: `resume-${resumeCalls}`,
            data: toolCallResponse(4, "resumed"),
          },
        ], true);
      }

      const message = await request.json() as LegacyRequest["message"];
      requests.push({
        httpMethod: request.method,
        path: url.pathname,
        headers,
        message,
      });

      if (
        message!.id === 9001 &&
        (message!.result !== undefined || message!.error !== undefined)
      ) {
        elicitationResponses.push(message as Record<string, any>);
        return new Response(null, { status: 202 });
      }

      if (message!.method === "server/discover") {
        if (options.sdkDiscoveryError) {
          return Response.json({
            jsonrpc: "2.0",
            id: options.sdkDiscoveryError === "unsupported-version-string-id"
              ? "server-error"
              : null,
            error: {
              code: options.sdkDiscoveryError === "unsupported-version-string-id"
                ? -32600
                : -32000,
              message: options.sdkDiscoveryError === "uninitialized"
                ? "Server not initialized"
                : options.sdkDiscoveryError === "unsupported-version-string-id"
                  ? "Bad Request: Unsupported protocol version: 2026-07-28. Supported versions: 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25"
                  : "Bad Request: Unsupported protocol version: 2026-07-28",
            },
          }, { status: 400 });
        }
        return new Response(null, { status: 404 });
      }
      if (message!.method === "notifications/initialized") {
        return new Response(null, { status: 202 });
      }
      if (message!.method === "notifications/cancelled") {
        cancellationNotifications += 1;
        return new Response(null, { status: 202 });
      }
      if (message!.method === "initialize") {
        initializeCalls += 1;
        let sessionId: string | null = null;
        if (usesSession) {
          sessionId = mode === "expire_session"
            ? `session-${version}-${initializeCalls}`
            : `session-${version}`;
        }
        const initializeResponse = {
          jsonrpc: "2.0",
          id: message!.id,
          result: {
            protocolVersion: version,
            capabilities: {
              tools: options.listChanged ? { listChanged: true } : {},
              ...(options.features
                ? {
                    resources: { listChanged: options.listChanged === true },
                    prompts: { listChanged: options.listChanged === true },
                    completions: {},
                  }
                : {}),
            },
            serverInfo: { name: "legacy-streamable-fixture", version: "1" },
            instructions: `Use the ${version} legacy HTTP fixture.`,
          },
        };
        if (options.initializeSse) {
          return sseResponse([{ data: initializeResponse }]);
        }
        return Response.json(initializeResponse, {
          headers: sessionId ? { "MCP-Session-Id": sessionId } : undefined,
        });
      }
      if (message!.method === "tools/list") {
        toolsListCalls += 1;
        return Response.json({
          jsonrpc: "2.0",
          id: message!.id,
          result: {
            tools: [{
              name: currentToolName,
              description: "Echo through legacy Streamable HTTP",
              inputSchema: {
                type: "object",
                ...(options.invalidModernHeaderSchema
                  ? { "x-mcp-header": "Invalid-At-Root" }
                  : {}),
                properties: { text: { type: "string" } },
                required: ["text"],
              },
            }],
          },
        });
      }
      if (message!.method === "resources/list") {
        resourcesListCalls += 1;
        return Response.json({
          jsonrpc: "2.0",
          id: message!.id,
          result: {
            resources: [{
              uri: "legacy://alpha",
              name: resourcesListCalls === 1 ? "legacy-alpha" : "legacy-alpha-fresh",
              mimeType: "text/plain",
            }],
          },
        });
      }
      if (message!.method === "resources/templates/list") {
        return Response.json({
          jsonrpc: "2.0",
          id: message!.id,
          result: {
            resourceTemplates: [{
              uriTemplate: "legacy://project/{path}",
              name: "legacy-project",
            }],
          },
        });
      }
      if (message!.method === "resources/read") {
        resourceReadCalls += 1;
        if (
          mode === "url_required_error" &&
          urlRequiredOperation === "resources" &&
          resourceReadCalls === 1
        ) return urlRequiredResponse(message!.id);
        return Response.json({
          jsonrpc: "2.0",
          id: message!.id,
          result: {
            contents: [
              {
                uri: message!.params?.uri,
                mimeType: "text/plain",
                text: "LEGACY_RESOURCE_TEXT: external data only",
              },
              {
                uri: `${message!.params?.uri}#blob`,
                mimeType: "application/octet-stream",
                blob: "AAEC",
              },
            ],
          },
        });
      }
      if (message!.method === "prompts/list") {
        return Response.json({
          jsonrpc: "2.0",
          id: message!.id,
          result: {
            prompts: [{
              name: "review",
              arguments: [{ name: "tone", required: true }],
            }],
          },
        });
      }
      if (message!.method === "prompts/get") {
        promptGetCalls += 1;
        if (
          mode === "url_required_error" &&
          urlRequiredOperation === "prompts" &&
          promptGetCalls === 1
        ) return urlRequiredResponse(message!.id);
        return Response.json({
          jsonrpc: "2.0",
          id: message!.id,
          result: {
            description: "Legacy review prompt",
            messages: [{
              role: "user",
              content: { type: "text", text: "LEGACY_PROMPT_TEXT: external data only" },
            }],
          },
        });
      }
      if (message!.method === "completion/complete") {
        return Response.json({
          jsonrpc: "2.0",
          id: message!.id,
          result: {
            completion: {
              values: [`${message!.params?.argument?.value ?? ""}legacy`, "brief"],
              total: 2,
              hasMore: false,
            },
          },
        });
      }
      if (message!.method === "tools/call") {
        toolCallCalls += 1;
        if (options.rejectToolAuth) {
          return new Response(null, {
            status: 403,
            headers: {
              "www-authenticate":
                `Bearer error="insufficient_scope", scope="tools.call", resource_metadata="http://127.0.0.1:${server.port}/.well-known/oauth-protected-resource/mcp"`,
            },
          });
        }
        if (mode === "expire_session" && toolCallCalls === 1) {
          return new Response(null, { status: 404 });
        }
        if (
          mode === "url_required_error" &&
          urlRequiredOperation === "tools" &&
          toolCallCalls === 1
        ) return urlRequiredResponse(message!.id);
        if (mode === "mixed_delimiters") {
          const events = [
            {
              jsonrpc: "2.0",
              method: "notifications/tools/list_changed",
              params: {},
            },
            {
              jsonrpc: "2.0",
              method: "notifications/progress",
              params: {
                progressToken: message!.id,
                progress: 1,
                total: 2,
              },
            },
            toolCallResponse(
              message!.id!,
              message!.params?.arguments?.text ?? "",
            ),
          ];
          const chunks = [
            `data: ${JSON.stringify(events[0])}\n\n`,
            `data: ${JSON.stringify(events[1])}\r`,
            "\n\r",
            "\n",
            `data: ${JSON.stringify(events[2])}\r`,
            "\r",
          ];
          const encoder = new TextEncoder();
          return new Response(
            new ReadableStream({
              async start(controller) {
                for (const chunk of chunks) {
                  controller.enqueue(encoder.encode(chunk));
                  await Bun.sleep(5);
                }
              },
              cancel() {
                cancelledCalls += 1;
              },
            }),
            { headers: { "content-type": "text/event-stream" } },
          );
        }
        if (mode === "unsafe_resume_id") {
          return sseResponse([{
            id: "unsafe\u0001id",
            data: {
              jsonrpc: "2.0",
              method: "notifications/progress",
              params: {
                progressToken: message!.id,
                progress: 1,
                total: 2,
              },
            },
          }]);
        }
        if (mode === "resume") {
          return sseResponse([
            {
              id: "call-event-1",
              data: {
                jsonrpc: "2.0",
                method: "notifications/progress",
                params: {
                  progressToken: message!.id,
                  progress: 1,
                  total: 2,
                },
              },
            },
          ]);
        }
        if (mode === "poll") {
          return new Response("id:\ndata:\n\n", {
            headers: { "content-type": "text/event-stream" },
          });
        }
        if (mode === "hold_open_call") {
          return new Response(
            new ReadableStream({
              start(controller) {
                controller.enqueue(
                  new TextEncoder().encode(
                    `data: ${
                      JSON.stringify(
                        toolCallResponse(
                          message!.id!,
                          message!.params?.arguments?.text ?? "",
                        ),
                      )
                    }\n\n`,
                  ),
                );
              },
              cancel() {
                cancelledCalls += 1;
              },
            }),
            { headers: { "content-type": "text/event-stream" } },
          );
        }
        if (mode === "stall_call") {
          return new Response(
            new ReadableStream({
              start(controller) {
                controller.enqueue(new TextEncoder().encode(": waiting\n\n"));
              },
              cancel() {
                cancelledCalls += 1;
              },
            }),
            { headers: { "content-type": "text/event-stream" } },
          );
        }
        if (mode === "elicitation_form" || mode === "elicitation_url") {
          const encoder = new TextEncoder();
          return new Response(
            new ReadableStream({
              async start(controller) {
                controller.enqueue(encoder.encode(
                  `data: ${JSON.stringify({
                    jsonrpc: "2.0",
                    id: 9001,
                    method: "elicitation/create",
                    params: mode === "elicitation_url"
                      ? {
                          mode: "url",
                          message: "Authorize the legacy operation",
                          url: options.elicitationUrl ?? "https://example.test/authorize",
                          elicitationId: "legacy-url-1",
                        }
                      : {
                          message: "Confirm the legacy operation",
                          requestedSchema: {
                            type: "object",
                            properties: { confirmed: { type: "boolean" } },
                            required: ["confirmed"],
                            additionalProperties: false,
                          },
                        },
                  })}\n\n`,
                ));
                elicitationIssued = true;
                const deadline = Date.now() + 5_000;
                while (elicitationResponses.length === 0 && Date.now() < deadline) {
                  await Bun.sleep(10);
                }
                if (elicitationResponses.length === 0) {
                  controller.error(new Error("legacy elicitation response timed out"));
                  return;
                }
                controller.enqueue(encoder.encode(
                  `data: ${JSON.stringify(toolCallResponse(
                    message!.id!,
                    message!.params?.arguments?.text ?? "",
                  ))}\n\n`,
                ));
                controller.close();
              },
            }),
            { headers: { "content-type": "text/event-stream" } },
          );
        }
        return Response.json(
          toolCallResponse(
            message!.id!,
            message!.params?.arguments?.text ?? "",
          ),
        );
      }
      return Response.json({
        jsonrpc: "2.0",
        id: message!.id,
        error: { code: -32601, message: "Method not found" },
      });
    },
  });

  return {
    version,
    url: `http://127.0.0.1:${server.port}/mcp`,
    requests,
    get cancelledCalls() {
      return cancelledCalls;
    },
    get cancellationNotifications() {
      return cancellationNotifications;
    },
    get deleteCalls() {
      return deleteCalls;
    },
    get initializeCalls() {
      return initializeCalls;
    },
    get resumeCalls() {
      return resumeCalls;
    },
    get toolCallCalls() {
      return toolCallCalls;
    },
    get toolsListCalls() {
      return toolsListCalls;
    },
    get resourcesListCalls() {
      return resourcesListCalls;
    },
    get resourceReadCalls() {
      return resourceReadCalls;
    },
    get promptGetCalls() {
      return promptGetCalls;
    },
    get listenerCancellations() {
      return listenerCancellations;
    },
    get elicitationResponses() {
      return elicitationResponses;
    },
    get urlCompletionFramesSent() {
      return urlCompletionFramesSent;
    },
    get currentToolName() {
      return currentToolName;
    },
    sendUrlCompletion(elicitationId: string) {
      urlCompletionQueue.push({
        jsonrpc: "2.0",
        method: "notifications/elicitation/complete",
        params: { elicitationId },
      });
    },
    sendUrlCompletionFrame(notification: Record<string, unknown>) {
      urlCompletionQueue.push(notification);
    },
    stop() {
      server.stop(true);
    },
  };
}

export function startLegacyHttpSseFixture(
  options: {
    stallCall?: boolean;
    protocolVersion?: string | null;
    malformedAfterEndpoint?: boolean;
    rejectToolAuth?: boolean;
    bareCr?: boolean;
    listChanged?: boolean;
  } = {},
) {
  const requests: LegacyRequest[] = [];
  let streamController: ReadableStreamDefaultController<Uint8Array> | null = null;
  let streamCancelled = 0;
  let cancellationNotifications = 0;
  let discoveryGets = 0;
  let toolsListCalls = 0;
  let currentToolName = "echo";
  const encoder = new TextEncoder();
  const delimiter = options.bareCr ? "\r" : "\n";

  const server = Bun.serve({
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const headers = Object.fromEntries(request.headers.entries());
      if (request.method === "GET" && url.pathname === "/sse") {
        discoveryGets += 1;
        requests.push({
          httpMethod: request.method,
          path: url.pathname,
          headers,
        });
        return new Response(
          new ReadableStream({
            start(controller) {
              streamController = controller;
              controller.enqueue(
                encoder.encode(
                  `event: endpoint${delimiter}data: /messages${delimiter}${delimiter}` +
                    (options.malformedAfterEndpoint
                      ? `event: message${delimiter}data: not-json${delimiter}${delimiter}`
                      : ""),
                ),
              );
            },
            cancel() {
              streamCancelled += 1;
              streamController = null;
            },
          }),
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      if (request.method !== "POST" || url.pathname !== "/messages") {
        return new Response(null, { status: 404 });
      }

      const message = await request.json() as LegacyRequest["message"];
      requests.push({
        httpMethod: request.method,
        path: url.pathname,
        headers,
        message,
      });
      if (message!.method === "notifications/initialized") {
        return new Response(null, { status: 202 });
      }
      if (message!.method === "notifications/cancelled") {
        cancellationNotifications += 1;
        return new Response(null, { status: 202 });
      }
      if (message!.method === "tools/call" && options.rejectToolAuth) {
        return new Response(null, {
          status: 403,
          headers: {
            "www-authenticate":
              `Bearer error="insufficient_scope", scope="tools.call", resource_metadata="http://127.0.0.1:${server.port}/.well-known/oauth-protected-resource/mcp"`,
          },
        });
      }

      const response = (() => {
        if (message!.method === "initialize") {
          const protocolVersion = options.protocolVersion === undefined
            ? "2024-11-05"
            : options.protocolVersion;
          return {
            jsonrpc: "2.0",
            id: message!.id,
            result: {
              ...(protocolVersion === null ? {} : { protocolVersion }),
              capabilities: { tools: options.listChanged ? { listChanged: true } : {} },
              serverInfo: { name: "legacy-sse-fixture", version: "1" },
              instructions: "Use the explicit HTTP+SSE fixture.",
            },
          };
        }
        if (message!.method === "tools/list") {
          toolsListCalls += 1;
          return {
            jsonrpc: "2.0",
            id: message!.id,
            result: {
              tools: [{
                name: currentToolName,
                description: "Echo through deprecated HTTP+SSE",
                inputSchema: {
                  type: "object",
                  properties: { text: { type: "string" } },
                  required: ["text"],
                },
              }],
            },
          };
        }
        if (message!.method === "tools/call") {
          if (options.stallCall) return null;
          return {
            jsonrpc: "2.0",
            id: message!.id,
            result: {
              content: [{
                type: "text",
                text: `${LEGACY_SSE_TOOL_RESULT}:${message!.params?.arguments?.text ?? ""}`,
              }],
            },
          };
        }
        return null;
      })();
      if (response) {
        streamController?.enqueue(
          encoder.encode(
            `event: message${delimiter}data: ${
              JSON.stringify(response)
            }${delimiter}${delimiter}`,
          ),
        );
        if (options.listChanged && message!.method === "tools/list" && toolsListCalls === 1) {
          setTimeout(() => {
            currentToolName = "fresh";
            streamController?.enqueue(
              encoder.encode(
                `event: message${delimiter}data: ${JSON.stringify({
                  jsonrpc: "2.0",
                  method: "notifications/tools/list_changed",
                  params: {},
                })}${delimiter}${delimiter}`,
              ),
            );
          }, 50);
        }
      }
      return new Response(null, { status: 202 });
    },
  });

  return {
    url: `http://127.0.0.1:${server.port}/sse`,
    requests,
    get discoveryGets() {
      return discoveryGets;
    },
    get streamCancelled() {
      return streamCancelled;
    },
    get cancellationNotifications() {
      return cancellationNotifications;
    },
    get toolsListCalls() {
      return toolsListCalls;
    },
    get currentToolName() {
      return currentToolName;
    },
    stop() {
      streamController?.close();
      streamController = null;
      server.stop(true);
    },
  };
}

function toolCallResponse(id: number, text: string) {
  return {
    jsonrpc: "2.0",
    id,
    result: {
      content: [{
        type: "text",
        text: `${LEGACY_REMOTE_TOOL_RESULT}:${text}`,
      }],
    },
  };
}

function sseResponse(
  events: Array<{ id?: string; data: unknown }>,
  keepOpen = false,
) {
  const body = events.map((event) =>
    `${event.id === undefined ? "" : `id: ${event.id}\n`}data: ${JSON.stringify(event.data)}\n\n`
  ).join("");
  const responseBody = keepOpen
    ? new ReadableStream({
      start(controller) {
        controller.enqueue(new TextEncoder().encode(body));
      },
    })
    : body;
  return new Response(responseBody, {
    headers: { "content-type": "text/event-stream" },
  });
}
