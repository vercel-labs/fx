// Runs web_fetch's address admission along tests/tla/web/FetchAdmission.tla
// and has TLC check every hop it observes (FetchAdmissionTrace.tla).
//
// Two sources of hops, both the real code:
//
//   - lab.zig runs `fetch` from src/tools/web/http_fetch.zig on DNS answer
//     sets: a fixed list of edge cases (the DNS64 answers from issue #1184,
//     NAT64 addresses that wrap private ones, the RFC 8215 local-use prefix,
//     IPv4-compatible and IPv4-mapped forms, answer sets that mix them) and
//     seeded random sets drawn from a pool that covers every address form.
//   - The built fx binary (FX_BIN, or zig-out/bin/fx) runs `fx ask` against a
//     local fake gateway that asks for web_fetch on IP literals. The run goes
//     through `env -i` and, on macOS, `sandbox-exec` with outbound connections
//     allowed only to localhost, so an admitted address fails at its dial on
//     this machine and fx reports a transport failure; a refused one never
//     gets there. Elsewhere the binary part is skipped.
//
// The driver maps each address to the model's [form, v4] record with its own
// table of the RFC prefixes, apart from fx's code, then writes the hops as
// FetchAdmissionObserved.tla. The run is ACCEPTED when the design (Rule
// "fixed") can produce every hop.
//
// --self-check also requires the model of fx before the change (Rule "today")
// to reject the same hops, and builds the lab on copies of src/ with a planted
// bug in isPublicIpv6, each of which the design must reject.
//
// Usage:
//   bun tests/tla/drivers/web/driver.ts [--self-check] [--seed N] [--random N] [--no-binary]
//
// Exits 0 when ACCEPTED, 1 when REJECTED, and 2 for a harness or tool failure.
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { REPO_ROOT, TLA_ROOT, fxBin, outDir, runTlc, writeJson } from "../lib/tlc";

type Form = "ipv4" | "nat64" | "nat64_local" | "compat" | "mapped" | "global6" | "special6" | "local6";
type Address = { form: Form; v4: string };
type Outcome = "admitted" | "refused";
type Observation = { source: string; inputs: string[]; answers: Address[]; outcome: Outcome; dialed: Address[] };
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const options = (() => {
  const args = process.argv.slice(2);
  const value = (flag: string, fallback: number) => {
    const index = args.indexOf(flag);
    return index >= 0 ? Number(args[index + 1]) : fallback;
  };
  return {
    selfCheck: args.includes("--self-check"),
    noBinary: args.includes("--no-binary"),
    seed: value("--seed", 1184),
    random: value("--random", 400),
  };
})();

function fail(code: number, message: string): never {
  console.log(message);
  process.exit(code);
}

// --- Address forms, from the RFCs -------------------------------------------

const V4_CLASSES = [
  "public", "this_network", "private", "shared", "loopback", "link_local", "ietf",
  "documentation", "relay", "benchmark", "multicast", "reserved",
] as const;

// RFC 6890 and the IANA IPv4 special-purpose registry, plus multicast and
// the reserved block (which holds the limited broadcast address).
const V4_SPECIAL: Array<[number[], number, string]> = [
  [[0, 0, 0, 0], 8, "this_network"],
  [[10, 0, 0, 0], 8, "private"],
  [[100, 64, 0, 0], 10, "shared"],
  [[127, 0, 0, 0], 8, "loopback"],
  [[169, 254, 0, 0], 16, "link_local"],
  [[172, 16, 0, 0], 12, "private"],
  [[192, 0, 0, 0], 24, "ietf"],
  [[192, 0, 2, 0], 24, "documentation"],
  [[192, 88, 99, 0], 24, "relay"],
  [[192, 168, 0, 0], 16, "private"],
  [[198, 18, 0, 0], 15, "benchmark"],
  [[198, 51, 100, 0], 24, "documentation"],
  [[203, 0, 113, 0], 24, "documentation"],
  [[224, 0, 0, 0], 4, "multicast"],
  [[240, 0, 0, 0], 4, "reserved"],
];

function v4Class(bytes: number[]): string {
  const value = ((bytes[0]! << 24) | (bytes[1]! << 16) | (bytes[2]! << 8) | bytes[3]!) >>> 0;
  for (const [prefix, bits, name] of V4_SPECIAL) {
    const base = ((prefix[0]! << 24) | (prefix[1]! << 16) | (prefix[2]! << 8) | prefix[3]!) >>> 0;
    const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
    if (((value & mask) >>> 0) === ((base & mask) >>> 0)) return name;
  }
  return "public";
}

