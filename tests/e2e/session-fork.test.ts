import { describe, expect, test } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { fakeGatewayFinalText, startFakeGateway } from "./tmux-helpers";

const TIMEOUT = 60_000;

function sessionFileSnapshot(sessionDir: string): Record<string, string> {
  return Object.fromEntries(
    readdirSync(sessionDir, { withFileTypes: true })
      .filter((entry) => entry.isFile())
      .sort((left, right) => left.name.localeCompare(right.name))
      .map((entry) => [
        entry.name,
        readFileSync(join(sessionDir, entry.name)).toString("base64"),
      ]),
  );
}

function makeWorkspace(prefix: string) {
  const root = mkdtempSync(join(tmpdir(), prefix));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  return { root, home, workspaceRoot: realpathSync(workspace) };
}

async function seedSession(
  workspaceRoot: string,
  home: string,
  answers: string[],
): Promise<string> {
  const gateway = startFakeGateway(
    answers.map((answer) => fakeGatewayFinalText(answer)),
  );
  try {
    let sessionId = "";
    for (const [index, answer] of answers.entries()) {
      const args =
        index === 0
          ? ["ask", "--json", "--auto", `prompt for ${answer}`]
          : [
              "ask",
              "--json",
              "--auto",
              "--resume",
              "last",
              `prompt for ${answer}`,
            ];
      const run = await runFx(args, {
        cwd: workspaceRoot,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "e2e-placeholder",
          VERCEL_OIDC_TOKEN: "",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
      });
      expect(run.code).toBe(0);
      sessionId = JSON.parse(run.stdout).session_id;
    }
    return sessionId;
  } finally {
    gateway.stop?.();
  }
}

async function sessionDetail(
  workspaceRoot: string,
  home: string,
  sessionId: string,
) {
  const detail = await runFx(["session", "--id", sessionId, "--json"], {
    cwd: workspaceRoot,
    env: { HOME: home },
  });
  expect(detail.code).toBe(0);
  return JSON.parse(detail.stdout);
}

function promptTexts(detail: { history: { user: { text: string } }[] }) {
  return detail.history.map((turn) => turn.user.text);
}

