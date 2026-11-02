import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  cleanupWorkDir,
  createWorkDir,
  runEval,
  runFx,
} from "./eval-helpers";

const TIMEOUT = 120_000;
// Format evals can spend a tool round inspecting before they answer.
const FORMAT_TIMEOUT = 180_000;
let workDir: string | null = null;

afterEach(() => {
  if (workDir) { cleanupWorkDir(workDir); workDir = null; }
});

// GFM accepts a single dash per delimiter cell, with optional alignment colons.
const TABLE_DELIMITER_ROW = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)+\|?\s*$/m;
const HEADING = /^#{1,6}\s/m;

// fx shows fenced content as a code block, so fenced tables and comment
// lines are neither rendered tables nor headings.
function withoutFencedCode(text: string): string {
  return text.replace(/^\s*(```|~~~)[\s\S]*?^\s*\1\s*$/gm, "");
}

describe("eval: system prompt override", () => {
  test(
    "agent respects custom system prompt personality",
    async () => {
      workDir = createWorkDir();

      const result = await runFx(
        [
          "ask", "--auto", "--json", "--no-save",
          "--system", "You are a pirate. You must use pirate language like 'Arrr', 'matey', 'ye', 'ahoy', or 'shiver me timbers' in every response.",
          "Say hello and introduce yourself in one sentence.",
        ],
        { cwd: workDir, timeoutMs: 60_000 },
      );

      expect(result.code).toBe(0);
      const json = JSON.parse(result.stdout.trim());
      const output = json.output.toLowerCase();
      const hasPirateLanguage =
        output.includes("arrr") ||
        output.includes("matey") ||
        output.includes("ahoy") ||
        output.includes("ye ") ||
        output.includes("shiver") ||
        output.includes("pirate");
      expect(hasPirateLanguage).toBe(true);
    },
    TIMEOUT,
  );
});

describe("eval: default system prompt response format", () => {
  test(
    "a comparison across several attributes comes back as a Markdown table",
    async () => {
      workDir = createWorkDir();
      const result = await runEval(
        "Compare TCP, UDP, and QUIC by reliability, ordering, connection setup, and typical use cases.",
        { cwd: workDir, timeoutSec: 150 },
      );
      expect(result.json.exit_code).toBe(0);
      expect(withoutFencedCode(result.json.output)).toMatch(TABLE_DELIMITER_ROW);
      expect(result.json.output).toContain("QUIC");
    },
    FORMAT_TIMEOUT,
  );

  test(
    "structured data read from the workspace comes back as a Markdown table",
    async () => {
      workDir = createWorkDir();
      const services = [
        { name: "billing", port: 8081, owner: "payments", language: "Go" },
        { name: "search", port: 8082, owner: "discovery", language: "Rust" },
        { name: "notify", port: 8083, owner: "platform", language: "TypeScript" },
      ];
      mkdirSync(join(workDir, "services"));
      for (const service of services) {
        writeFileSync(
          join(workDir, "services", `${service.name}.json`),
          JSON.stringify(service, null, 2) + "\n",
        );
      }
      const result = await runEval(
        "List every service defined in services/ with its name, port, owner, and language.",
        { cwd: workDir, timeoutSec: 150 },
      );
      expect(result.json.exit_code).toBe(0);
      const output = result.json.output;
      expect(withoutFencedCode(output)).toMatch(TABLE_DELIMITER_ROW);
      for (const service of services) expect(output).toContain(service.name);
    },
    FORMAT_TIMEOUT,
  );

  test(
    "a simple question stays in plain sentences",
    async () => {
      workDir = createWorkDir();
      const result = await runEval(
        "What does the -r flag do for cp?",
        { cwd: workDir, timeoutSec: 150 },
      );
      expect(result.json.exit_code).toBe(0);
      const output = result.json.output;
      expect(output.toLowerCase()).toContain("recursive");
      expect(withoutFencedCode(output)).not.toMatch(TABLE_DELIMITER_ROW);
      expect(withoutFencedCode(output)).not.toMatch(HEADING);
    },
    FORMAT_TIMEOUT,
  );
});