function parseIpv4(text: string): number[] | null {
  const parts = text.split(".");
  if (parts.length !== 4 || parts.some((part) => !/^\d{1,3}$/.test(part) || Number(part) > 255)) return null;
  return parts.map(Number);
}

function parseIpv6(text: string): number[] | null {
  // A dotted IPv4 tail, as in ::ffff:192.0.2.1, stands for the last two groups.
  const dotted = /^(.*:)(\d+\.\d+\.\d+\.\d+)$/.exec(text);
  if (dotted) {
    const ip4 = parseIpv4(dotted[2]!);
    if (!ip4) return null;
    text = `${dotted[1]}${((ip4[0]! << 8) | ip4[1]!).toString(16)}:${((ip4[2]! << 8) | ip4[3]!).toString(16)}`;
  }
  if (!/^[0-9a-fA-F:]+$/.test(text)) return null;
  const halves = text.split("::");
  if (halves.length > 2) return null;
  const groups = (part: string) => (part === "" ? [] : part.split(":"));
  const head = groups(halves[0]!);
  const tail = halves.length === 2 ? groups(halves[1]!) : [];
  const fill = 8 - head.length - tail.length;
  if (halves.length === 1 ? head.length !== 8 : fill < 1) return null;
  const all = [...head, ...Array(halves.length === 2 ? fill : 0).fill("0"), ...tail];
  if (all.some((group) => !/^[0-9a-fA-F]{1,4}$/.test(group))) return null;
  return all.flatMap((group) => {
    const value = parseInt(group, 16);
    return [value >> 8, value & 0xff];
  });
}

const equalBytes = (bytes: number[], start: number, expected: number[]) =>
  expected.every((byte, index) => bytes[start + index] === byte);

/// The model's record for one address, from RFC 6052, 8215, 4291, 6890,
/// 3056, 4380, 3849, and 9637.
function abstractAddress(text: string): Address {
  const ip4 = parseIpv4(text);
  if (ip4) return { form: "ipv4", v4: v4Class(ip4) };
  const bytes = parseIpv6(text);
  if (!bytes) throw new Error(`driver cannot parse ${text}`);
  const tail = bytes.slice(12, 16);
  if (equalBytes(bytes, 0, [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0])) return { form: "nat64", v4: v4Class(tail) };
  if (equalBytes(bytes, 0, [0x00, 0x64, 0xff, 0x9b, 0x00, 0x01])) return { form: "nat64_local", v4: v4Class(tail) };
  if (equalBytes(bytes, 0, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff])) return { form: "mapped", v4: v4Class(tail) };
  if (equalBytes(bytes, 0, Array(15).fill(0))) return { form: "local6", v4: "none" }; // :: and ::1
  if (equalBytes(bytes, 0, Array(12).fill(0))) return { form: "compat", v4: v4Class(tail) };
  if ((bytes[0]! & 0xe0) === 0x20) {
    const teredoOrIetf = bytes[0] === 0x20 && bytes[1] === 0x01 && (bytes[2]! & 0xfe) === 0x00; // 2001::/23
    const documentation = equalBytes(bytes, 0, [0x20, 0x01, 0x0d, 0xb8]) || // 2001:db8::/32
      (bytes[0] === 0x3f && (bytes[1]! & 0xf0) === 0xf0); // 3fff::/20
    const sixToFour = bytes[0] === 0x20 && bytes[1] === 0x02; // 2002::/16
    return { form: teredoOrIetf || documentation || sixToFour ? "special6" : "global6", v4: "none" };
  }
  return { form: "local6", v4: "none" };
}

// --- Cases --------------------------------------------------------------------

