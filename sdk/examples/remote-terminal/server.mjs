import { startBroker } from "./broker.mjs";

const config = JSON.parse(process.env.FX_TERMINAL_CONFIG);
delete process.env.FX_TERMINAL_CONFIG;
const broker = await startBroker(config);
let stopping = false;
const stop = async () => {
  if (stopping) return;
  stopping = true;
  await broker.close();
};
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
