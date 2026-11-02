import AgentClient from "./agent-client.js";

// A page whose client component holds a browser agent. The server renders it
// too, so importing libfx/browser and creating the agent must do no work.
export default function Page() {
  return <main>libfx browser agent fixture <AgentClient /></main>;
}
