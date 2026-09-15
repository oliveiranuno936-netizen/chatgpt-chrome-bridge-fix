// ChatGPT connectivity self-check (no dependencies; probes through a local proxy by default).
//
// Output is ASCII/English on purpose: the stock Windows console codepage (936) garbles
// UTF-8 Chinese printed by Node.
//
// Usage:
//   node chatgpt-check.mjs                          # probe through 127.0.0.1:7892
//   node chatgpt-check.mjs --proxy 127.0.0.1:7890   # any local HTTP proxy (host:port)
//   node chatgpt-check.mjs --proxy-port 7890        # same, host defaults to 127.0.0.1
//   node chatgpt-check.mjs --direct                 # no proxy: connect to :443 directly
//   node chatgpt-check.mjs --help
//   set CHATGPT_PROXY=127.0.0.1:7890 && node chatgpt-check.mjs
//
// It answers one question: is "ChatGPT will not open" a broken tunnel, a broken exit
// node, or a Cloudflare challenge?
//
// Exit codes:
//   0 = healthy (an occasional Cloudflare challenge is normal noise)
//   1 = the proxy / tunnel / exit node is broken, or the page never loads
//   2 = bad command line

import http from 'node:http';
import tls from 'node:tls';

const DEFAULT_PROXY = '127.0.0.1:7892'; // common mixed-port default (Clash / Mihomo / ...)

const HOSTS = [
  'chatgpt.com',
  'ab.chatgpt.com',
  'cdn.oaistatic.com',
  'cdn.openai.com',
  'files.oaiusercontent.com',
  'ws.chatgpt.com',
  'auth.openai.com',
  'api.openai.com',
  'challenges.cloudflare.com',
  'openai.com',
];

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const USAGE = `ChatGPT connectivity self-check

  node chatgpt-check.mjs [options]

Options:
  --proxy <host:port>   probe through this local proxy (default ${DEFAULT_PROXY})
  --proxy <port>        shorthand for 127.0.0.1:<port>
  --proxy-port <port>   same as above
  --direct              do not use a proxy: connect to :443 directly
  -h, --help            print this help

Environment:
  CHATGPT_PROXY         default proxy, e.g. 127.0.0.1:7890

Exit codes: 0 healthy / 1 broken tunnel or exit node / 2 bad command line
`;

function parseArgs(argv) {
  const opts = {
    direct: false,
    help: false,
    proxy: process.env.CHATGPT_PROXY || process.env.chatgpt_proxy || DEFAULT_PROXY,
  };

  const setProxy = (value) => {
    if (!value) throw new Error('--proxy needs a value, e.g. --proxy 127.0.0.1:7890');
    const text = String(value).trim();
    opts.proxy = /^\d+$/.test(text) ? `127.0.0.1:${text}` : text;
  };

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') opts.help = true;
    else if (a === '--direct') opts.direct = true;
    else if (a === '--proxy' || a === '--proxy-port') setProxy(argv[++i]);
    else if (a.startsWith('--proxy=')) setProxy(a.slice('--proxy='.length));
    else if (a.startsWith('--proxy-port=')) setProxy(a.slice('--proxy-port='.length));
    else throw new Error(`unknown argument: ${a}`);
  }

  const [host, portText] = opts.proxy.split(':');
  const port = Number(portText);
  if (!host || !Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`bad proxy address: "${opts.proxy}" (expected host:port)`);
  }
  opts.proxyHost = host;
  opts.proxyPort = port;
  return opts;
}

let OPTIONS;
try {
  OPTIONS = parseArgs(process.argv.slice(2));
} catch (e) {
  console.error(`error: ${e.message}\n`);
  console.error(USAGE);
  process.exit(2);
}

if (OPTIONS.help) {
  console.log(USAGE);
  process.exit(0);
}

const DIRECT = OPTIONS.direct;
const PROXY_HOST = OPTIONS.proxyHost;
const PROXY_PORT = OPTIONS.proxyPort;
const TARGET = DIRECT ? 'direct (no proxy)' : `proxy ${PROXY_HOST}:${PROXY_PORT}`;

function buildRequest(host, path) {
  return (
    `GET ${path} HTTP/1.1\r\nHost: ${host}\r\nUser-Agent: ${UA}\r\n` +
    'Accept: text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8\r\n' +
    'Accept-Language: en-US,en;q=0.9\r\nSec-Fetch-Dest: document\r\nSec-Fetch-Mode: navigate\r\n' +
    'Sec-Fetch-Site: none\r\nSec-Fetch-User: ?1\r\nUpgrade-Insecure-Requests: 1\r\n' +
    'sec-ch-ua: "Chromium";v="131", "Not_A Brand";v="24"\r\n' +
    'sec-ch-ua-mobile: ?0\r\nsec-ch-ua-platform: "Windows"\r\nConnection: close\r\n\r\n'
  );
}

