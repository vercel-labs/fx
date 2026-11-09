import { createServer, type Socket } from "node:net";
import { MODERN_HTTP_TOOL_RESULT, MODERN_MCP_VERSION } from "./mcp-modern-http";

export type ContentLengthResponseType = "json" | "sse";

export type ContentLengthHttpRequest = {
  message: {
    id: number;
    method: string;
    params?: Record<string, any>;
  };
  headers: Record<string, string>;
};

export async function startContentLengthMcpHttpFixture(
  responseType: ContentLengthResponseType,
) {
  const requests: ContentLengthHttpRequest[] = [];
  const sockets = new Set<Socket>();
  let failure: Error | undefined;

  const server = createServer((socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("error", (error) => {
      failure ??= error;
    });

    // A keep-alive connection: every request on it is answered, in order,
    // each response written in two parts before the next starts.
    let requestBytes = Buffer.alloc(0);
    let writing = Promise.resolve();
    socket.on("data", (chunk) => {
      if (requestBytes.length + chunk.length > 1024 * 1024) {
        failure ??= new Error("content-length fixture request exceeded 1 MiB");
        socket.destroy();
        return;
      }
      requestBytes = Buffer.concat([requestBytes, chunk]);
      for (;;) {
        const headerEnd = requestBytes.indexOf("\r\n\r\n");
        if (headerEnd < 0) return;
        const head = requestBytes.subarray(0, headerEnd).toString("utf8");
        const headers: Record<string, string> = {};
        for (const line of head.split("\r\n").slice(1)) {
          const separator = line.indexOf(":");
          if (separator < 0) continue;
          headers[line.slice(0, separator).trim().toLowerCase()] =
            line.slice(separator + 1).trim();
        }
        const contentLength = Number.parseInt(headers["content-length"] ?? "0", 10);
        const bodyStart = headerEnd + 4;
        if (requestBytes.length < bodyStart + contentLength) return;
        const requestBody = requestBytes.subarray(bodyStart, bodyStart + contentLength).toString("utf8");
        requestBytes = requestBytes.subarray(bodyStart + contentLength);
        let body: Buffer;
        let status = "200 OK";
        let contentType = responseType === "sse" ? "text/event-stream" : "application/json";
        try {
          const message = JSON.parse(requestBody) as ContentLengthHttpRequest["message"];
          requests.push({ message, headers });
          if (message.id === undefined) {
            // A notification: accepted, nothing to answer.
            status = "202 Accepted";
            body = Buffer.alloc(0);
          } else {
            const json = JSON.stringify(responseFor(message));
            body = Buffer.from(
              responseType === "sse"
                ? `data: ${json}\n\n${": trailing bytes\n".repeat(2_000)}`
                : json,
              "utf8",
            );
          }
        } catch (error) {
          failure ??= error instanceof Error ? error : new Error(String(error));
          socket.destroy();
          return;
        }
        const responseHead = Buffer.from(
          `HTTP/1.1 ${status}\r\n` +
            (body.length > 0 ? `Content-Type: ${contentType}\r\n` : "") +
            `Content-Length: ${body.length}\r\n` +
            "Connection: keep-alive\r\n\r\n",
          "utf8",
        );
        writing = writing.then(() => new Promise<void>((resolve) => {
          if (socket.destroyed) return resolve();
          socket.write(responseHead);
          const split = Math.max(1, Math.floor(body.length / 2));
          if (body.length > 0) socket.write(body.subarray(0, split));
          setTimeout(() => {
            if (!socket.destroyed && body.length > split) socket.write(body.subarray(split));
            resolve();
          }, 5);
        }));
      }
    });
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  if (address === null || typeof address === "string") {
    throw new Error("missing content-length fixture address");
  }

  return {
    url: `http://127.0.0.1:${address.port}/mcp`,
    requests,
    get failure() {
      return failure;
    },
    async stop() {
      for (const socket of sockets) socket.destroy();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

function responseFor(message: ContentLengthHttpRequest["message"]) {
  if (message.method === "server/discover") {
    return {
      jsonrpc: "2.0",
      id: message.id,
      result: {
        resultType: "complete",
        supportedVersions: [MODERN_MCP_VERSION],
        capabilities: { tools: {} },
        instructions: "Use the fixed-length echo tool.",
      },
    };
  }
  if (message.method === "tools/list") {
    return {
      jsonrpc: "2.0",
      id: message.id,
      result: {
        resultType: "complete",
        tools: [{
          name: "echo",
          description: "Echo text through the fixed-length fixture",
          inputSchema: {
            type: "object",
            properties: { text: { type: "string" } },
            required: ["text"],
          },
        }],
        ttlMs: 60_000,
        cacheScope: "public",
      },
    };
  }
  if (message.method === "tools/call") {
    return {
      jsonrpc: "2.0",
      id: message.id,
      result: {
        resultType: "complete",
        content: [{
          type: "text",
          text: `${MODERN_HTTP_TOOL_RESULT}:${message.params?.arguments?.text ?? ""}`,
        }],
      },
    };
  }
  // Anything else, the listen for list changes included, is answered as a
  // server without it would.
  return {
    jsonrpc: "2.0",
    id: message.id,
    error: { code: -32601, message: `Method not found: ${message.method}` },
  };
}