const FIXED_CASES: string[][] = [
  ["64:ff9b::40ef:6d41", "64:ff9b::40ef:7b41", "64.239.123.65", "64.239.109.65"], // issue #1184
  ["64:ff9b::40ef:7b41"],
  ["64.239.123.65", "64:ff9b::7f00:1"],
  ["64:ff9b::40ef:7b41", "64:ff9b::a9fe:a9fe"],
  ["64:ff9b::a00:1"],
  ["64:ff9b::"],
  ["64:ff9b::ffff:ffff"],
  ["64:ff9b::6440:1"],
  ["64:ff9b:1::5db8:d822"],
  ["64:ff9b::1:5db8:d822"],
  ["::a00:1"],
  ["::a9fe:a9fe"],
  ["::5db8:d822"],
  ["::ffff:64.239.123.65"],
  ["2606:4700:4700::1111", "93.184.216.34", "64:ff9b::5db8:d822"],
  ["2001:db8::1"],
  ["fe80::1", "64:ff9b::40ef:7b41"],
];

const POOL = [
  "64.239.123.65", "64.239.109.65", "93.184.216.34", "8.8.8.8",
  "127.0.0.1", "10.0.0.5", "169.254.169.254", "100.64.0.1", "192.168.1.1", "0.0.0.0", "255.255.255.255", "192.0.2.1",
  "64:ff9b::40ef:7b41", "64:ff9b::40ef:6d41", "64:ff9b::808:808",
  "64:ff9b::7f00:1", "64:ff9b::a00:5", "64:ff9b::a9fe:a9fe", "64:ff9b::6440:1", "64:ff9b::", "64:ff9b::ffff:ffff",
  "64:ff9b::c000:201", "64:ff9b:1::5db8:d822", "64:ff9b:1::7f00:1", "64:ff9b::1:5db8:d822", "64:ff9b:0:0:1::808:808",
  "::a00:1", "::a9fe:a9fe", "::5db8:d822", "::ffff:64.239.123.65", "::ffff:127.0.0.1",
  "2606:4700:4700::1111", "2a00:1450:4001::200e", "2001::1", "2001:db8::1", "2002::1", "3fff::1",
  "::1", "::", "fc00::1", "fe80::1", "ff02::1",
];

// mulberry32: small, seedable, and the same in every runtime.
function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function cases(): string[][] {
  const next = rng(options.seed);
  const out = [...FIXED_CASES];
  for (let i = 0; i < options.random; i++) {
    const size = 1 + Math.floor(next() * 4);
    out.push(Array.from({ length: size }, () => POOL[Math.floor(next() * POOL.length)]!));
  }
  // A large answer set: 32 A records and their 32 DNS64 records, then the
  // same with one answer that wraps loopback.
  const big: string[] = [];
  for (let i = 1; i <= 32; i++) {
    big.push(`64.239.123.${i}`);
    big.push(`64:ff9b::40ef:7b${i.toString(16).padStart(2, "0")}`);
  }
  out.push(big, [...big, "64:ff9b::7f00:1"]);
  return out;
}

// --- The lab: fetch from http_fetch.zig on DNS answers ---------------------------

const LAB_ROOT = [
  "pub const http_fetch = @import(\"tools/web/http_fetch.zig\");",
  "pub const url_policy = @import(\"tools/web/url_policy.zig\");",
  "pub const io_mod = @import(\"core/shared/io.zig\");",
  "",
].join("\n");