function parseResponse(body) {
  return {
    status: (body.match(/^HTTP\/1\.\d (\d+)/) || [])[1] || '000',
    title: ((body.match(/<title[^>]*>([^<]*)<\/title>/i) || [])[1] || '').trim(),
    mitigated: /cf-mitigated:\s*(\w+)/i.test(body) ? RegExp.$1 : '',
  };
}

/**
 * Probe one host: TLS handshake (optionally through the local proxy's CONNECT),
 * and optionally one real HTTP GET over that TLS session.
 */
function probe(host, { path = null, timeout = 12000 } = {}) {
  return new Promise((resolve) => {
    const started = Date.now();
    let settled = false;
    let cn = '-';
    let body = '';
    let timer = null;

    const finish = (o) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve({ ...o, cn, ms: Date.now() - started });
    };

    // Every TLS session ends up here: collect one response, then report.
    const onTls = (sock) => {
      sock.on('data', (d) => {
        body += d.toString('utf8');
        if (body.length > 200000) sock.destroy();
      });
      sock.on('close', () => finish(body ? { ok: true, ...parseResponse(body), body } : { ok: false, err: 'closed with no response' }));
      sock.on('error', (e) => finish({ ok: false, err: `TLS ${e.code || e.message}` }));

      if (!path) {
        const proto = sock.getProtocol();
        sock.destroy();
        return finish({ ok: true, proto });
      }

      sock.write(buildRequest(host, path));
      timer = setTimeout(() => {
        try {
          sock.destroy();
        } catch {}
        if (!body) finish({ ok: false, err: 'TLS timeout' });
      }, timeout);
      if (timer.unref) timer.unref();
    };

    if (DIRECT) {
      const sock = tls.connect(
        { host, port: 443, servername: host, rejectUnauthorized: false, timeout },
        () => {
          const cert = sock.getPeerCertificate() || {};
          cn = (cert.subject && cert.subject.CN) || '-';
          onTls(sock);
        },
      );
      sock.on('timeout', () => {
        sock.destroy();
        finish({ ok: false, err: 'connect timeout' });
      });
      sock.on('error', (e) => finish({ ok: false, err: `TLS ${e.code || e.message}` }));
      return;
    }

    const req = http.request({
      host: PROXY_HOST,
      port: PROXY_PORT,
      method: 'CONNECT',
      path: `${host}:443`,
      timeout,
    });

    req.on('connect', (resp, socket) => {
      if (resp.statusCode !== 200) {
        socket.destroy();
        return finish({ ok: false, err: `proxy refused CONNECT (HTTP ${resp.statusCode})` });
      }

      const sock = tls.connect({ socket, servername: host, rejectUnauthorized: false }, () => {
        const cert = sock.getPeerCertificate() || {};
        cn = (cert.subject && cert.subject.CN) || '-';
        onTls(sock);
      });
      sock.on('error', (e) => finish({ ok: false, err: `TLS ${e.code || e.message}` }));
    });

    req.on('timeout', () => {
      req.destroy();
      finish({ ok: false, err: 'CONNECT timeout' });
    });
    req.on('error', (e) => finish({ ok: false, err: `CONNECT ${e.code || e.message}` }));
    req.end();
  });
}

function line(label, text, ok) {
  const mark = ok === undefined ? '  ' : ok ? 'OK' : 'XX';
  console.log(`  ${mark}  ${label.padEnd(30)} ${text}`);
}

console.log('=== ChatGPT connectivity self-check ===');
console.log(`mode ${TARGET}\n`);

const gateLabel = DIRECT ? 'chatgpt.com:443' : `${PROXY_HOST}:${PROXY_PORT}`;

// 1) is the tunnel (or the direct route) even alive?
const gate = await probe('chatgpt.com');
console.log(`[1/4] ${DIRECT ? 'direct connection' : 'local proxy'}`);
if (!gate.ok) {
  line(gateLabel, gate.err, false);
  if (DIRECT) {
    console.log('\nVERDICT: cannot open a TLS session to chatgpt.com directly.');
    console.log('  -> This network blocks ChatGPT (or DNS is hijacked).');
    console.log('  -> Start your accelerator and rerun, or pass its port: --proxy 127.0.0.1:<port>');
  } else {
    console.log('\nVERDICT: the local proxy is NOT usable.');
    console.log('  -> The accelerator core is stopped, or its node is down.');
    console.log('  -> Start (or reconnect) the accelerator, wait until it says "connected", then rerun.');
    console.log(`  -> If it listens on another port, pass it: --proxy 127.0.0.1:<port>`);
  }
  process.exit(1);
}
line(gateLabel, `reachable, TLS ${gate.proto}`, true);

