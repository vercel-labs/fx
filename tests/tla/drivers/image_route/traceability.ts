// The traceability check: design/DESIGN.md must account for every review
// question, every rule, and every law, and each enforcement entry must name
// something that exists.
//
// Enforcement entries are backticked tokens in the last column of the rule
// and law tables under "## Enforcement":
//   inv:Name        an invariant defined in ImageRoute.tla and listed in MCImageRoute.cfg
//   prop:Name       a property defined in ImageRoute.tla and listed in MCImageRoute.cfg
//   trace:Name      a check TraceImageRoute.cfg lists, run on traces of the real core
//   mutation:ID     a planted bug in mutations.json
//   zig:path#name   a `test "name"` block in that Zig file
//   e2e:path#name, sdk:path#name   a test whose source contains that name
//   driver:name     a driver stage: spec-to-code, code-to-spec, or binary-to-spec
//   review:text     how a check that cannot be automated is enforced instead
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT } from "../lib/tlc.ts";
import { MODEL_DIR, SPEC_DIR, configNames } from "./lib.ts";
import { mutations } from "./mutations.ts";

export type Traceability = { problems: string[]; rules: number; laws: number; questions: number; entries: number };

function section(text: string, heading: string): string {
  const start = text.indexOf(`\n## ${heading}\n`);
  if (start < 0) return "";
  const rest = text.slice(start + heading.length + 5);
  const end = rest.search(/\n## /);
  return end < 0 ? rest : rest.slice(0, end);
}

function rows(text: string, prefix: string): string[][] {
  return text.split("\n")
    .filter((line) => new RegExp(`^\\|\\s*${prefix}\\d+\\s*\\|`).test(line))
    .map((line) => line.split("|").slice(1, -1).map((cell) => cell.trim()));
}

export function checkTraceability(designPath = join(MODEL_DIR, "design", "DESIGN.md")): Traceability {
  const problems: string[] = [];
  const design = readFileSync(designPath, "utf8");
  const spec = readFileSync(join(SPEC_DIR, "ImageRoute.tla"), "utf8");
  const traceSpec = readFileSync(join(SPEC_DIR, "TraceImageRoute.tla"), "utf8");
  const model = configNames();
  const trace = configNames(readFileSync(join(SPEC_DIR, "TraceImageRoute.cfg"), "utf8"));
  const mutationIds = new Set([...mutations.spec, ...mutations.code].map((m) => m.id));
  const defined = (text: string, name: string) => new RegExp(`^${name} ==`, "m").test(text);
  const referenced = new Set<string>();
  let entries = 0;

  const checkToken = (owner: string, token: string) => {
    entries += 1;
    const colon = token.indexOf(":");
    const kind = token.slice(0, colon);
    const value = token.slice(colon + 1).trim();
    const fileTest = () => {
      const [path, name] = value.split("#");
      const file = join(REPO_ROOT, path ?? "");
      if (!path || !name || !existsSync(file)) return problems.push(`${owner}: ${token} names a file that does not exist`);
      const source = readFileSync(file, "utf8");
      const found = kind === "zig" ? source.includes(`test "${name}"`) : source.includes(name);
      if (!found) problems.push(`${owner}: ${token} names a test that does not exist`);
    };
    switch (kind) {
      case "inv":
        referenced.add(value);
        if (!defined(spec, value)) problems.push(`${owner}: ${token} is not defined in ImageRoute.tla`);
        if (!model.invariants.includes(value)) problems.push(`${owner}: ${token} is not an INVARIANT in MCImageRoute.cfg`);
        break;
      case "prop":
        referenced.add(value);
        if (!defined(spec, value)) problems.push(`${owner}: ${token} is not defined in ImageRoute.tla`);
        if (!model.properties.includes(value)) problems.push(`${owner}: ${token} is not a PROPERTY in MCImageRoute.cfg`);
        break;
      case "trace":
        if (!defined(traceSpec, value)) problems.push(`${owner}: ${token} is not defined in TraceImageRoute.tla`);
        if (![...trace.invariants, ...trace.properties].includes(value)) problems.push(`${owner}: ${token} is not checked by TraceImageRoute.cfg`);
        break;
      case "mutation":
        if (!mutationIds.has(value)) problems.push(`${owner}: ${token} is not in mutations.json`);
        break;
      case "zig":
      case "e2e":
      case "sdk":
        fileTest();
        break;
      case "driver":
        if (!["spec-to-code", "code-to-spec", "binary-to-spec"].includes(value)) problems.push(`${owner}: ${token} is not a driver stage`);
        break;
      case "review":
        if (value.length < 20) problems.push(`${owner}: ${token} must say how it is enforced`);
        break;
      default:
        problems.push(`${owner}: ${token} has an unknown kind`);
    }
  };
  const tokens = (cell: string | undefined) => [...(cell ?? "").matchAll(/`([a-z]+:[^`]+)`/g)].map((m) => m[1]!);

  // Every review question is answered or listed as not applicable.
  const answers = section(design, "Questions");
  const answered = new Set([...answers.matchAll(/^- Q(\d+)\b/gm)].map((m) => Number(m[1])));
  const notApplicable = /^Not applicable:(.*)$/m.exec(answers)?.[1] ?? "";
  const skipped = new Set([...notApplicable.matchAll(/Q(\d+)/g)].map((m) => Number(m[1])));
  for (let q = 1; q <= 39; q += 1) {
    if (answered.has(q) && skipped.has(q)) problems.push(`Q${q} is both answered and listed as not applicable`);
    if (!answered.has(q) && !skipped.has(q)) problems.push(`Q${q} is neither answered nor listed as not applicable`);
  }

  const enforcement = section(design, "Enforcement");
  // Every rule has one row with a status; an applicable one names its checks.
  const ruleRows = rows(enforcement, "R");
  for (let r = 1; r <= 11; r += 1) {
    const matches = ruleRows.filter((row) => row[0] === `R${r}`);
    if (matches.length !== 1) { problems.push(`R${r} needs exactly one row under Enforcement, found ${matches.length}`); continue; }
    const [, status, reason, enforced] = matches[0]!;
    if (!["pass", "fail", "n/a"].includes(status ?? "")) problems.push(`R${r} has status "${status}", not pass, fail, or n/a`);
    if (!reason) problems.push(`R${r} gives no reason`);
    const found = tokens(enforced);
    if (status !== "n/a" && found.length === 0) problems.push(`R${r} applies but names no enforcement`);
    for (const token of found) checkToken(`R${r}`, token);
  }

  // Every law the design states has a row, enforced by the model or a test.
  const lawIds = [...section(design, "Laws").matchAll(/^- \*\*(L\d+)\b/gm)].map((m) => m[1]!);
  if (lawIds.length === 0) problems.push("the Laws section states no laws");
  const lawRows = rows(enforcement, "L");
  for (const id of lawIds) {
    const matches = lawRows.filter((row) => row[0] === id);
    if (matches.length !== 1) { problems.push(`${id} needs exactly one row under Enforcement, found ${matches.length}`); continue; }
    const found = tokens(matches[0]!.at(-1));
    if (found.length === 0) problems.push(`${id} names no enforcement`);
    for (const token of found) checkToken(id, token);
  }
  for (const row of lawRows) if (!lawIds.includes(row[0]!)) problems.push(`${row[0]} has an enforcement row but is not stated under Laws`);

  // Every check the model runs belongs to a rule or a law.
  for (const name of [...model.invariants, ...model.properties]) {
    if (name !== "TypeOK" && !referenced.has(name)) problems.push(`MCImageRoute.cfg checks ${name}, which no rule or law names`);
  }
  return { problems, rules: ruleRows.length, laws: lawIds.length, questions: answered.size + skipped.size, entries };
}
