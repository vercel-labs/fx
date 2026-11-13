import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";

const wireLogPath = process.env.FX_MCP_WIRE_LOG;
const pidPath = process.env.FX_MCP_PID_PATH;
const resultText = process.env.FX_MCP_RESULT_TEXT ?? "LEGACY_MCP_TOOL_RESULT";
const mode = process.env.FX_MCP_MODE ?? "normal";
const invalidationReleasePath = process.env.FX_MCP_INVALIDATION_RELEASE_PATH;
// By default an old server that never heard of server/discover, at the
// oldest version fx speaks.
const legacyVersion = process.env.FX_MCP_LEGACY_VERSION ?? "2025-03-26";
const discoveryVersions = process.env.FX_MCP_LEGACY_DISCOVERY_VERSIONS?.split(",");
const discoveryMethodNotFound = process.env.FX_MCP_LEGACY_DISCOVERY_METHOD_NOT_FOUND === "1";
const discoveryInvalidParams = process.env.FX_MCP_LEGACY_DISCOVERY_INVALID_PARAMS === "1";
const rejectNewerInitialize = process.env.FX_MCP_LEGACY_REJECT_NEWER_INITIALIZE === "1";
const draft7Pattern = process.env.FX_MCP_DRAFT7_PATTERN;
const elicitationUrl = process.env.FX_MCP_ELICITATION_URL ?? "https://example.test/authorize";
const urlRequiredOperation = process.env.FX_MCP_URL_REQUIRED_OPERATION ?? "tools";
let buffer = Buffer.alloc(0);
let messageCount = 0;
// `initialize` is the first message, or the second after a discovery probe.
let sawDiscovery = false;
let toolsListCalls = 0;
let currentToolName = "echo";
let pendingToolCall = null;
// FX_MCP_MODE=ping_before_initialize: the initialize answer, held until the
// client answers this server's ping, as a server that blocks on it would.
let pendingInitialize = null;
let urlRequiredSent = false;
let completionStage = 0;

if (pidPath) writeFileSync(pidPath, String(process.pid));

// Startup failure modes model a package runner that exits before the server
// answers initialize, printing npm-style diagnostics to stderr.
const startupFailure = mode === "startup_exit" || mode === "startup_exit_after_delay";
if (startupFailure) {
  const fail = () => process.stderr.write(
    "npm error code E401\nnpm error Incorrect or missing password.\n",
    () => process.exit(7),
  );
  if (mode === "startup_exit") fail();
  else setTimeout(fail, 400);
}

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function log(message) {
  if (wireLogPath) {
    appendFileSync(
      wireLogPath,
      `${JSON.stringify({ pid: process.pid, sequence: messageCount, message })}\n`,
    );
  }
}

