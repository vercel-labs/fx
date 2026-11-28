import { afterAll } from "bun:test";
import { killLiveTmuxSessions } from "./tmux-helpers";

// Bun runs this after the whole test run. A timed-out test keeps its body
// running, and Bun exits without waiting for that body, so its fx and tmux
// server would outlive the run unless the run ends them here.
afterAll(killLiveTmuxSessions);
