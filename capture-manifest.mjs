// Capture the marketplace manifest the app writes into its staging directory.
//
// When the materialization key does not match, the app builds a fresh marketplace in
//   <runtimeRoot>.staging-<uuid>/.agents/plugins/marketplace.json
// and only then fails on the copy step. That file is the app's own filtered, expected manifest,
// which is exactly what the runtime marketplace has to contain — so we grab it while it exists
// (a few tens of milliseconds after the app writes it).
//
// Usage: node capture-manifest.mjs <parentDirOfRuntimeRoot> <outputFile>

import fs from 'node:fs';
import path from 'node:path';

const parent = process.argv[2];
const out = process.argv[3];
const deadline = Date.now() + 300000;

function attempt() {
  let entries = [];
  try {
    entries = fs.readdirSync(parent);
  } catch {
    return false;
  }
  for (const name of entries) {
    if (!/^openai-bundled\.staging-/.test(name)) continue;
    const manifest = path.join(parent, name, '.agents', 'plugins', 'marketplace.json');
    let buf;
    try {
      buf = fs.readFileSync(manifest, 'utf8');
    } catch {
      continue;
    }
    // The app creates the file first and writes its content a moment later, so an empty or
    // half-written read is normal: keep waiting instead of capturing nothing.
    if (!buf || !buf.trim()) continue;
    try {
      const parsed = JSON.parse(buf);
      if (!Array.isArray(parsed.plugins) || parsed.plugins.length === 0) continue;
    } catch {
      continue;
    }
    fs.writeFileSync(out, buf, 'utf8');
    console.log(`captured ${buf.length} bytes from ${name}`);
    return true;
  }
  return false;
}

const watcher = fs.watch(parent, () => {
  if (attempt()) {
    watcher.close();
    process.exit(0);
  }
});
const iv = setInterval(() => {
  if (attempt()) {
    clearInterval(iv);
    watcher.close();
    process.exit(0);
  }
  if (Date.now() > deadline) {
    clearInterval(iv);
    watcher.close();
    console.error('timeout');
    process.exit(2);
  }
}, 5);