function sendUrlRequired(message) {
  urlRequiredSent = true;
  const elicitations = [{
    mode: "url",
    message: "Authorize the legacy operation",
    url: elicitationUrl,
    elicitationId: "legacy-url-1",
  }];
  if (mode === "url_required_multiple") {
    elicitations.push({
      mode: "url",
      message: "Confirm the second legacy authorization",
      url: `${elicitationUrl}#second`,
      elicitationId: "legacy-url-2",
    });
  }
  send({
    jsonrpc: "2.0",
    id: message.id,
    error: {
      code: -32042,
      message: "URL elicitation required",
      data: { elicitations },
    },
  });
  const shouldPoll = mode === "url_required_multiple" || urlRequiredOperation !== "tools";
  if (mode === "url_required_malformed_completion" && invalidationReleasePath) {
    const completionPoll = setInterval(() => {
      const requestedStage = existsSync(invalidationReleasePath)
        ? readFileSync(invalidationReleasePath, "utf8").trim()
        : "";
      if (completionStage === 0 && requestedStage === "invalid") {
        const malformed = [
          {
            method: "notifications/elicitation/complete",
            params: { elicitationId: "legacy-url-1" },
          },
          {
            jsonrpc: "1.0",
            method: "notifications/elicitation/complete",
            params: { elicitationId: "legacy-url-1" },
          },
          {
            jsonrpc: 2,
            method: "notifications/elicitation/complete",
            params: { elicitationId: "legacy-url-1" },
          },
          {
            jsonrpc: "2.0",
            method: "notifications/elicitation/completed",
            params: { elicitationId: "legacy-url-1" },
          },
          {
            jsonrpc: "2.0",
            method: "notifications/elicitation/complete",
            params: null,
          },
          {
            jsonrpc: "2.0",
            method: "notifications/elicitation/complete",
            params: { elicitationId: 7 },
          },
          {
            jsonrpc: "2.0",
            method: "notifications/elicitation/complete",
            params: { elicitationId: "" },
          },
          {
            jsonrpc: "2.0",
            method: "notifications/elicitation/complete",
            params: { elicitationId: "x".repeat(257) },
          },
          {
            jsonrpc: "2.0",
            method: "notifications/elicitation/complete",
            params: { elicitationId: "unknown-legacy-url" },
          },
        ];
        for (const notification of malformed) send(notification);
        completionStage = 1;
      }
      if (completionStage === 1 && requestedStage === "valid") {
        for (let index = 0; index < 2; index += 1) {
          send({
            jsonrpc: "2.0",
            method: "notifications/elicitation/complete",
            params: { elicitationId: "legacy-url-1" },
          });
        }
        completionStage = 2;
        clearInterval(completionPoll);
      }
    }, 5);
    return;
  }
  if (!shouldPoll || !invalidationReleasePath) return;
  const completionPoll = setInterval(() => {
    if (!existsSync(invalidationReleasePath)) return;
    const requestedStage = readFileSync(invalidationReleasePath, "utf8").trim();
    if (completionStage === 0 && (requestedStage === "one" || requestedStage === "two")) {
      for (const elicitationId of ["unknown-legacy-url", "legacy-url-1", "legacy-url-1"]) {
        send({
          jsonrpc: "2.0",
          method: "notifications/elicitation/complete",
          params: { elicitationId },
        });
      }
      completionStage = 1;
      if (mode !== "url_required_multiple") clearInterval(completionPoll);
    }
    if (completionStage === 1 && requestedStage === "two") {
      send({
        jsonrpc: "2.0",
        method: "notifications/elicitation/complete",
        params: { elicitationId: "legacy-url-2" },
      });
      completionStage = 2;
      clearInterval(completionPoll);
    }
  }, 5);
}

