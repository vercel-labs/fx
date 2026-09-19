import { readFileSync, writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { classify } from './classifier.mjs';
import { route } from './router.mjs';

const [command, ...args] = process.argv.slice(2);
function value(flag, fallback) { const n = args.indexOf(flag); return n < 0 ? fallback : args[n + 1]; }
const promptPath = value('--prompt-file');
const prompt = promptPath ? readFileSync(promptPath, 'utf8') : readFileSync(0, 'utf8');
try {
  if (command === 'classify') console.log(JSON.stringify(await classify(prompt)));
  else if (command === 'route' || command === 'run-fx') {
    const policy = JSON.parse(readFileSync(value('--policy', new URL('../config/policy.json', import.meta.url))));
    const decision = await route(prompt, policy, { tools: command === 'run-fx', explicitModel: value('--model') });
    const trace = value('--trace');
    if (trace) writeFileSync(trace, JSON.stringify(decision, null, 2));
    if (command === 'route') console.log(JSON.stringify(decision));
    else {
      const binary = value('--binary');
      if (!binary?.startsWith('/')) throw new Error('--binary must be the absolute path to the freshly built fx');
      const child = spawn(binary, ['ask', '--model', decision.model, '--json', '--', prompt], {
        stdio: 'inherit', shell: false, env: { ...process.env, FX_AUTO_UPGRADE: '0' },
      });
      child.on('error', e => { console.error(e.message); process.exitCode = 1; });
      child.on('exit', code => { process.exitCode = code ?? 1; });
    }
  } else throw new Error('Use classify, route, or run-fx');
} catch (e) { console.error(e.message); process.exitCode = 1; }
