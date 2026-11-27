// Runs the built fx along tests/tla/subagent/ViewWaits.tla for the paths a
// person drives from the view: a hidden kind-E wait lent as a card and
// answered, kind B's model switch (the picker that stands where the card
// would), a stop while the card is lent, the alternate screen over the card,
// and an instance's child.
//
// fx runs in tmux against a local gateway with its trace on. The driver reads
// fx's pane, its trace and the gateway's requests, and checks each against the
// rule the model states for it: ShownWhenFree (the card is the tree's oldest
// live item while the view is free), CardYieldsToPicker (no card for the child
// whose picker is open), ActionReachesOwner and ModelChosen (the choice
// reaches the child and its request continues on the model it took),
// NoStaleShown (a stop never lends the card again), HeldUnderAltScreen, and
// InstanceScope. A step the model does not allow fails with the rule's name.
// The model has no trace spec, so the rules are asserted here by name rather
// than replayed through TLC.
//
//   bun test ./tests/tla/drivers/subagent/view-waits.test.ts
//   FX_BIN=<binary>   drives another build (the fail-before run points it at a
//                     scratch copy of b205b3bfd4)
import { expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, watch } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, targetHelpers, worktree } from "../lib/context";

const TIMEOUT = 120_000;
const SECOND_MODEL = "openai/gpt-5-mini";
const CARD_LENT = "event=wait_card_lent";
const CARD_ANSWERED = "event=wait_card_answered";
/// The trace file in the isolated home; its writes are the signal `watch` waits on.
const TRACE_FILE_NAME = "fx-trace.log";
/// The scopes the driver reads: `host` carries the card's lend and answer,
/// `subagent` and `mailbox` the child's turns. `fx` filters the trace by this,
/// so every scope the driver watches must be named here.
const TRACE_SCOPES = "host,subagent,worker,mailbox,input";

type Helpers = Awaited<ReturnType<typeof targetHelpers>>;
type Session = Awaited<ReturnType<Helpers["TmuxSession"]["create"]>>;
type Gateway = ReturnType<Helpers["startDynamicFakeGateway"]>;
type Obs = { event: string; line: string };
/** One request the gateway answered, as fx sent it. `role` is the subagent
 * the request is for, from fx's own system message, and null for main's. */
type Seen = { body: string; model: string; role: string | null; users: string[] };

function sse(helpers: Helpers, events: object[]): Response {
  return helpers.fakeGatewaySse(events);
}

function text(helpers: Helpers, id: string, delta: string): Response {
  return sse(helpers, [
    { type: "text-delta", id, delta },
    { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
  ]);
}

function spawnTool(helpers: Helpers, id: string, agent: string, message: string): Response {
  return sse(helpers, [
    { type: "tool-call", toolCallId: id, toolName: "subagent", input: { request: { action: "message", agent, message } } },
    { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
  ]);
}

function refused(): Response {
  return new Response(JSON.stringify({
    error: {
      type: "invalid_request_error",
      message: "Gateway-executed tool(s) are not available for this team: gateway.exa_search.",
    },
  }), { status: 400, headers: { "content-type": "application/json" } });
}

function outOfCredits(): Response {
  return new Response(JSON.stringify({
    error: { code: "credit_card_required", message: "Buy credits to use AI Gateway." },
  }), { status: 402, headers: { "content-type": "application/json" } });
}

/** The subagent a request is for, from fx's own system message. The body is
 * JSON, so the name's quotes are escaped. */
function roleOf(body: string): string | null {
  const match = /You are the subagent \\?"([^"\\]+)\\?"/.exec(body);
  return match ? match[1]! : null;
}

/** A request's user messages, in order. */
function usersOf(body: string): string[] {
  const parsed = JSON.parse(body) as { prompt?: Array<{ role?: string; content?: unknown }> };
  return (parsed.prompt ?? [])
    .filter((message) => message.role === "user")
    .map((message) => {
      if (typeof message.content === "string") return message.content;
      if (!Array.isArray(message.content)) return "";
      return message.content.map((part: any) => (typeof part?.text === "string" ? part.text : "")).join("");
    });
}

/** Whether a request is one of main's own, by the marker in its user text. */
function isMain(body: string): boolean {
  return roleOf(body) === null && usersOf(body).some((text) => text.includes("VW_MAIN"));
}

/** Every request the gateway answered, with its model from the header fx
 * sends (`ai-language-model-id`) and the subagent it is for. The body holds
 * only `prompt`, so the model is never read from it. */