function handle(message) {
  messageCount += 1;
  log(message);

  if (pendingToolCall && message.id === "legacy-elicitation") {
    if (message.jsonrpc !== "2.0" || message.result?.action !== "accept") process.exit(8);
    const answer = message.result?.content?.choice;
    if (legacyVersion === "2025-06-18" && answer !== "legacy-alpha-choice") process.exit(9);
    if (legacyVersion === "2025-11-25" && answer !== "legacyvalid") process.exit(10);
    const call = pendingToolCall;
    pendingToolCall = null;
    send({
      jsonrpc: "2.0",
      id: call.id,
      result: {
        content: [{ type: "text", text: `${resultText}:elicited` }],
      },
    });
    return;
  }

  if (pendingInitialize && message.id === "legacy-ping" && message.method === undefined) {
    if (message.jsonrpc !== "2.0" || JSON.stringify(message.result) !== "{}") process.exit(11);
    const answer = pendingInitialize;
    pendingInitialize = null;
    send(answer);
    return;
  }

  if (message.method === "server/discover") {
    sawDiscovery = true;
    if (process.env.FX_MCP_IGNORE_DISCOVERY === "1") return;
    if (discoveryInvalidParams) {
      send({
        jsonrpc: "2.0",
        id: message.id,
        error: { code: -32602, message: "Invalid params" },
      });
      return;
    }
    if (discoveryVersions) {
      send({
        jsonrpc: "2.0",
        id: message.id,
        result: {
          resultType: "complete",
          supportedVersions: discoveryVersions,
          capabilities: {},
        },
      });
      return;
    }
    if (
      process.env.FX_MCP_LEGACY_VERSION !== undefined &&
      legacyVersion !== "2024-11-05" &&
      !discoveryMethodNotFound
    ) {
      send({
        jsonrpc: "2.0",
        id: message.id,
        error: {
          code: -32022,
          message: "Unsupported protocol version",
          data: { supported: [legacyVersion], requested: "2026-07-28" },
        },
      });
      return;
    }
    send({
      jsonrpc: "2.0",
      id: message.id,
      error: { code: -32601, message: "Method not found" },
    });
    return;
  }
  if (message.method === "initialize") {
    if (startupFailure) return;
    // Answer with output fx must reject; the process itself stays up.
    if (mode === "startup_garbage") {
      process.stdout.write("not json\n");
      return;
    }
    if (messageCount !== 1 && !(sawDiscovery && messageCount === 2)) process.exit(2);
    const requestedVersion = message.params?.protocolVersion;
    if (requestedVersion !== legacyVersion && rejectNewerInitialize) process.exit(5);
    if (requestedVersion === "2025-06-18") {
      const capability = message.params?.capabilities?.elicitation;
      if (capability !== undefined && JSON.stringify(capability) !== "{}") process.exit(6);
      if (mode === "direct_form" && capability === undefined) process.exit(6);
    }
    if (requestedVersion === "2025-11-25") {
      const capability = message.params?.capabilities?.elicitation;
      // URL questions exist from 2025-11-25; an older server answers with its
      // own version and never asks for one.
      const asksForUrl = (mode === "url_required_error" || mode === "url_required_multiple") &&
        legacyVersion === "2025-11-25";
      if (
        (mode === "direct_form" || asksForUrl) &&
        (capability?.form == null || capability?.url == null)
      ) process.exit(7);
    }
    const answer = {
      jsonrpc: "2.0",
      id: message.id,
      result: {
        protocolVersion: legacyVersion,
        capabilities: {
          tools: mode === "list_changed" ? { listChanged: true } : {},
          ...(urlRequiredOperation === "resources" ? { resources: {} } : {}),
          ...(urlRequiredOperation === "prompts" ? { prompts: {} } : {}),
        },
        serverInfo: { name: "legacy-fixture", version: "1.0.0" },
      },
    };
    if (mode === "ping_before_initialize") {
      pendingInitialize = answer;
      send({ jsonrpc: "2.0", id: "legacy-ping", method: "ping" });
      return;
    }
    send(answer);
    return;
  }
  if (message.method === "notifications/initialized") return;
  if (message.method === "tools/list") {
    toolsListCalls += 1;
    if (deepSite().startsWith("tool_")) {
      sendDeepToolList(message);
      return;
    }
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        tools: [{
          name: currentToolName,
          description: "Echo text through the legacy MCP fixture",
          inputSchema: {
            ...(mode === "draft7_schema"
              ? { $schema: "http://json-schema.org/draft-07/schema#" }
              : {}),
            type: "object",
            properties: {
              text: {
                type: "string",
                ...(draft7Pattern ? { pattern: draft7Pattern } : {}),
              },
            },
            required: ["text"],
          },
          ...(mode === "draft7_schema"
            ? { execution: { taskSupport: "forbidden" } }
            : {}),
        }],
      },
    });
    if (mode === "list_changed" && toolsListCalls === 1) {
      const notify = () => {
        currentToolName = "fresh";
        send({
          jsonrpc: "2.0",
          method: "notifications/tools/list_changed",
          params: {},
        });
      };
      if (invalidationReleasePath) {
        const releasePoll = setInterval(() => {
          if (!existsSync(invalidationReleasePath)) return;
          clearInterval(releasePoll);
          notify();
        }, 5);
      } else {
        setTimeout(notify, 50);
      }
    }
    return;
  }
  if (message.method === "resources/list") {
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        resources: [{ uri: "legacy://alpha", name: "legacy-alpha", mimeType: "text/plain" }],
      },
    });
    return;
  }
  if (message.method === "resources/read") {
    if (mode === "url_required_error" && urlRequiredOperation === "resources" && !urlRequiredSent) {
      sendUrlRequired(message);
      return;
    }
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        contents: [{
          uri: message.params?.uri,
          mimeType: "text/plain",
          text: "LEGACY_STDIO_RESOURCE_TEXT",
        }],
      },
    });
    return;
  }
  if (message.method === "prompts/list") {
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        prompts: [{ name: "review", arguments: [{ name: "tone", required: true }] }],
      },
    });
    return;
  }
  if (message.method === "prompts/get") {
    if (mode === "url_required_error" && urlRequiredOperation === "prompts" && !urlRequiredSent) {
      sendUrlRequired(message);
      return;
    }
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        description: "Legacy stdio review prompt",
        messages: [{
          role: "user",
          content: { type: "text", text: "LEGACY_STDIO_PROMPT_TEXT" },
        }],
      },
    });
    return;
  }
  if (message.method === "tools/call") {
    if (deepSite() !== "" && !deepSite().startsWith("tool_")) {
      sendDeepResult(message);
      return;
    }
    if (mode === "invalid_params") {
      // A server built on the Go MCP SDK refuses arguments of the wrong type
      // with -32602, in its validator's words, then the tool's schema, as
      // Datadog's server does.
      send({
        jsonrpc: "2.0",
        id: message.id,
        error: {
          code: -32602,
          message: 'validating "arguments": validating root: validating /properties/limit: ' +
            'type: "40" has type "string", want "number"\n\n' +
            'Full input schema for tool "echo":\n' +
            '{"type":"object","properties":{"limit":{"type":"number"}}}',
        },
      });
      return;
    }
    if (mode === "draft7_schema" && draft7Pattern && !new RegExp(draft7Pattern, "u").test(message.params?.arguments?.text)) {
      send({ jsonrpc: "2.0", id: message.id, result: { isError: true, content: [{ type: "text", text: "text violates the server pattern" }] } });
      return;
    }
    const progressToken = message.params?._meta?.progressToken;
    if (!Number.isInteger(progressToken)) process.exit(4);
    if (mode === "direct_form") {
      pendingToolCall = message;
      send({
        jsonrpc: "2.0",
        id: "legacy-elicitation",
        method: "elicitation/create",
        params: legacyVersion === "2025-06-18"
          ? {
              message: "Choose a legacy value",
              requestedSchema: {
                type: "object",
                properties: {
                  choice: {
                    type: "string",
                    enum: ["legacy-alpha-choice", "legacy-beta-choice"],
                    enumNames: ["Alpha", "Beta"],
                  },
                },
                required: ["choice"],
              },
            }
          : {
              mode: "form",
              message: "Enter a legacy value",
              requestedSchema: {
                type: "object",
                properties: {
                  choice: {
                    type: "string",
                    enum: ["legacyvalid", "legacyalternate"],
                    enumNames: ["Legacy valid", "Legacy alternate"],
                    description: "Do not provide a phone number, pin, or other sensitive info",
                  },
                },
                required: ["choice"],
              },
            },
      });
      return;
    }
    if (
      (mode === "url_required_error" ||
        mode === "url_required_multiple" ||
        mode === "url_required_malformed_completion") &&
      urlRequiredOperation === "tools" &&
      !urlRequiredSent
    ) {
      sendUrlRequired(message);
      return;
    }
    if (mode === "progress") {
      send({
        jsonrpc: "2.0",
        method: "notifications/progress",
        params: {
          progressToken,
          progress: 1,
          total: 2,
          message: "Legacy MCP fixture halfway",
        },
      });
    }
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        content: [{
          type: "text",
          text: `${resultText}:${message.params?.arguments?.text ?? ""}`,
        }],
      },
    });
    return;
  }
  send({
    jsonrpc: "2.0",
    id: message.id,
    error: { code: -32601, message: "Method not found" },
  });
}

