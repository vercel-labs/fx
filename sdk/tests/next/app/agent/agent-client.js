"use client";
import { createFxAgent } from "libfx/browser";

// Created once at module scope, as the README recommends.
const agent = createFxAgent();

export default function AgentClient() {
  return <span id="libfx-agent">{typeof agent.session}</span>;
}