function seenRequests(gateway: Gateway): Seen[] {
  return (gateway.requests ?? []).map((entry) => ({
    body: entry.body,
    model: entry.headers.get("ai-language-model-id") ?? "",
    role: roleOf(entry.body),
    users: usersOf(entry.body),
  }));
}

function cardDigit(pane: string, label: string): string {
  const row = pane.split("\n").find((line) => line.includes(label));
  const digit = row ? /([1-9])/.exec(row) : null;
  if (!digit) throw new Error(`no choice "${label}" in:\n${pane}`);
  return digit[1]!;
}

/** A card drawn for `name` with the refused reason. */
const cardShows = (pane: string, name: string) => pane.includes(`${name}: The provider rejected this request`);

/** Runs the check a rule stands for, so a failure starts with the rule's name
 * (`tests/tla/subagent/ViewWaits.tla`). The check itself is unchanged. */
function rule(name: string, check: () => void): void {
  try {
    check();
  } catch (err) {
    throw new Error(`${name}: ${(err as Error).message}`, { cause: err });
  }
}

/** One fx under tmux with its own profile, workspace, gateway and trace. */
class View {
  home = "";
  workspace = "";
  tracePath = "";
  session: Session | null = null;
  gateway: Gateway | null = null;
  mark = 0;

  constructor(readonly helpers: Helpers, readonly respond: (body: string) => Response | Promise<Response>, readonly instances = 1) {}

  async start() {
    const helpers = this.helpers;
    const evals = await import(join(worktree, "tests", "evals", "eval-helpers.ts"));
    // fx's own profile, as the E2E helpers and the agents_menu driver make it.
    this.home = evals.createIsolatedTestHome();
    this.workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-tla-view-ws-")));
    this.tracePath = join(this.home, TRACE_FILE_NAME);
    // The catalog the picker lists: main's model first, the payer's second.
    this.gateway = helpers.startDynamicFakeGateway((body: string) => this.respond(body), {
      models: [
        { id: helpers.FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] },
        { id: SECOND_MODEL, type: "language", tags: ["tool-use"] },
      ],
    });
    this.session = await helpers.TmuxSession.create({
      cmd: binary,
      cwd: this.workspace,
      env: {
        HOME: this.home,
        AI_GATEWAY_API_KEY: "fake-view-waits-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
        FX_MODEL: helpers.FAKE_GATEWAY_MODEL,
        FX_PERMISSION_MODE: "auto",
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
        FX_TRACE_LOG: this.tracePath,
        FX_TRACE_SCOPES: TRACE_SCOPES,
        ...(this.instances > 1 ? { FX_TEST_INSTANCES: String(this.instances) } : {}),
      },
      width: 120,
      height: 40,
    });
    await this.session.waitForComposer(30_000);
  }

  async stop() {
    try {
      await this.session?.kill();
    } finally {
      this.gateway?.stop();
      const evals = await import(join(worktree, "tests", "evals", "eval-helpers.ts"));
      if (this.home) evals.cleanupIsolatedTestHome(this.home);
      if (this.workspace) rmSync(this.workspace, { recursive: true, force: true });
    }
  }

  seen(): Seen[] {
    return this.gateway ? seenRequests(this.gateway) : [];
  }

  /** The models of the requests for subagent `name`, in order. */
  modelsOfChild(name: string): string[] {
    return this.seen().filter((request) => request.role === name).map((request) => request.model);
  }

  /** The models of main's own requests, in order. */
  mainModels(): string[] {
    return this.seen().filter((request) => isMain(request.body)).map((request) => request.model);
  }

  lines(): string[] {
    return existsSync(this.tracePath) ? readFileSync(this.tracePath, "utf8").split("\n") : [];
  }

  /** Lines written since `newMark`, for a check that something must not happen. */
  sinceMark(): string[] {
    return this.lines().slice(this.mark);
  }

  /** The events of `names` written since `newMark`, in order, under `label`,
   * the rule they check. The signal is fx's own write to its trace file: each
   * change event re-reads the lines, so nothing here waits on a clock
   * (`RULES.md` R7.3). */
  async watch(names: string[], label = names.join(", "), ms = 30_000): Promise<Obs[]> {
    const found = () => this.sinceMark().flatMap((line) =>
      names.filter((name) => line.includes(name)).map((event) => ({ event, line })),
    );
    const controller = AbortSignal.timeout(ms);
    const events = watch(this.home, { signal: controller });
    try {
      const already = found();
      if (already.length > 0) return already;
      for await (const event of events) {
        if (String(event.filename ?? "") !== TRACE_FILE_NAME) continue;
        const seen = found();
        if (seen.length > 0) return seen;
      }
    } catch (err) {
      if (!controller.aborted) throw err;
    } finally {
      events.close();
    }
    await this.dump(`${label}: none of ${names.join(", ")} appeared in the trace`);
    throw new Error(`${label}: none of ${names.join(", ")} appeared in the trace`);
  }

  newMark() {
    this.mark = this.lines().length;
  }

  async pane(ms = 30_000): Promise<string> {
    return await this.session!.capturePane();
  }

  /** Waits for the pane to show `value`, under `label`, the rule it checks. */
  async text(value: string, ms = 30_000, label = value): Promise<string> {
    try {
      return await this.session!.waitForText(value, ms);
    } catch (err) {
      throw new Error(`${label}: ${(err as Error).message}`, { cause: err });
    }
  }

  /** Waits for a pane that matches `pattern`, under `what`, the rule it
   * checks, dumping the pane first. */
  async matches(pattern: RegExp, what: string, ms = 30_000): Promise<string> {
    try {
      return await this.session!.waitForPane((pane) => pattern.test(pane), ms);
    } catch (err) {
      await this.dump(`the pane never showed ${what}`);
      throw new Error(`${what}: ${(err as Error).message}`, { cause: err });
    }
  }

  async keys(...keys: string[]) {
    for (const key of keys) await this.session!.sendKeys(key);
  }

  /** Prints the pane and the last trace lines, for a failure's evidence. */
  async dump(why: string) {
    const pane = await this.session?.capturePane().catch(() => "");
    const tail = this.lines().slice(-60).join("\n");
    console.log(`\n===== ${why} =====\n--- pane ---\n${pane ?? ""}\n--- trace tail ---\n${tail}\n===== end =====\n`);
  }
}