/// Copies src/ into `dir`, applies `edit` to url_policy.zig, and builds lab.zig
/// against the copy. Returns the binary.
function buildLab(dir: string, edit: (source: string) => string = (source) => source): string {
  const src = join(dir, "src");
  cpSync(join(REPO_ROOT, "src"), src, { recursive: true });
  const policy = join(src, "tools", "web", "url_policy.zig");
  writeFileSync(policy, edit(readFileSync(policy, "utf8")));
  writeFileSync(join(src, "fx_web_lab_root.zig"), LAB_ROOT);
  const bin = join(dir, "web-lab");
  const build = Bun.spawnSync(
    ["zig", "build-exe", "-O", "ReleaseSafe", "-lc", "--dep", "fx_web",
      `-Mroot=${join(TLA_ROOT, "drivers", "web", "lab.zig")}`, `-Mfx_web=${join(src, "fx_web_lab_root.zig")}`,
      "--name", "web-lab", `-femit-bin=${bin}`],
    { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0) fail(2, `building the lab in ${dir} failed:\n${new TextDecoder().decode(build.stderr)}`);
  return bin;
}

type LabResult = { outcome: string; error: string | null; pinned: number[]; resolver_calls: number; connector_calls: number };

function runLab(bin: string, dir: string, sets: string[][]): Observation[] {
  const input = join(dir, "cases.jsonl");
  const output = join(dir, "results.jsonl");
  writeFileSync(input, sets.map((answers) => JSON.stringify({ answers })).join("\n") + "\n");
  const run = Bun.spawnSync([bin, input, output], { stdout: "pipe", stderr: "pipe" });
  if (run.exitCode !== 0) fail(2, `the lab failed (exit ${run.exitCode}):\n${new TextDecoder().decode(run.stderr)}`);
  const results = readFileSync(output, "utf8").trim().split("\n").map((line) => JSON.parse(line) as LabResult);
  if (results.length !== sets.length) fail(2, `the lab answered ${results.length} of ${sets.length} cases`);
  return results.map((result, index) => {
    const inputs = sets[index]!;
    if (result.outcome === "bad_case") fail(2, `case ${index}: the lab cannot parse ${JSON.stringify(inputs)}`);
    if (result.resolver_calls !== 1) fail(2, `case ${index}: the resolver ran ${result.resolver_calls} times`);
    if (result.outcome === "admitted") {
      if (result.connector_calls !== 1) fail(2, `case ${index}: admitted with ${result.connector_calls} dials`);
    } else if (result.outcome === "refused") {
      if (result.connector_calls !== 0) fail(1, `REJECTED: case ${index} was refused after a dial: ${JSON.stringify(inputs)}`);
    } else {
      fail(2, `case ${index}: fetch ended with ${result.error}: ${JSON.stringify(inputs)}`);
    }
    return {
      source: "lab",
      inputs,
      answers: inputs.map(abstractAddress),
      outcome: result.outcome as Outcome,
      dialed: result.pinned.map((pinned) => abstractAddress(inputs[pinned]!)),
    };
  });
}

// --- The built binary on IP literals ------------------------------------------------

const LITERALS = [
  "64:ff9b::40ef:7b41", "64:ff9b::40ef:6d41", "64:ff9b::7f00:1", "64:ff9b::a9fe:a9fe", "64:ff9b::a00:1",
  "64:ff9b:1::5db8:d822", "64:ff9b::1:5db8:d822", "0064:FF9B:0000:0000:0000:0000:7F00:0001", "::a9fe:a9fe",
  "::ffff:64.239.123.65", "2606:4700:4700::1111",
];
// Spellings std.Io.net.Ip6Address.parse does not read; fx must refuse them.
const MALFORMED = ["64:ff9b::127.0.0.1", "64:ff9b::64.239.123.65", "::ffff:40ef:7b41"];
const SANDBOX = "(version 1)(allow default)(deny network-outbound (remote ip \"*:*\"))(allow network-outbound (remote ip \"localhost:*\"))";

function sse(events: object[]) {
  return new Response(
    events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );
}

async function runBinary(dir: string): Promise<Observation[] | null> {
  if (options.noBinary) return null;
  if (process.platform !== "darwin" || !existsSync("/usr/bin/sandbox-exec")) {
    console.log("binary: skipped, sandbox-exec is macOS only");
    return null;
  }
  const urls = [...LITERALS, ...MALFORMED].map((literal) => `https://[${literal}]/`);
  const outputs = new Map<string, string>();
  let chatRequests = 0;
  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(req) {
      const path = new URL(req.url).pathname;
      if (path === "/coding-agent/v1/models") {
        return Response.json({ data: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
      }
      if (req.method !== "POST") return new Response("not found", { status: 404 });
      const body = await req.text();
      if (body.includes("Generate a short title")) return sse([{ type: "finish", finishReason: { unified: "stop", raw: "stop" } }]);
      chatRequests += 1;
      if (chatRequests === 1) {
        return sse([
          ...urls.map((url, index) => ({ type: "tool-call", toolCallId: `fetch_${index}`, toolName: "web_fetch", input: { url } })),
          { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
        ]);
      }
      for (const message of JSON.parse(body).prompt as Array<{ role: string; content: any[] }>) {
        if (message.role !== "tool") continue;
        for (const part of message.content) {
          const url = urls[Number(String(part.toolCallId).replace("fetch_", ""))];
          const value = part.output?.value;
          if (url) outputs.set(url, typeof value === "string" ? value : JSON.stringify(value));
        }
      }
      return sse([
        { type: "text-delta", id: "answer", delta: "fetched" },
        { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: { inputTokens: { total: 1 }, outputTokens: { total: 1 } } },
      ]);
    },
  });
  const root = mkdtempSync(join(tmpdir(), "fx-tla-web-bin-"));
  try {
    for (const name of ["home", "fx-home", "workspace"]) mkdirSync(join(root, name));
    const base = `http://127.0.0.1:${server.port}`;
    const argv = [
      "/usr/bin/env", "-i",
      `HOME=${join(root, "home")}`, "PATH=/usr/bin:/bin", `FX_HOME=${join(root, "fx-home")}`,
      "FX_DISABLE_KEYCHAIN=1", "FX_SOUND=0", "FX_AUTO_UPGRADE=0", "FX_E2E_DISABLE_DOTENV=1", "NO_COLOR=1",
      `FX_GATEWAY_BASE_URL=${base}`, `FX_GATEWAY_CHAT_URL=${base}/v4/ai/language-model`,
      "AI_GATEWAY_API_KEY=fake-web-fetch-key", "FX_MODEL=openai/gpt-5",
      "/usr/bin/sandbox-exec", "-p", SANDBOX,
      fxBin(), "ask", "--full-access", "--json", "--no-save", "Fetch the NAT64 URLs.",
    ];
    const proc = Bun.spawn(argv, { cwd: join(root, "workspace"), stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    const timer = setTimeout(() => proc.kill("SIGKILL"), 60_000);
    const [stdout, stderr, exit] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
    clearTimeout(timer);
    writeFileSync(join(dir, "binary.log"), `${argv.join(" ")}\nexit ${exit}\n--- stdout\n${stdout}\n--- stderr\n${stderr}\n`);
    writeJson(join(dir, "binary-outputs.json"), Object.fromEntries(outputs));
    if (exit !== 0) fail(2, `binary: fx exited ${exit}; see ${join(dir, "binary.log")}`);
    if (chatRequests !== 2) fail(2, `binary: the fake gateway counted ${chatRequests} chat requests, want 2`);
    if (outputs.size !== urls.length) fail(2, `binary: ${outputs.size} of ${urls.length} tool results came back`);
  } finally {
    server.stop(true);
    rmSync(root, { recursive: true, force: true });
  }
  const observations: Observation[] = [];
  for (const literal of LITERALS) {
    const output = outputs.get(`https://[${literal}]/`)!;
    const address = abstractAddress(literal);
    if (/only fetches known public/.test(output)) {
      observations.push({ source: "binary", inputs: [literal], answers: [address], outcome: "refused", dialed: [] });
    } else if (/transport failed/.test(output)) {
      observations.push({ source: "binary", inputs: [literal], answers: [address], outcome: "admitted", dialed: [address] });
    } else {
      fail(2, `binary: cannot read the result for [${literal}]: ${output}`);
    }
  }
  for (const literal of MALFORMED) {
    const output = outputs.get(`https://[${literal}]/`)!;
    if (/transport failed/.test(output)) fail(1, `REJECTED: the binary dialed the malformed literal [${literal}]`);
  }
  console.log(`binary: ${observations.length} literal hops, ${MALFORMED.length} malformed spellings refused, 2 gateway requests`);
  return observations;
}

// --- TLC ------------------------------------------------------------------------

const tla = (address: Address) => `[form |-> "${address.form}", v4 |-> "${address.v4}"]`;
const tlaSet = (addresses: Address[]) => `{${[...new Set(addresses.map(tla))].join(", ")}}`;

function observedModule(observations: Observation[]): string {
  const value = (o: Observation) =>
    `[answers |-> ${tlaSet(o.answers)}, outcome |-> "${o.outcome}", dialed |-> ${tlaSet(o.dialed)}]`;
  return [
    "----------------------- MODULE FetchAdmissionObserved -----------------------",
    "(* Generated by tests/tla/drivers/web/driver.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${observations.map(value).join(",\n  ")} >>`,
    "ObservedAnswerSets == {Observed[i].answers : i \\in DOMAIN Observed}",
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(observations: Observation[], rule: string, parent: string, label: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${label}-`));
  const widest = Math.max(...observations.map((o) => new Set(o.answers.map(tla)).size));
  writeFileSync(join(dir, "FetchAdmissionObserved.tla"), observedModule(observations));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `  V4Classes = {${V4_CLASSES.map((name) => `"${name}"`).join(", ")}}`,
    `  MaxAnswers = ${widest}`,
    "  MaxHops = 1",
    `  Rule = "${rule}"`,
    "  AnswerSets <- ObservedAnswerSets",
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const run = await runTlc(dir, "FetchAdmissionTrace", "trace.cfg", ["FetchAdmission.tla", "FetchAdmissionTrace.tla"],
    join(TLA_ROOT, "web"));
  if (run.exitCode === 12 && run.violated === "NotAllMatched") return { verdict: "ACCEPTED", dir };
  if (run.exitCode === 0 && run.output.includes("No error has been found")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

// The first observation the model cannot produce: the shortest rejected prefix.
async function firstMismatch(observations: Observation[], rule: string, parent: string): Promise<Observation | null> {
  let low = 1;
  let high = observations.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    const { verdict } = await runTrace(observations.slice(0, middle), rule, parent, "bisect");
    if (verdict === "TOOL_ERROR") return null;
    if (verdict === "ACCEPTED") low = middle + 1;
    else high = middle;
  }
  return observations[low - 1] ?? null;
}

// Planted bugs in isPublicIpv6 (src/tools/web/url_policy.zig), each one
// expression of the fix.
const PLANTED: Array<{ name: string; target: string; planted: string }> = [
  {
    name: "no-embedded-check",
    target: "return isPublicIpv4(bytes[12..16].*);",
    planted: "return true;",
  },
  {
    name: "loose-prefix",
    target: "std.mem.eql(u8, bytes[0..12], &nat64_well_known_prefix)",
    planted: "std.mem.eql(u8, bytes[0..4], nat64_well_known_prefix[0..4])",
  },
  {
    name: "wrong-tail",
    target: "return isPublicIpv4(bytes[12..16].*);",
    planted: "return isPublicIpv4(bytes[8..12].*);",
  },
  {
    name: "today",
    target: "if (std.mem.eql(u8, bytes[0..12], &nat64_well_known_prefix)) return isPublicIpv4(bytes[12..16].*);",
    planted: "",
  },
];

async function main(): Promise<number> {
  const out = outDir("web");
  const started = performance.now();
  const sets = cases();
  const lab = buildLab(join(out, "lab"));
  const observations = runLab(lab, join(out, "lab"), sets);
  const binary = await runBinary(out);
  if (binary) observations.push(...binary);
  writeJson(join(out, "observations.json"), observations);
  const counts: Record<string, number> = {};
  for (const o of observations) counts[`${o.source} ${o.outcome}`] = (counts[`${o.source} ${o.outcome}`] ?? 0) + 1;
  console.log(`${observations.length} hops (seed ${options.seed}, ${options.random} random sets) in ` +
    `${((performance.now() - started) / 1000).toFixed(1)}s: ${JSON.stringify(counts)}`);
  console.log(`observations: ${join(out, "observations.json")}`);

  const design = await runTrace(observations, "fixed", out, "design");
  console.log(`design: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const mismatch = await firstMismatch(observations, "fixed", out);
    console.log(`first hop the model cannot produce: ${JSON.stringify(mismatch)}`);
    console.log("REJECTED");
    return 1;
  }

  if (options.selfCheck) {
    const today = await runTrace(observations, "today", out, "today");
    console.log(`self-check, the model of fx before the change: ${today.verdict} (must be REJECTED)`);
    if (today.verdict !== "REJECTED") return today.verdict === "TOOL_ERROR" ? 2 : 1;
    const policy = readFileSync(join(REPO_ROOT, "src", "tools", "web", "url_policy.zig"), "utf8");
    for (const bug of PLANTED) {
      if (!policy.includes(bug.target)) fail(2, `self-check: the target for "${bug.name}" is gone from url_policy.zig`);
      const dir = join(out, `planted-${bug.name}`);
      mkdirSync(dir, { recursive: true });
      const bin = buildLab(dir, (source) => source.replace(bug.target, bug.planted));
      const planted = await runTrace(runLab(bin, dir, sets), "fixed", out, bug.name);
      console.log(`self-check, planted bug ${bug.name}: ${planted.verdict} (must be REJECTED)`);
      if (planted.verdict !== "REJECTED") return planted.verdict === "TOOL_ERROR" ? 2 : 1;
    }
  }
  console.log("ACCEPTED");
  return 0;
}

try {
  process.exit(await main());
} catch (error) {
  console.error(error);
  process.exit(2);
}
