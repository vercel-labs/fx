// Programs that models wrote for the `execute` tool in fx's code-mode evals,
// one per block. engine.zig runs each with stand-in tools to check that the
// built-ins code mode cuts are ones real programs don't need.
for (let n=1;n<=6;n++){ await tools.write_file({path:`notes/${n}.md`, content:`note ${n}\n`}); }
let ok=0; const out=[];
for (let n=1;n<=6;n++){ const r=await tools.read_file({path:`notes/${n}.md`}); out.push(r); if(r.includes(`note ${n}`)) ok++; }
return {ok,out};
// ----
await Promise.all([1,2,3,4,5,6].map(n => tools.write_file({path:`notes/${n}.md`, content:`note ${n}\n`})));
const out=[];
for (let n=1;n<=6;n++){ const r=await tools.read_file({path:`notes/${n}.md`}); out.push(r);}
return out;
// ----
const names="atlas beacon cinder delta ember fjord garnet harbor ion juniper kestrel lumen".split(" ");
let out=[];
for(const n of names){out.push(n+": "+(await tools.read_file({path:`services/${n}/service.json`})));}
return out.join("\n");
// ----
const names="atlas beacon cinder delta ember fjord garnet harbor ion juniper kestrel lumen".split(" ");
let out=[];
for(const n of names){out.push(n+": "+(await tools.read_file({path:`services/${n}/service.json`})).replace(/\s+/g," "));}
return out.join("\n");
// ----
const names="atlas beacon cinder delta ember fjord garnet harbor ion juniper kestrel lumen".split(" ");
const out={};
for(const n of names){out[n]=await tools.read_file({path:`services/${n}/service.json`});}
return out;
// ----
const fs=["m03","m07","m11","m14","m18"];
const out=await Promise.all(fs.map(async f=>f+":\n"+await tools.read_file({path:`src/${f}.ts`})));
return out.join("\n");
// ----
const fs=["m03","m07","m11","m14","m18"];
const out=await Promise.all(fs.map(f=>tools.read_file({path:`src/${f}.ts`})));
return out.join("\n=====\n");
// ----
const fs=["m03","m07","m11","m14","m18"];
const r=await Promise.all(fs.map(f=>tools.read_file({path:`src/${f}.ts`})));
return r.join("\n=====\n");
// ----
const rs = await Promise.all([1,2,3,4,5,6].map(n => tools.read_file({path:`notes/${n}.md`}))); return rs.join('\n---\n');
// ----
const files = await tools.glob_files({pattern:'services/**', path:'.', mode:'matches'}); return files;
// ----
const paths=(await tools.glob_files({pattern:'services/**/service.json',path:'.',mode:'matches'})).match(/ - (.*)/g)?.map(x=>x.slice(3))||[]; const rs=await Promise.all(paths.map(path=>tools.read_file({path}))); return paths.map((p,i)=>`--- ${p}\n${rs[i]}`).join('\n');
// ----
const r = await tools.glob_files({path:"services",pattern:"**/*",mode:"matches"}); return r;
// ----
const [files, ag, status] = await Promise.all([
  tools.glob_files({path:"services", pattern:"**/*"}),
  tools.glob_files({path:".", pattern:"AGENTS.md"}),
  tools.shell({action:"run", command:"git status --short", cwd:".", yield_time_ms:30000})
]);
return JSON.stringify({files,ag,status});
// ----
await tools.shell({ action: "run", command: "mkdir -p notes" });
for (let n = 1; n <= 6; n++) {
  await tools.write_file({ path: `notes/${n}.md`, content: `note ${n}\n` });
}
const results = [];
for (let n = 1; n <= 6; n++) {
  const content = await tools.read_file({ path: `notes/${n}.md` });
  results.push({ n, content });
}
return results;
// ----
const names = ["atlas", "cinder", "ember", "garnet", "ion", "kestrel"];
const results = await Promise.all(names.map(async (name) => {
  const text = await tools.read_file({ path: `services/${name}/service.json` });
  return { name, text };
}));
return results.map(r => `=== ${r.name} ===\n${r.text}`).join("\n");
// ----
const files = [
  "services/atlas/service.json",
  "services/cinder/service.json",
  "services/ember/service.json",
  "services/garnet/service.json",
  "services/ion/service.json",
  "services/kestrel/service.json",
];
const out = [];
for (const path of files) {
  const text = await tools.read_file({ path });
  out.push({ path, text });
}
return out;
// ----
const out=[];
const ids=[];for(let i=101;i<=140;i++)ids.push("TRK-"+i);
const res=await Promise.all(ids.map(async id=>{try{return [id,await tools.mcp_tracker_get_issue({id})]}catch(e){return [id,"ERR "+e.message]}}));
for(const [id,r] of res){const m=r.match(/status\W+([A-Za-z_ -]+)/i);out.push(id+": "+(m?m[1].trim():r.slice(0,150)));}
return out.join("\n");
// ----
const out=[];
const ids=[];for(let i=101;i<=140;i++)ids.push("TRK-"+i);
const res=await Promise.all(ids.map(async id=>{try{return [id,await tools.mcp_tracker_get_issue({id})]}catch(e){return [id,"ERR "+e.message]}}));
for(const [id,r] of res){const m=r.match(/status[^\n]*/i);out.push(id+": "+(m?m[0]:r.slice(0,100)));}
return out.join("\n");
// ----
const out=[];
const ids=[];
for(let i=101;i<=140;i++)ids.push("TRK-"+i);
const res=await Promise.all(ids.map(async id=>{try{return [id,await tools.mcp_tracker_get_issue({id})]}catch(e){return [id,"ERR "+e.message]}}));
for(const [id,r] of res){const m=r.match(/status\W+([A-Za-z_ -]+)/i);out.push(id+": "+(m?m[1].trim().slice(0,20):r.slice(0,150)));}
return out.join("\n");
// ----
const ids=[];for(let i=101;i<=125;i++)ids.push("TRK-"+i);
const res=await Promise.all(ids.map(id=>tools.mcp_tracker_get_issue({id})));
console.log(res.map(r=>r.slice(0,400)).join("\n"));
// ----
const ids=[];for(let i=101;i<=125;i++)ids.push("TRK-"+i);
const res=await Promise.all(ids.map(id=>tools.mcp_tracker_get_issue({id})));
return res.map(r=>r.slice(0,400)).join("\n");
// ----
const ids=[];for(let i=101;i<=125;i++)ids.push("TRK-"+i);
const rs=await Promise.all(ids.map(id=>tools.mcp_tracker_get_issue({id})));
return rs.map(r=>r.slice(0,600)).join("\n---\n");
// ----
const r = await tools.mcp_tracker_search_logs({service:"checkout"});
const lines = r.split("\n");
const err = lines.filter(l=>/\bERROR\b/.test(l));
const m = err.filter(l=>/payment-gateway/.test(l));
console.log(lines.length, err.length, m.length);
console.log(m.join("\n"));
console.log(r.slice(0,500));
// ----
const r = await tools.mcp_tracker_search_logs({service:"checkout"});
let text = r;
try { const j = JSON.parse(r); text = j.result?.content?.map(c=>c.text).join("\n") ?? r; } catch(e){}
const lines = text.split("\n");
const err = lines.filter(l=>/\sERROR\s/.test(l));
const n = err.filter(l=>/(^|[^a-z-])payment-gateway($|[^a-z-])/.test(l)).length;
console.log(lines.length, err.length, n);
// ----
const r = await tools.mcp_tracker_search_logs({service:"checkout"});
const lines = r.split("\n");
const errs = lines.filter(l=>/\bERROR\b/.test(l));
const m = errs.filter(l=>/(^|[^a-zA-Z0-9-])payment-gateway(?![a-zA-Z0-9-])/.test(l));
console.log(lines.length, errs.length, m.length);
console.log(errs.filter(l=>/gateway/.test(l)).join("\n"));
// ----
const ids = Array.from({length:40},(_,i)=>`TRK-${101+i}`);
const results = await Promise.all(ids.map(async id => ({id, text: await tools.mcp_tracker_get_issue({id})})));
console.log(JSON.stringify(results));
// ----
const ids = Array.from({length:40},(_,i)=>`TRK-${101+i}`);
const results = await Promise.all(ids.map(async id => JSON.parse(await tools.mcp_tracker_get_issue({id}))));
console.log(results.filter(x => x.status === 'blocked').map(x => x.id).join(', '));
// ----
const ids = Array.from({length: 40}, (_, i) => `TRK-${101+i}`);
const results = await Promise.all(ids.map(async id => ({id, result: await tools.mcp_tracker_get_issue({id})})));
console.log(JSON.stringify(results));
// ----
const ids = Array.from({length: 40}, (_, i) => `TRK-${101+i}`);
const rows = await Promise.all(ids.map(async id => {
  const raw = await tools.mcp_tracker_get_issue({id});
  const issue = JSON.parse(raw);
  return {id, status: issue.status};
}));
console.log(rows.filter(x => x.status === 'blocked').map(x => x.id).join(','));
// ----
const out=[];
const ids=[];for(let i=101;i<=140;i++)ids.push("TRK-"+i);
const res=await Promise.all(ids.map(async id=>{try{return [id,await tools.mcp_tracker_get_issue({id})]}catch(e){return [id,"ERR "+e.message]}}));
for(const [id,r] of res){const m=r.match(/status\W+([A-Za-z_ -]+)/i);out.push(id+": "+(m?m[1].trim():r.slice(0,100)));}
return out.join("\n");