test("ViewWaits: a hidden wait is lent as a card, and its answer reaches that subagent", async () => {
  const helpers = await targetHelpers();
  let childCalls = 0;
  const view = new View(helpers, (body) => {
    if (roleOf(body) === "reviewer") {
      childCalls += 1;
      return childCalls === 1 ? refused() : text(helpers, "child_done", "VW_RETRY_DONE");
    }
    if (!body.includes('"vw_spawn"')) {
      return spawnTool(helpers, "vw_spawn", "reviewer", "VW_TASK");
    }
    return text(helpers, "main_done", "VW_MAIN_DONE");
  });
  try {
    await view.start();
    view.newMark();
    await view.session!.sendText("VW_MAIN start it");
    await view.text("VW_MAIN_DONE");
    // ShownWhenFree: the refused wait is the tree's oldest live item, so the
    // view shows it as a card named for the subagent.
    const pane = await view.matches(/reviewer: The provider rejected this request/, "ShownWhenFree: the refused wait is shown as its card");
    rule("FooterQuietForShown: no needs you for the shown card", () => expect(pane).not.toContain("reviewer needs you"));
    const lent = await view.watch([CARD_LENT], "ShownWhenFree: the card's lend in the trace");
    rule("ShownWhenFree: the lend names the child", () => expect(lent.some((obs) => obs.line.includes("agent="))).toBe(true));
    // ActionReachesOwner: the card's answer reaches the child, and its request
    // runs again.
    await view.keys(cardDigit(pane, "Retry"));
    const answered = await view.watch([CARD_ANSWERED], "ActionReachesOwner: the card's answer reaches the child");
    rule("ActionReachesOwner: the answer is the card's retry", () => expect(answered.some((obs) => obs.line.includes("choice=retry"))).toBe(true));
    // The child's reply reaches main as its report; the view says it finished.
    await view.matches(/reviewer finished/, "ActionReachesOwner: the child's request runs again");
    rule("ActionReachesOwner: the child asked twice", () => expect(childCalls).toBe(2));
  } catch (err) {
    await view.dump("ShownWhenFree and ActionReachesOwner: a hidden wait is lent as a card");
    throw err;
  } finally {
    await view.stop();
  }
}, TIMEOUT);