describe("session fork", () => {
  test(
    "fork branches a turn prefix into a new session and leaves the source unchanged",
    async () => {
      const { root, home, workspaceRoot } = makeWorkspace("fx-session-fork-");
      try {
        const sessionId = await seedSession(workspaceRoot, home, [
          "ONE",
          "TWO",
          "THREE",
          "FOUR",
        ]);
        const sessionDir = join(home, ".fx", "sessions", sessionId);
        const sourceBefore = sessionFileSnapshot(sessionDir);

        const fork = await runFx(
          ["session", "fork", sessionId, "--at", "2"],
          { cwd: workspaceRoot, env: { HOME: home } },
        );
        expect(fork.code).toBe(0);
        expect(fork.stderr).toBe("");
        const forkedId = fork.stdout.match(/ to (\S+)/)![1]!;
        expect(forkedId).not.toBe(sessionId);
        expect(fork.stdout).toBe(
          `[session fork] forked ${sessionId} to ${forkedId}\n` +
            "history_turns: 2 of 4\n" +
            `resume: fx --resume ${forkedId}\n`,
        );

        expect(sessionFileSnapshot(sessionDir)).toEqual(sourceBefore);

        const forkedDetail = await sessionDetail(workspaceRoot, home, forkedId);
        expect(forkedDetail.history_len).toBe(2);
        expect(promptTexts(forkedDetail)).toEqual([
          "prompt for ONE",
          "prompt for TWO",
        ]);

        const sourceDetail = await sessionDetail(
          workspaceRoot,
          home,
          sessionId,
        );
        expect(sourceDetail.history_len).toBe(4);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "a forked session resumes and continues from its branch point",
    async () => {
      const { root, home, workspaceRoot } = makeWorkspace(
        "fx-session-fork-resume-",
      );
      try {
        const sessionId = await seedSession(workspaceRoot, home, [
          "ONE",
          "TWO",
          "THREE",
        ]);
        const fork = await runFx(
          ["session", "fork", "--id", sessionId, "--at", "1", "--json"],
          { cwd: workspaceRoot, env: { HOME: home } },
        );
        expect(fork.code).toBe(0);
        const forkedId = JSON.parse(fork.stdout).forked_id;

        const gateway = startFakeGateway([
          fakeGatewayFinalText("BRANCH_CONTINUED"),
        ]);
        try {
          const resumed = await runFx(
            ["ask", "--json", "--auto", "--resume", forkedId, "keep going"],
            {
              cwd: workspaceRoot,
              env: {
                HOME: home,
                AI_GATEWAY_API_KEY: "e2e-placeholder",
                VERCEL_OIDC_TOKEN: "",
                FX_GATEWAY_BASE_URL: gateway.baseUrl,
                FX_GATEWAY_CHAT_URL: gateway.chatUrl,
              },
            },
          );
          expect(resumed.code).toBe(0);
          expect(JSON.parse(resumed.stdout).session_id).toBe(forkedId);
        } finally {
          gateway.stop?.();
        }

        const detail = await sessionDetail(workspaceRoot, home, forkedId);
        expect(promptTexts(detail)).toEqual(["prompt for ONE", "keep going"]);
        expect(
          (await sessionDetail(workspaceRoot, home, sessionId)).history_len,
        ).toBe(3);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fork --json reports both turn counts",
    async () => {
      const { root, home, workspaceRoot } = makeWorkspace(
        "fx-session-fork-json-",
      );
      try {
        const sessionId = await seedSession(workspaceRoot, home, [
          "ONE",
          "TWO",
          "THREE",
        ]);
        const fork = await runFx(
          ["session", "fork", sessionId, "--at", "2", "--json"],
          { cwd: workspaceRoot, env: { HOME: home } },
        );
        expect(fork.code).toBe(0);
        expect(fork.stderr).toBe("");
        const payload = JSON.parse(fork.stdout);
        expect(payload.kind).toBe("session_fork");
        expect(payload.source_id).toBe(sessionId);
        expect(payload.forked_id).not.toBe(sessionId);
        expect(payload.status).toBe("forked");
        expect(payload.history_turns).toBe(2);
        expect(payload.source_history_turns).toBe(3);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fork rejects a turn past the end of the session in text and json",
    async () => {
      const { root, home, workspaceRoot } = makeWorkspace(
        "fx-session-fork-range-",
      );
      try {
        const sessionId = await seedSession(workspaceRoot, home, [
          "ONE",
          "TWO",
        ]);

        const text = await runFx(
          ["session", "fork", sessionId, "--at", "12"],
          { cwd: workspaceRoot, env: { HOME: home } },
        );
        expect(text.code).toBe(1);
        expect(text.stdout).toBe("");
        expect(text.stderr).toBe(
          "fx session: turn 12 is out of range; session has 2 turns\n",
        );

        const json = await runFx(
          ["session", "fork", sessionId, "--at", "12", "--json"],
          { cwd: workspaceRoot, env: { HOME: home } },
        );
        expect(json.code).toBe(1);
        expect(json.stderr).toBe("");
        const payload = JSON.parse(json.stdout);
        expect(payload.kind).toBe("session");
        expect(payload.code).toBe("SessionTurnOutOfRange");
        expect(payload.error).toBe(
          "turn 12 is out of range; session has 2 turns",
        );

        expect(
          (await sessionDetail(workspaceRoot, home, sessionId)).history_len,
        ).toBe(2);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe("session rewind", () => {
  test(
    "rewind drops the last turns in place and keeps the session id",
    async () => {
      const { root, home, workspaceRoot } = makeWorkspace("fx-session-rewind-");
      try {
        const sessionId = await seedSession(workspaceRoot, home, [
          "ONE",
          "TWO",
          "THREE",
        ]);

        const rewind = await runFx(
          ["session", "rewind", sessionId, "--by", "2"],
          { cwd: workspaceRoot, env: { HOME: home } },
        );
        expect(rewind.code).toBe(0);
        expect(rewind.stderr).toBe("");
        expect(rewind.stdout).toBe(
          `[session rewind] ${sessionId}\n` +
            "history_turns: 1\n" +
            "removed_turns: 2\n",
        );

        const detail = await sessionDetail(workspaceRoot, home, sessionId);
        expect(detail.id).toBe(sessionId);
        expect(promptTexts(detail)).toEqual(["prompt for ONE"]);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "rewind --json reports the removed turn count and a no-op rewind",
    async () => {
      const { root, home, workspaceRoot } = makeWorkspace(
        "fx-session-rewind-json-",
      );
      try {
        const sessionId = await seedSession(workspaceRoot, home, [
          "ONE",
          "TWO",
          "THREE",
        ]);

        const rewind = await runFx(
          ["session", "rewind", "--id", sessionId, "--by", "1", "--json"],
          { cwd: workspaceRoot, env: { HOME: home } },
        );
        expect(rewind.code).toBe(0);
        expect(rewind.stderr).toBe("");
        expect(JSON.parse(rewind.stdout)).toEqual({
          kind: "session_rewind",
          id: sessionId,
          status: "rewound",
          history_turns: 2,
          removed_turns: 1,
        });

        const noop = await runFx(
          ["session", "rewind", sessionId, "--by", "0", "--json"],
          { cwd: workspaceRoot, env: { HOME: home } },
        );
        expect(noop.code).toBe(0);
        expect(JSON.parse(noop.stdout)).toEqual({
          kind: "session_rewind",
          id: sessionId,
          status: "already_at_target",
          history_turns: 2,
          removed_turns: 0,
        });
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "rewind rejects dropping more turns than the session holds",
    async () => {
      const { root, home, workspaceRoot } = makeWorkspace(
        "fx-session-rewind-range-",
      );
      try {
        const sessionId = await seedSession(workspaceRoot, home, [
          "ONE",
          "TWO",
        ]);

        const text = await runFx(
          ["session", "rewind", sessionId, "--by", "9"],
          { cwd: workspaceRoot, env: { HOME: home } },
        );
        expect(text.code).toBe(1);
        expect(text.stdout).toBe("");
        expect(text.stderr).toBe(
          "fx session: cannot rewind 9 turns; session has 2 turns\n",
        );

        const json = await runFx(
          ["session", "rewind", sessionId, "--by", "9", "--json"],
          { cwd: workspaceRoot, env: { HOME: home } },
        );
        expect(json.code).toBe(1);
        expect(json.stderr).toBe("");
        expect(JSON.parse(json.stdout).code).toBe("SessionTurnOutOfRange");

        expect(
          (await sessionDetail(workspaceRoot, home, sessionId)).history_len,
        ).toBe(2);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});
