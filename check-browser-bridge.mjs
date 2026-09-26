// End-to-end browser-bridge self-check.
//
// This drives the app's own `node_repl` MCP server (the same path the agent uses):
//   node_repl js tool -> browser service -> app browser-use pipe -> extension host -> Chrome
// and prints the browsers + open tabs it can see. If a tab with a URL comes back, the bridge works.
//
// Why it is needed: the static checks (diagnose script) can all pass while the live bridge is dead.
// This is the only check that proves the app can actually enumerate Chrome tabs / read the current URL.
//
// Usage:  node check-browser-bridge.mjs [--seconds 90]
// Exit code: 0 = bridge works (browsers and tabs returned), 1 = bridge broken, 2 = usage/环境问题
//
// Everything is derived from ~/.codex/config.toml ([mcp_servers.node_repl] + .env), so it works on
// any machine where the desktop app is installed and has run at least once.

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';

const codexHome = process.env.CODEX_HOME || path.join(process.env.USERPROFILE || process.env.HOME, '.codex');
const cfgPath = path.join(codexHome, 'config.toml');
if (!fs.existsSync(cfgPath)) {
  console.error(`config.toml not found: ${cfgPath} (run the ChatGPT desktop app at least once)`);
  process.exit(2);
}
const cfg = fs.readFileSync(cfgPath, 'utf8');
const section = (name) => {
  const m = cfg.match(new RegExp(`\\[${name.replace(/\./g, '\\.')}\\]([\\s\\S]*?)(?=\\n\\[|$)`));
  return m ? m[1] : '';
};

const cmdMatch = section('mcp_servers.node_repl').match(/command\s*=\s*'(.*?)'/);
if (!cmdMatch) {
  console.error('config.toml has no [mcp_servers.node_repl] command - the bundled plugin config is missing.');
  console.error('Run fix-chatgpt-chrome-bridge.ps1 (it restores the plugin state) and try again.');
  process.exit(2);
}
const command = cmdMatch[1];