// 2) every domain ChatGPT needs
console.log('\n[2/4] domains ChatGPT depends on');
const failed = [];
for (const h of HOSTS) {
  const r = await probe(h);
  line(h, r.ok ? `${r.ms}ms  cn=${r.cn}` : r.err, r.ok);
  if (!r.ok) failed.push(h);
}

// 3) where does traffic actually exit?
console.log('\n[3/4] exit node');
const trace = await probe('chatgpt.com', { path: '/cdn-cgi/trace' });
const exit = {};
if (trace.ok && trace.body) {
  for (const m of trace.body.matchAll(/^(ip|loc|colo|warp)=(.+)$/gm)) exit[m[1]] = m[2].trim();
}
if (exit.ip) {
  line('egress ip', `${exit.ip}  loc=${exit.loc}  colo=${exit.colo}  warp=${exit.warp}`, true);
} else {
  line('egress ip', 'could not read /cdn-cgi/trace', false);
}

// 4) does the actual page come back, and does it come back consistently?
console.log('\n[4/4] page load x10 (detects intermittent failures)');
let good = 0;
let challenged = 0;
let other = 0;
let lastTitle = '';
const reasons = new Map();
const bump = (k) => reasons.set(k, (reasons.get(k) || 0) + 1);
for (let i = 0; i < 10; i++) {
  const r = await probe('chatgpt.com', { path: '/' });
  const isChallenge =
    (r.ok && r.mitigated === 'challenge') || /Just a moment|请稍候/i.test(r.title || '');
  if (r.ok && r.status === '200' && !r.mitigated) {
    good++;
    lastTitle = r.title || lastTitle;
    process.stdout.write('  +');
  } else if (isChallenge) {
    challenged++;
    bump('Cloudflare challenge (HTTP ' + r.status + ')');
    process.stdout.write('  C');
  } else {
    other++;
    bump(r.ok ? `HTTP ${r.status} without challenge` : r.err || 'unknown');
    process.stdout.write('  X');
  }
  if (i < 9) await sleep(1200);
}
console.log('\n');
line('real page (HTTP 200)', `${good}/10`, good >= 8);
line('cloudflare challenge', `${challenged}/10`, challenged === 0);
line('hard failures', `${other}/10`, other === 0);
if (lastTitle) line('page title', lastTitle.slice(0, 60));
if (reasons.size) {
  console.log('  failures seen:');
  for (const [k, v] of reasons) console.log(`      x${v}  ${k}`);
}

console.log('\n=== VERDICT ===');
let exitCode = 0;
if (failed.length) {
  exitCode = 1;
  console.log(`Tunnel is broken for: ${failed.join(', ')}`);
  console.log('Fix: switch to another node/line in the accelerator, or restart it, then rerun.');
} else if (other > 0) {
  exitCode = 1;
  console.log('The tunnel drops or resets requests intermittently (not a Cloudflare challenge).');
  console.log('Fix: the current node is unstable - switch node/line and rerun.');
} else if (challenged > 3) {
  exitCode = 1;
  console.log(`Tunnel is fine, but Cloudflare challenged ${challenged}/10 page loads.`);
  console.log(`Exit IP ${exit.ip || '?'} (${exit.loc || '?'}) is heavily flagged - it is a datacenter IP.`);
  console.log('Fix: switch to a node with a residential / less-flagged IP. This is the usual cause of');
  console.log('     a browser sitting on "Just a moment..." / "请稍候..." and never opening ChatGPT.');
} else if (challenged > 0) {
  console.log(`Tunnel and exit node are OK. ${challenged}/10 requests got a Cloudflare challenge -`);
  console.log('this is normal noise for a datacenter exit IP; a real browser with JavaScript and');
  console.log('cookies normally solves it in a second or two.');
  console.log('If ChatGPT still hangs: reload once (or clear cookies for chatgpt.com), and prefer');
  console.log('the desktop app over the browser when the challenge loop repeats.');
} else {
  console.log('Everything is healthy: proxy, all ChatGPT domains, exit node, and real page load.');
  console.log('If ChatGPT still misbehaves, the problem is on the app side (stale cookies, hung');
  console.log('desktop app process, logged-out session, or the browser-bridge plugin), not the network.');
  console.log('For the browser-bridge plugin, run diagnose-chatgpt-chrome-bridge.ps1.');
}
console.log('');

process.exitCode = exitCode;
