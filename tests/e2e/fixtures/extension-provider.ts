// A deterministic local executable proves host credential and lifecycle boundaries without HTTP.
import { createInterface } from "node:readline";
import { appendFileSync, existsSync } from "node:fs";

const LOG_FILENAME = "rpc-log.jsonl";
const RESULT_TEXT = "extension-rpc-ok";
const PROTOCOL_VERSION = 1;
const JSONRPC_VERSION = "2.0";
const PREPARED_HANDLE = "prepared-fixture";
const FINISH_REASON = "stop";
const MISSING_FINISH_FILENAME = "missing-finish";
const DROP_STREAM_FILENAME = "drop-stream";
const FAILURE_EXIT_CODE = 1;
const CREDENTIAL_SLOT = "FX_EXTENSION_TEST_KEY";
const lines = createInterface({ input: process.stdin });

for await (const line of lines) {
  const request = JSON.parse(line);
  appendFileSync(LOG_FILENAME, JSON.stringify({
    method: request.method,
    pid: process.pid,
    credential: Boolean(request.params.credential),
    ambientKey: Boolean(process.env[CREDENTIAL_SLOT]),
  }) + "\n");
  let result: unknown;
  switch (request.method) {
    case "initialize": result = { version: PROTOCOL_VERSION }; break;
    case "provider.prepare": result = { handle: PREPARED_HANDLE }; break;
    case "provider.stream":
      if (existsSync(DROP_STREAM_FILENAME)) process.exit(FAILURE_EXIT_CODE);
      result = { content: RESULT_TEXT, ...(existsSync(MISSING_FINISH_FILENAME) ? {} : { finish_reason: FINISH_REASON }) };
      break;
    case "shutdown": result = {}; break;
    default: throw new Error("unexpected fixture RPC method");
  }
  process.stdout.write(JSON.stringify({ jsonrpc: JSONRPC_VERSION, id: request.id, result }) + "\n");
  if (request.method === "shutdown") process.exit(0);
}
