// Runtime bridge for the compaction audience driver: one plan's isolated home and
// workspace, the fx acp processes it starts, the fake Gateway's compaction replies,
// and the mapping from what fx wrote to the messages AcpCompactionAudience.tla names.
// The frames come from ../join/harness.ts and the stdio client from ../disconnect/harness.ts.
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { testEnvironment } from "../../lib/context";
import { Acp } from "../disconnect/harness";
import { isAgentText } from "../join/harness";

export { Acp };

/// The done line the terminal writes once a compaction completes, as fx sends it in an agent message.
const DONE_LINE = /^Context compacted \([0-9hms]+\)$/;
/// The sentence fx's compactor writes into its summary request, which a turn never sends.
export const SUMMARY_SENTENCE = "Write the compaction notes for";
export const SUMMARY_TEXT = "Retain the notes the turn read.";
/// The reply of the turn that runs after the compaction.
export const FINAL_TEXT = "ACP_AFTER_COMPACTION";
/// About 30,000 estimated tokens: past 20 percent of the model's input, well short of the default 80 percent.
export const LARGE_TEXT = "ACP_LARGE_REPLY\n" + "historical reference line, not new completed work.\n".repeat(2_400);

/// Capabilities at initialize for a client that lists session.compaction, and one that does not.
export const LISTING = { session: { compaction: {} }, _meta: {} };
export const PLAIN = { _meta: {} };

export const ENDS = ["completed", "failed", "cancelled"] as const;

/// The compaction message a frame from fx carries: a compaction_update's status, or the
/// done line. Any other frame carries none.
export function compactionMessage(frame: any): "in_progress" | "completed" | "failed" | "cancelled" | "done" | null {
  if (frame?.method !== "session/update") return null;
  const update = frame.params?.update;
  if (update?.sessionUpdate === "compaction_update") return update.status;
  if (isAgentText(frame) && DONE_LINE.test(update.content?.text ?? "")) return "done";
  return null;
}

/// Whether a frame is the turn's final reply text.
export function isFinalText(frame: any): boolean {
  return isAgentText(frame) && (frame.params.update.content?.text ?? "").includes(FINAL_TEXT);
}

/// A reply without provider usage, so fx sizes the conversation by its own estimate.
export function compactingReply(helpers: any, text: string) {
  return helpers.fakeGatewaySse([
    { type: "text-delta", id: "answer_1", delta: text },
    { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
  ]);
}

/// The fake Gateway's model catalog, with a context window large enough for the reply.
export function compactingModels(helpers: any) {
  return [{ id: helpers.FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"], context_window: 128_000 }];
}

/// One plan's home and workspace, and the fx acp processes it starts. A process gets its
/// own TMPDIR, so its leader socket goes under the plan's root, and FX_AUTO_COMPACT_PERCENT
/// makes the large reply trigger a compaction on the next prompt.
export class CompactionFixture {
  readonly root: string;
  readonly home: string;
  readonly workspace: string;
  /// fx's debug trace of the run, which records each compaction decision.
  readonly traceLog: string;
  private tmpdirs = 0;

  constructor(private readonly fxBin: string, private readonly model: string) {
    this.root = realpathSync(mkdtempSync(join("/tmp", "fx-compaction-audience-")));
    this.home = join(this.root, "home");
    this.workspace = join(this.root, "workspace");
    this.traceLog = join(this.root, "fx-trace.log");
    mkdirSync(join(this.home, ".fx"), { recursive: true, mode: 0o700 });
    mkdirSync(this.workspace, { recursive: true, mode: 0o700 });
    writeFileSync(join(this.home, ".fx", "settings.json"), `${JSON.stringify({ session_titles: false })}\n`, { mode: 0o600 });
    writeFileSync(join(this.workspace, "notes.md"), "recorded notes\n");
  }

  spawn(gateway: { baseUrl: string; chatUrl: string }): Acp {
    this.tmpdirs += 1;
    const tmpdir = join(this.root, `tmp-${this.tmpdirs}`);
    mkdirSync(tmpdir, { recursive: true, mode: 0o700 });
    const env = testEnvironment({
      NO_COLOR: "1",
      HOME: this.home,
      AI_GATEWAY_API_KEY: "acp-compaction-fake-key",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_MODEL: this.model,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_AUTO_COMPACT_PERCENT: "20",
      FX_TRACE_LOG: this.traceLog,
      TMPDIR: tmpdir,
    });
    const proc = Bun.spawn([this.fxBin, "acp"], { cwd: this.workspace, env, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    return new Acp(proc);
  }

  dispose() {
    rmSync(this.root, { recursive: true, force: true });
  }
}