process.stdin.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  while (true) {
    const lineEnd = buffer.indexOf("\n");
    if (lineEnd < 0) return;
    const line = buffer.subarray(0, lineEnd).toString("utf8").replace(/\r+$/, "");
    buffer = buffer.subarray(lineEnd + 1);
    if (line.length > 0) handle(JSON.parse(line));
  }
});

// FX_MCP_DEEP_SITE nests JSON at one place, for the depth limit on a server's JSON. FX_MCP_DEEP_DEPTH is the
// nesting depth of the root value fx checks (the result for the result sites, the tool object for the tool
// sites), FX_MCP_DEEP_SHAPE is object (the default), array or mixed. Sites: structured, content_meta,
// content_annotations, error_data, tool_meta, tool_annotations, tool_icons.
function deepSite() {
  return process.env.FX_MCP_DEEP_SITE ?? "";
}

/** A value with exactly `depth` containers inside one another, and 1 at the bottom. */
function deepValue(depth, objectRoot) {
  const shape = process.env.FX_MCP_DEEP_SHAPE ?? "object";
  let text = "1";
  for (let level = 1; level <= depth; level += 1) {
    const fromRoot = depth - level;
    const object = shape === "object" || (shape === "mixed" && fromRoot % 2 === 0) || (objectRoot && fromRoot === 0);
    text = object ? `{"a":${text}}` : `[${text}]`;
  }
  return text;
}