test("ViewWaits: the picker a subagent's answer opens holds its card, and the choice continues its request", async () => {
  const helpers = await targetHelpers();
  let childCalls = 0;
  // Main's next request, as the gateway sees it: the promise the fake gateway
  // resolves is the signal that main's turn reached the wire.
  let resolveAfterMain: () => void = () => {};
  const afterMain = new Promise<void>((resolve) => {
    resolveAfterMain = resolve;
  });
  const view = new View(helpers, (body) => {
    if (roleOf(body) === "payer") {
      childCalls += 1;
      return childCalls === 1 ? outOfCredits() : text(helpers, "child_done", "VW_PAYER_DONE");
    }
    if (isMain(body) && usersOf(body).some((message) => message.includes("VW_MAIN after it"))) {
      resolveAfterMain();
    }
    if (!body.includes('"vw_payer"')) {
      return spawnTool(helpers, "vw_payer", "payer", "VW_PAYER_TASK");
    }
    return text(helpers, "main_done", "VW_MAIN_DONE");
  });
  try {
    await view.start();
    await view.session!.sendText("VW_MAIN start it");
    await view.text("VW_MAIN_DONE");
    const question = await view.matches(/Switch to another model/, "ShownWhenFree: the out-of-credits picker is shown");
    rule("FooterQuietForShown: no needs you for the shown picker", () => expect(question).not.toContain("payer needs you"));
    // CardYieldsToPicker: from the answer that queues the picker, the card is
    // not lent for the child whose picker is open.
    view.newMark();
    await view.keys(cardDigit(question, "Switch to another model"));
    // The out-of-credits picker is the child's own question prompt, lent, so
    // its answer is recorded there and what opens is the model picker.
    const picker = await view.text("/model", 30_000, "CardYieldsToPicker: the model picker opens");
    rule("CardYieldsToPicker: no card under the picker", () => expect(picker).not.toContain("payer: Out of credits"));
    // The picker's own list is drawn, so the frame that could have lent the
    // card has run with the picker holding the item.
    await view.matches(/openai\/gpt-5-mini/, "CardYieldsToPicker: the picker's own list is drawn", 25_000);
    rule("CardYieldsToPicker: no card lent while the picker holds the item", () =>
      expect(view.sinceMark().some((line) => line.includes(CARD_LENT))).toBe(false));
    // The picker lists main's model first: the second is the payer's.
    await view.keys("Down", "Enter");
    await view.matches(new RegExp(`payer continues with ${SECOND_MODEL}`), "ModelChosen: the payer continues with the model the picker took", 25_000);
    // ModelChosen: the wait continued with the model the picker took.
    await view.matches(/payer finished/, "ModelChosen: the payer's request runs again");
    rule("ActionReachesOwner: the payer asked twice", () => expect(childCalls).toBe(2));
    const childModels = view.modelsOfChild("payer");
    rule("ModelChosen: the payer asked again on a model", () => expect(childModels.length).toBeGreaterThanOrEqual(2));
    rule("ModelChosen: the payer's last request names the picked model", () => expect(childModels.at(-1)).toBe(SECOND_MODEL));
    rule("ModelChosen: the payer's request changed model", () => expect(childModels.at(-1)).not.toBe(childModels[0]!));
    // And the screen's own model is untouched: main's next turn keeps it.
    const mainBefore = view.mainModels().length;
    await view.session!.sendText("VW_MAIN after it");
    await afterMain;
    rule("ModelChosen: main's next turn runs", () => expect(view.mainModels().length).toBeGreaterThan(mainBefore));
    rule("ModelChosen: main's own model is untouched", () => expect(view.mainModels().at(-1)).toBe(helpers.FAKE_GATEWAY_MODEL));
  } catch (err) {
    await view.dump("CardYieldsToPicker: the picker holds the card");
    throw err;
  } finally {
    await view.stop();
  }
}, TIMEOUT);

