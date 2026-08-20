#!/usr/bin/env node
// P2 universal bridge E2E: tests health, ?agent, ?cwd, unknown agent, cwd validation, parallel
import { spawn } from "node:child_process";
import { WebSocket } from "ws";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const FX_BIN = "/home/ubuntu/fx/zig-out/bin/fx";
const BRIDGE_PORT = 8796;
const BRIDGE_URL = `ws://127.0.0.1:${BRIDGE_PORT}/acp`;

let bridge;
let passed=0, failed=0;
function ok(name, cond, detail="") {
  if(cond){ passed++; console.log(`  PASS  ${name}`); }
  else { failed++; console.error(`  FAIL  ${name}${detail?" — "+detail:""}`); }
}
function waitForMessage(ws, pred, timeoutMs=8000){
  return new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>reject(new Error("timeout waiting for message")), timeoutMs);
    const handler=(data)=>{
      let msg; try{msg=JSON.parse(data.toString());}catch{return;}
      if(pred(msg)){ clearTimeout(timer); ws.off("message", handler); resolve(msg); }
    };
    ws.on("message", handler);
  });
}

async function main(){
  const mockAgentPath = join(import.meta.dirname, "mock-agent.mjs");
  // Create temp config that overrides omp and pi to use mock agent
  const tmpConfig = join(tmpdir(), `bridge-universal-config-${Date.now()}.json`);
  const { writeFileSync } = await import("node:fs");
  writeFileSync(tmpConfig, JSON.stringify({
    defaultAgent: "fx",
    allowCwdRoots: [],
    agents: {
      fx: { command: FX_BIN, args: ["acp"], env: {} },
      mockpi: { command: "node", args: [mockAgentPath], env: { MOCK_AGENT_NAME: "mockpi" } },
      mockomp: { command: "node", args: [mockAgentPath], env: { MOCK_AGENT_NAME: "mockomp" } },
      pi: { command: "node", args: [mockAgentPath], env: { MOCK_AGENT_NAME: "pi" } },
      omp: { command: "node", args: [mockAgentPath], env: { MOCK_AGENT_NAME: "omp" } },
      opencode: { command: "node", args: [mockAgentPath], env: { MOCK_AGENT_NAME: "opencode" } },
    }
  }));
  bridge = spawn("node", ["bridge.mjs"], {
    env: { ...process.env, PORT: String(BRIDGE_PORT), BRIDGE_CONFIG_PATH: tmpConfig },
    stdio: ["ignore","pipe","pipe"],
  });
  bridge.stderr.on("data", (d)=> process.stderr.write(d.toString().includes("mockpi") ? d : d)); // show all

  await new Promise((resolve, reject)=>{
    const timer=setTimeout(()=>reject(new Error("bridge did not start")), 8000);
    bridge.stderr.on("data", d=>{
      if(d.toString().includes("listening on")){ clearTimeout(timer); resolve(); }
    });
    bridge.on("error", reject);
  });
  console.log("\n# Universal bridge P2");

  // health
  {
    const res = await fetch(`http://127.0.0.1:${BRIDGE_PORT}/health`);
    const body = await res.json();
    ok("GET /health returns 200", res.status===200);
    ok("health reports agents includes fx, pi, omp", Array.isArray(body.agents) && body.agents.includes("fx") && body.agents.includes("pi") && body.agents.includes("omp"), JSON.stringify(body));
    ok("health defaultAgent is fx", body.defaultAgent==="fx");
  }
  {
    const res = await fetch(`http://127.0.0.1:${BRIDGE_PORT}/agents`);
    const body = await res.json();
    ok("GET /agents lists mockpi", body.agents.includes("mockpi"), JSON.stringify(body));
  }
  {
    const res = await fetch(`http://127.0.0.1:${BRIDGE_PORT}/acp`);
    ok("GET /acp without upgrade returns 426", res.status===426);
  }
  {
    const res = await fetch(`http://127.0.0.1:${BRIDGE_PORT}/acp`, { method:"POST", headers:{"content-type":"application/json"}, body: JSON.stringify({jsonrpc:"2.0",id:1,method:"initialize"}) });
    ok("POST /acp returns 501", res.status===501);
  }

  // unknown agent should be 400 on upgrade
  {
    const { WebSocket: WS2 } = await import("ws");
    const ws = new WS2(`ws://127.0.0.1:${BRIDGE_PORT}/acp?agent=unknownXYZ`);
    const err = await new Promise(resolve=>{
      ws.on("error", e=> resolve(e.message));
      ws.on("unexpected-response", (req, res)=> resolve(`unexpected-response ${res.statusCode}`));
      setTimeout(()=> resolve("timeout"), 2000);
    });
    // ws will fail to connect; we just check it didn't open
    const opened = await new Promise(res=>{ ws.on("open",()=>res(true)); setTimeout(()=>res(false), 800); });
    ok("unknown agent rejected (no open)", !opened, err);
    try{ ws.close(); }catch{}
  }

  // ?agent selection: mockpi
  {
    const ws = new WebSocket(`${BRIDGE_URL}?agent=mockpi`);
    await new Promise((res,rej)=>{ ws.on("open",res); ws.on("error",rej); });
    const conn = await waitForMessage(ws, m=>m.method==="transport/connection");
    ok("mockpi transport/connection reports agent", conn.params?.agent==="mockpi", JSON.stringify(conn.params));
    ws.send(JSON.stringify({jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:1,clientCapabilities:{}}}));
    const init = await waitForMessage(ws, m=>m.id===1 && m.result);
    ok("mockpi initialize returns mockpi name", init.result?.agentInfo?.name==="mockpi", JSON.stringify(init.result?.agentInfo));
    ws.send(JSON.stringify({jsonrpc:"2.0",id:2,method:"session/new",params:{cwd:"/tmp"}}));
    const sess = await waitForMessage(ws, m=>m.id===2 && m.result);
    ok("mockpi session/new returns sessionId", typeof sess.result?.sessionId==="string", JSON.stringify(sess));
    ws.send(JSON.stringify({jsonrpc:"2.0",id:3,method:"session/prompt",params:{sessionId:sess.result.sessionId, prompt:[{type:"text",text:"hello"}]}}));
    const resp = await waitForMessage(ws, m=>m.id===3 && m.result);
    ok("mockpi prompt returns end_turn", resp.result?.stopReason==="end_turn");
    ws.close(); await new Promise(r=>ws.on("close",r));
  }

  // ?cwd eager spawn via query
  {
    const dir = mkdtempSync(join(tmpdir(),"fx-universal-cwd-"));
    const ws = new WebSocket(`${BRIDGE_URL}?agent=fx&cwd=${encodeURIComponent(dir)}`);
    await new Promise((res,rej)=>{ ws.on("open",res); ws.on("error",rej); });
    await waitForMessage(ws, m=>m.method==="transport/connection");
    // Don't send cwd in JSON; rely on query cwd
    ws.send(JSON.stringify({jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:1,clientCapabilities:{}}}));
    const init = await waitForMessage(ws, m=>m.id===1 && m.result);
    ok("eager ?cwd fx initialize ok", init.result?.protocolVersion===1);
    ws.send(JSON.stringify({jsonrpc:"2.0",id:2,method:"session/new",params:{cwd: dir}}));
    const sess = await waitForMessage(ws, m=>m.id===2 && m.result);
    ok("eager ?cwd session/new still succeeds", typeof sess.result?.sessionId==="string");
    ws.close(); await new Promise(r=>ws.on("close",r));
    rmSync(dir,{recursive:true,force:true});
  }

  // parallel per-cwd with different agents: fx and mockomp
  {
    const dir1 = mkdtempSync(join(tmpdir(),"fx-par1-"));
    const dir2 = mkdtempSync(join(tmpdir(),"fx-par2-"));
    const ws1 = new WebSocket(`${BRIDGE_URL}?agent=fx&cwd=${encodeURIComponent(dir1)}`);
    const ws2 = new WebSocket(`${BRIDGE_URL}?agent=mockomp&cwd=${encodeURIComponent(dir2)}`);
    await Promise.all([
      new Promise((res,rej)=>{ ws1.on("open",res); ws1.on("error",rej); }),
      new Promise((res,rej)=>{ ws2.on("open",res); ws2.on("error",rej); }),
    ]);
    await Promise.all([
      waitForMessage(ws1, m=>m.method==="transport/connection", 8000),
      waitForMessage(ws2, m=>m.method==="transport/connection", 8000),
    ]);
    ws1.send(JSON.stringify({jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:1,clientCapabilities:{}}}));
    ws2.send(JSON.stringify({jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:1,clientCapabilities:{}}}));
    const [init1, init2] = await Promise.all([
      waitForMessage(ws1, m=>m.id===1 && m.result, 8000),
      waitForMessage(ws2, m=>m.id===1 && m.result, 8000),
    ]);
    ok("parallel fx init name fx", init1.result?.agentInfo?.name==="fx");
    ok("parallel mockomp init name mockomp", init2.result?.agentInfo?.name==="mockomp");
    ws1.send(JSON.stringify({jsonrpc:"2.0",id:2,method:"session/new",params:{cwd:dir1}}));
    ws2.send(JSON.stringify({jsonrpc:"2.0",id:2,method:"session/new",params:{cwd:dir2}}));
    const [sess1, sess2] = await Promise.all([
      waitForMessage(ws1, m=>m.id===2 && m.result, 8000),
      waitForMessage(ws2, m=>m.id===2 && m.result, 8000),
    ]);
    ok("parallel fx sessionId", typeof sess1.result.sessionId==="string");
    ok("parallel mockomp sessionId", typeof sess2.result.sessionId==="string");
    ok("parallel sessionIds distinct", sess1.result.sessionId!==sess2.result.sessionId);
    // only prompt mock side - fx prompt would require gateway and hang
    ws2.send(JSON.stringify({jsonrpc:"2.0",id:3,method:"session/prompt",params:{sessionId:sess2.result.sessionId, prompt:[{type:"text",text:"prompt mock"}]}}));
    const resp2 = await waitForMessage(ws2, m=>m.id===3 && m.result, 8000);
    ok("parallel mockomp prompt end_turn", resp2.result?.stopReason==="end_turn");
    ws1.close(); ws2.close();
    await Promise.all([new Promise(r=>ws1.on("close",r)), new Promise(r=>ws2.on("close",r))]);
    rmSync(dir1,{recursive:true,force:true});
    rmSync(dir2,{recursive:true,force:true});
  }

  // cwd disallowed test: create config with allowCwdRoots and test rejection
  // We'll do this by spawning a second bridge on different port with restrictive config
  {
    const { writeFileSync } = await import("node:fs");
    const restrictConfig = join(tmpdir(), `bridge-restrict-${Date.now()}.json`);
    writeFileSync(restrictConfig, JSON.stringify({
      defaultAgent: "fx",
      allowCwdRoots: ["/tmp/allowed-only"],
      agents: { fx: { command: FX_BIN, args: ["acp"] }, mockpi: { command: "node", args: [mockAgentPath], env: { MOCK_AGENT_NAME: "mockpi" } } }
    }));
    const restrictPort = 8795;
    const restrictBridge = spawn("node", ["bridge.mjs"], {
      env: { ...process.env, PORT: String(restrictPort), BRIDGE_CONFIG_PATH: restrictConfig },
      stdio: ["ignore","pipe","pipe"],
    });
    await new Promise((res,rej)=>{
      const t=setTimeout(()=>rej(new Error("restrict bridge not start")),5000);
      restrictBridge.stderr.on("data", d=>{ if(d.toString().includes("listening on")){clearTimeout(t);res();} });
    });
    // ?cwd outside allowed should be rejected on upgrade
    const wsBad = new WebSocket(`ws://127.0.0.1:${restrictPort}/acp?agent=mockpi&cwd=/etc`);
    const badOpened = await new Promise(res=>{ wsBad.on("open",()=>res(true)); wsBad.on("error",()=>res(false)); wsBad.on("unexpected-response",()=>res(false)); setTimeout(()=>res(false),1200); });
    ok("disallowed ?cwd rejected on upgrade", !badOpened);
    try{ wsBad.close(); }catch{}
    // ?cwd inside allowed should succeed
    const { mkdirSync } = await import("node:fs");
    const allowedDir = "/tmp/allowed-only/test123";
    try{ mkdirSync(allowedDir,{recursive:true}); }catch{}
    const wsGood = new WebSocket(`ws://127.0.0.1:${restrictPort}/acp?agent=mockpi&cwd=${encodeURIComponent(allowedDir)}`);
    const goodOpened = await new Promise(res=>{ wsGood.on("open",()=>res(true)); wsGood.on("error",()=>res(false)); setTimeout(()=>res(false),1500); });
    ok("allowed ?cwd succeeds", goodOpened);
    if(goodOpened){
      await waitForMessage(wsGood, m=>m.method==="transport/connection");
      wsGood.send(JSON.stringify({jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:1,clientCapabilities:{}}}));
      const init = await waitForMessage(wsGood, m=>m.id===1 && m.result);
      ok("allowed cwd init succeeds", init.result?.protocolVersion===1);
      wsGood.close(); await new Promise(r=>wsGood.on("close",r));
    }
    restrictBridge.kill("SIGTERM");
    await new Promise(r=>restrictBridge.on("exit",r));
    try{ rmSync(restrictConfig); }catch{}
    try{ rmSync("/tmp/allowed-only",{recursive:true,force:true}); }catch{}
  }

  console.log(`\n${passed} passed, ${failed} failed\n`);
  bridge.kill("SIGTERM");
  await new Promise(r=>bridge.on("exit",r));
  try{ rmSync(tmpConfig); }catch{}
  process.exit(failed>0?1:0);
}

main().catch(e=>{ console.error("fatal",e); bridge?.kill("SIGTERM"); process.exit(1); });
