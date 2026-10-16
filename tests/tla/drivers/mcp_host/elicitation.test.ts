// ElicitationRouting: a real `fx ask` in a terminal (tmux; fx ask asks MCP
// questions only with a terminal) whose fake-gateway model calls the 2025
// fixture's `elicit` tool. The fixture asks question 1, and once the harness
// sees it on screen, withdraws it (notifications/cancelled) and asks question
// 2, which the client's slot table puts in question 1's slot. The harness
// then answers what it saw: "for-1". The fixture's log says which question
// got which answer. Checked against ElicitationRouting.tla.
//
// An earlier fx gave question 2 the answer "for-1". Now it is the contract:
// the answer to the withdrawn question reaches no one, and question 2 gets its
// own, which the model with its guard accepts.
import { expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, shellQuote, targetHelpers } from "../lib/context";
import { fixture, fxEnv, save, serverEvents, stdioServer, waitFor, writeProfile } from "./driver";
import { checkTrace, type TraceRecord } from "./trace";

const TOOL = "mcp_fixture_elicit";

test("An answer to a withdrawn 2025 question reaches no one, and question 2 gets its own (trace ACCEPTED with the guard)", async () => {
  const f = fixture(artifacts, "elicit-slot-reuse");
  writeProfile(f, { fixture: stdioServer(f, "fixture") });
  const { TmuxSession, startFakeGateway, fakeGatewayToolCall, fakeGatewayFinalText } = await targetHelpers();
  const gateway = startFakeGateway([
    fakeGatewayToolCall("select", "mcp_select_tool", { name: TOOL }),
    fakeGatewayToolCall("call", TOOL, {}),
    fakeGatewayFinalText("ELICIT_TURN_DONE"),
  ], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
  const env = fxEnv(f, { FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5", FX_PERMISSION_MODE: "full-access" });
  const tui = await TmuxSession.create({
    cmd: `${shellQuote(binary)} ask --no-save ${shellQuote("Use the fixture's elicit tool.")}`,
    // No stderrPath: fx ask declares elicitation only when stdin and stderr are a terminal.
    cwd: f.workspace, env, isolated: true, width: 160, height: 40, remainOnExit: true,
  });
  const records: TraceRecord[] = [];
  const panes: { at: number; label: string; pane: string }[] = [];
  const snap = async (label: string) => { const pane = await tui.capturePane(); panes.push({ at: Date.now(), label, pane }); return pane; };
  const ev = (name: string) => serverEvents(f).filter((e) => e.ev === name);
  let two = false;
  try {
    await waitFor("question 1 sent", () => ev("ask").length >= 1, 30_000);
    await tui.waitForText(/Answer 1|Question 1|question 1/, 15_000);
    records.push({ event: "shown", data: { q: 1 }, at: Date.now() });
    await snap("question 1 on screen");
    writeFileSync(join(f.control, "go"), "go\n");
    await waitFor("question 2 sent", () => ev("ask").length >= 2, 10_000);
    await Bun.sleep(700);
    await snap("after the withdrawal and question 2");
    await tui.sendText("for-1");
    // fx reviews the form before it goes: Submit is choice 1.
    await tui.waitForText("Choose Submit, Edit, Decline, or Cancel.", 10_000);
    await snap("question 1 review");
    records.push({ event: "answer", data: { q: 1 }, at: Date.now() });
    await tui.sendText("1");
    // fx may show question 2 next; answer what is on screen, naming it.
    two = await tui.waitForText(/Answer 2|Question 2|question 2/, 6_000).then(() => true, () => false);
    if (two) {
      records.push({ event: "shown", data: { q: 2 }, at: Date.now() });
      await snap("question 2 on screen");
      await tui.sendText("for-2");
      await tui.waitForText(/Answer 2: "for-2"[\s\S]*Choose Submit/, 10_000).catch(() => undefined);
      records.push({ event: "answer", data: { q: 2 }, at: Date.now() });
      await tui.sendText("1");
    }
    await waitFor("the call's result", () => ev("call_end").length === 1, 40_000);
    await tui.waitForText("ELICIT_TURN_DONE", 20_000).catch(() => undefined);
    await snap("end");
  } finally {
    save(join(f.base, "panes.json"), panes);
    await tui.kill();
    gateway.stop();
  }
  const events = serverEvents(f);
  for (const e of events) {
    if (e.ev === "ask") records.push({ event: "ask", data: { q: e.q as number }, at: e.t });
    if (e.ev === "withdraw") records.push({ event: "withdraw", data: { q: e.q as number }, at: e.t });
    if (e.ev === "answered") {
      const target = e.id === "e1" ? 1 : 2;
      const content = (e.result as { action?: string; content?: { answer?: string } } | null);
      const from = /^for-(\d)$/.exec(content?.content?.answer ?? "")?.[1];
      records.push({ event: "delivered", data: { target, from: from ? Number(from) : target }, at: e.t, note: JSON.stringify(e.result) });
    }
    if (e.ev === "call_end") records.push({ event: "call_end", at: e.t });
  }
  records.sort((a, b) => (a.at ?? 0) - (b.at ?? 0));
  const verdict = await checkTrace({ module: "ElicitationRouting", records, dir: join(f.base, "trace"), constants: { ObsVersions: ["2025"], ObsMaxQ: 2, ObsSlots: 2, ObsGuard: true } });
  save(join(f.base, "verdict.json"), verdict);
  // Independent oracle: what reached question 2 on the wire.
  const toTwo = events.find((e) => e.ev === "answered" && e.id === "e2");
  save(join(f.base, "wire.json"), { toTwo, all: events.filter((e) => ["ask", "withdraw", "answered", "call_end"].includes(e.ev)) });
  expect(two).toBe(true);
  expect(toTwo).toBeDefined();
  expect((toTwo!.result as { content?: { answer?: string } }).content?.answer).toBe("for-2");
  expect(events.filter((e) => e.ev === "answered" && e.id === "e1")).toEqual([]);
  expect(verdict.verdict).toBe("ACCEPTED");
}, 180_000);