function sendDeepText(message, replacements) {
  let text = JSON.stringify(message);
  for (const [marker, value] of Object.entries(replacements)) text = text.replace(`"${marker}"`, () => value);
  if (process.env.FX_MCP_DEEP_FAULT === "cut") {
    // The reply stops in the middle of the nesting, as a server that dies while writing it.
    process.stdout.write(text.slice(0, Math.floor(text.length / 2)), () => process.exit(0));
    return;
  }
  process.stdout.write(`${text}\n`);
}

function sendDeepToolList(message) {
  const site = deepSite();
  const depth = Number(process.env.FX_MCP_DEEP_DEPTH ?? "0");
  const deep = {
    name: "deep",
    description: "A tool whose listing is nested deeper than fx accepts",
    inputSchema: { type: "object", properties: { text: { type: "string" } } },
  };
  if (site === "tool_meta") deep._meta = "@@DEEP@@";
  if (site === "tool_annotations") deep.annotations = { x: "@@DEEP@@" };
  if (site === "tool_icons") deep.icons = [{ src: "https://example.test/icon.png", x: "@@DEEP@@" }];
  // The tool object is one level, and the field's own wrapper levels come out of the depth.
  const inner = site === "tool_meta" ? depth - 1 : site === "tool_annotations" ? depth - 2 : depth - 3;
  const good = {
    name: currentToolName,
    description: "Echo text through the legacy MCP fixture",
    inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] },
  };
  sendDeepText({ jsonrpc: "2.0", id: message.id, result: { tools: [good, deep] } }, { "@@DEEP@@": deepValue(inner, site === "tool_meta") });
}

function sendDeepResult(message) {
  const site = deepSite();
  const depth = Number(process.env.FX_MCP_DEEP_DEPTH ?? "0");
  if (site === "error_data") {
    sendDeepText(
      { jsonrpc: "2.0", id: message.id, error: { code: -32602, message: "bad", data: "@@DEEP@@" } },
      { "@@DEEP@@": deepValue(depth, false) },
    );
    return;
  }
  const result = { content: [{ type: "text", text: `${resultText}:${message.params?.arguments?.text ?? ""}` }] };
  let inner = depth;
  if (site === "structured") {
    result.structuredContent = "@@DEEP@@";
    inner = depth - 1;
  }
  if (site === "content_meta") {
    result.content[0]._meta = "@@DEEP@@";
    inner = depth - 3;
  }
  if (site === "content_annotations") {
    result.content[0].annotations = { x: "@@DEEP@@" };
    inner = depth - 4;
  }
  sendDeepText({ jsonrpc: "2.0", id: message.id, result }, { "@@DEEP@@": deepValue(inner, site === "structured" || site === "content_meta") });
}