test("ViewWaits: a stop while the card is lent takes it away for good", async () => {
  const helpers = await targetHelpers();
  const view = new View(helpers, (body) => {
    if (roleOf(body) === "stuck") return refused();
    if (!body.includes('"vw_stuck"')) {
      return spawnTool(helpers, "vw_stuck", "stuck", "VW_STUCK_TASK");
    }
    return text(helpers, "main_done", "VW_MAIN_DONE");
  });
  try {
    await view.start();
    await view.session!.sendText("VW_MAIN start it");
    await view.text("VW_MAIN_DONE");
    const pane = await view.matches(/stuck: The provider rejected this request/, "ShownWhenFree: stuck's card is shown");
    view.newMark();
    await view.keys(cardDigit(pane, "Stop stuck"));
    // NoStaleShown: the card's stop closes the child, and the card is gone and
    // never lent again for it.
    const after = await view.matches(
      /^(?!.*stuck: The provider rejected this request)(?!.*Open stuck's screen).*$/s,
      "NoStaleShown: the card leaves after the stop",
    );
    rule("NoStaleShown: the stopped child's card is gone", () => expect(cardShows(after, "stuck")).toBe(false));
    // Main's transcript carries the cancellation the stop wrote, so the pass
    // that closed the child has run and nothing lends that child's card again.
    await view.text("stuck was cancelled", 30_000, "NoStaleShown: the pass that closed the child has run");
    rule("NoStaleShown: no card lent again for the stopped child", () =>
      expect(view.sinceMark().some((line) => line.includes(CARD_LENT))).toBe(false));
    rule("NoStaleShown: no needs you for the stopped child", () => expect(after).not.toContain("stuck needs you"));
  } catch (err) {
    await view.dump("NoStaleShown: a stop while the card is lent");
    throw err;
  } finally {
    await view.stop();
  }
}, TIMEOUT);

test("ViewWaits: the alternate screen hides the card, and it comes back", async () => {
  const helpers = await targetHelpers();
  const view = new View(helpers, (body) => {
    if (roleOf(body) === "hidden") return refused();
    if (!body.includes('"vw_hidden"')) {
      return spawnTool(helpers, "vw_hidden", "hidden", "VW_HIDDEN_TASK");
    }
    return text(helpers, "main_done", "VW_MAIN_DONE");
  });
  try {
    await view.start();
    await view.session!.sendText("VW_MAIN start it");
    await view.text("VW_MAIN_DONE");
    await view.matches(/hidden: The provider rejected this request/, "ShownWhenFree: hidden's card is shown");
    // HeldUnderAltScreen: Ctrl+O draws the transcript with no card.
    await view.keys("C-o");
    const transcript = await view.text("esc close · pgup/pgdn scroll", 30_000, "HeldUnderAltScreen: the transcript owns the alternate screen");
    rule("HeldUnderAltScreen: no card under the transcript", () => expect(transcript).not.toContain("Open hidden's screen"));
    rule("HeldUnderAltScreen: no card's stop under the transcript", () => expect(transcript).not.toContain("Stop hidden"));
    await view.keys("C-o");
    // And the card returns once the alternate screen closes.
    await view.matches(/hidden: The provider rejected this request/, "HeldUnderAltScreen: the card returns when the alternate screen closes");
  } catch (err) {
    await view.dump("HeldUnderAltScreen: the alternate screen over the card");
    throw err;
  } finally {
    await view.stop();
  }
}, TIMEOUT);

test("ViewWaits: an instance's child shows in that instance's view only", async () => {
  const helpers = await targetHelpers();
  const view = new View(helpers, (body) => {
    if (roleOf(body) === "scoped") return refused();
    if (!body.includes('"vw_scoped"')) {
      return spawnTool(helpers, "vw_scoped", "scoped", "VW_SCOPED_TASK");
    }
    return text(helpers, "main_done", "VW_MAIN_DONE");
  }, 2);
  try {
    await view.start();
    // The second instance starts the subagent, so the wait is fx 2's.
    await view.keys("C-x");
    await view.text("enter switch", 10_000);
    await view.keys("Down", "Enter");
    await view.session!.sendText("VW_MAIN start it");
    await view.text("VW_MAIN_DONE");
    await view.matches(/scoped: The provider rejected this request/, "InstanceScope: fx 2 shows its child's card");
    // Back on fx 1: InstanceScope, nothing of fx 2's item shows there.
    await view.keys("C-x");
    await view.text("enter switch", 10_000);
    await view.keys("Up", "Enter");
    const first = await view.pane();
    rule("InstanceScope: fx 1 shows nothing of fx 2's item", () => expect(cardShows(first, "scoped")).toBe(false));
    // fx 2 shows its card.
    await view.keys("C-x");
    await view.text("enter switch", 10_000);
    await view.keys("Down", "Enter");
    await view.matches(/scoped: The provider rejected this request/, "InstanceScope: fx 2 shows its card again");
  } catch (err) {
    await view.dump("InstanceScope: an instance's child");
    throw err;
  } finally {
    await view.stop();
  }
}, TIMEOUT);