const env = { ...process.env };
for (const line of section('mcp_servers.node_repl.env').split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(['"])(.*?)\2\s*$/);
  if (m) env[m[1]] = m[3];
}

// The browser client lives next to the browser service the app trusts.
let browserClient = null;
try {
  const trusted = JSON.parse(env.NODE_REPL_TRUSTED_SERVICES || '{}');
  if (typeof trusted.browser === 'string') {
    browserClient = path.join(path.dirname(trusted.browser), 'browser-client.mjs');
  }
} catch { /* ignore */ }
if (!browserClient || !fs.existsSync(browserClient)) {
  const guess = path.join(codexHome, 'plugins', 'cache', 'openai-bundled', 'browser');
  const dirs = fs.existsSync(guess)
    ? fs.readdirSync(guess).filter((d) => /^\d/.test(d)).sort().reverse()
    : [];
  browserClient = dirs.length ? path.join(guess, dirs[0], 'scripts', 'browser-client.mjs') : null;
}
if (!browserClient || !fs.existsSync(browserClient)) {
  console.error('cannot locate browser-client.mjs (browser plugin not installed in the plugin cache)');
  process.exit(2);
}
const browserClientUrl = `file:///${browserClient.replace(/\\/g, '/')}`;

const args = process.argv.slice(2);
const secondsIdx = args.indexOf('--seconds');
const timeoutMs = (secondsIdx >= 0 ? Number(args[secondsIdx + 1]) : 90) * 1000;

console.log(`node_repl   : ${command}`);
console.log(`browser cli : ${browserClient}`);

const child = spawn(command, [], { env, stdio: ['pipe', 'pipe', 'pipe'] });
const stderrLines = [];
child.stderr.on('data', (d) => stderrLines.push(d.toString('utf8').trim()));

let buffer = '';
const pending = new Map();
child.stdout.on('data', (chunk) => {
  buffer += chunk.toString('utf8');
  let idx;
  while ((idx = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, idx).trim();
    buffer = buffer.slice(idx + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    if (msg.id != null && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    }
  }
});

const send = (obj) => child.stdin.write(`${JSON.stringify(obj)}\n`);
function request(id, method, params) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${method} timed out after ${timeoutMs / 1000}s`)), timeoutMs);
    pending.set(id, (msg) => { clearTimeout(timer); resolve(msg); });
    send({ jsonrpc: '2.0', id, method, params });
  });
}

// The browser service refuses to run without turn metadata, so supply one (values are opaque here).
const turnMeta = JSON.stringify({
  session_id: process.env.BRIDGE_CHECK_SESSION_ID || '00000000-0000-4000-8000-000000000001',
  turn_id: process.env.BRIDGE_CHECK_TURN_ID || '00000000-0000-4000-8000-000000000002',
});

const jsCode = `
const m = await import(${JSON.stringify(browserClientUrl)});
const agent = await m.setupBrowserRuntime({});
globalThis.__bridgeCheckAgent = agent;
const out = {};
let list = [];
try { list = await agent.browsers.list(); out.browsers = list.map(b => ({ id: b.id, type: b.type, family: b.family })); }
catch (e) { out.browsersError = String((e && e.message) || e); }
try {
  const target = list.find(b => b.type === "extension") ?? list[0];
  if (!target) throw new Error("agent.browsers.list() returned no browser");
  const b = await agent.browsers.get(target.id);
  out.usedBrowserId = target.id;
  const tabs = await b.user.openTabs();
  out.tabCount = tabs.length;
  out.tabs = tabs.map(t => ({ id: t.id, title: t.title, url: t.url }));
} catch (e) { out.tabsError = String((e && e.message) || e); }
nodeRepl.write(JSON.stringify(out));
`;

let ok = false;
try {
  const init = await request(1, 'initialize', {
    protocolVersion: '2025-06-18',
    capabilities: {},
    clientInfo: { name: 'bridge-selfcheck', version: '1.0' },
  });
  if (!init.result) throw new Error(`initialize failed: ${JSON.stringify(init.error)}`);
  send({ jsonrpc: '2.0', method: 'notifications/initialized' });

  const call = await request(2, 'tools/call', {
    name: 'js',
    arguments: { code: jsCode, title: 'browser bridge self-check' },
    _meta: { 'x-codex-turn-metadata': turnMeta },
  });
  const text = (call.result?.content ?? []).map((c) => c.text ?? '').join('\n').trim();
  if (!text) throw new Error(`empty result: ${JSON.stringify(call.error ?? call.result)}`);

  let parsed = null;
  try { parsed = JSON.parse(text); } catch { /* keep raw */ }
  if (parsed && parsed.tabCount > 0 && Array.isArray(parsed.tabs)) {
    ok = true;
    console.log(`browsers    : ${JSON.stringify(parsed.browsers)}`);
    console.log(`tabs (${parsed.tabCount}):`);
    for (const t of parsed.tabs) console.log(`  - [${t.id}] ${t.title}  ${t.url}`);
    console.log('');
    console.log('VERDICT: bridge works - the app can enumerate Chrome tabs and read their URLs.');
  } else {
    console.log(`raw result  : ${text}`);
    console.log('');
    console.log('VERDICT: bridge is NOT working.');
    if (/Missing required Codex turn metadata/.test(text)) {
      console.log('  (this check always sends turn metadata, so this means the service changed its contract)');
    }
  }
} catch (e) {
  console.log(`VERDICT: bridge is NOT working - ${e.message}`);
} finally {
  try { child.kill(); } catch { /* ignore */ }
}
if (stderrLines.length) {
  console.log('');
  console.log('node_repl stderr:');
  for (const l of stderrLines.slice(0, 8)) console.log(`  ${l}`);
  if (stderrLines.join(' ').includes('CreateProcessWithLogonW')) {
    console.log('  -> the node_repl Windows sandbox could not log on; start the Secondary Logon service:');
    console.log('     Start-Service seclogon   (and keep CodexSandboxService running)');
  }
}
process.exit(ok ? 0 : 1);
