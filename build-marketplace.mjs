// Build a fresh runtime marketplace for the ChatGPT/Codex desktop app, without the app's own
// copy step (which fails on machines where the MSIX package files carry the EFS "Encrypted"
// attribute but the system cannot encrypt destination files).
//
// Why a read+write copy: fs.cp / CopyFileEx ask Windows to copy the encrypted attribute as well,
// so they fail with Win32 0x80071770 ("The specified file could not be encrypted"). Reading a file
// and writing its bytes out always works, so we reproduce the copy by hand.
//
// Usage:
//   node build-marketplace.mjs <srcRoot> <capturedManifest> <stagingDir> <appVersion> <cuVariant> <lvVariant> <audio:0|1>
//
// It mirrors what the app does (module `BundledPluginsMarketplace`):
//   1. write the app's own filtered manifest to <staging>/.agents/plugins/marketplace.json
//   2. copy every plugin listed there from the package into <staging>
//   3. apply the variant post-processing (visualize: bundledContentVariant, and drop skills/live
//      when the live variant is disabled)
//   4. write .materialization-key with exactly the app's field order
//   5. self-check the three conditions the app compares before it reuses a runtime marketplace,
//      and exit 1 unless all of them hold (so we never swap in a tree that cannot be reused)

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const [srcRoot, capturedPath, stagingDir, appVersion, cuArg, lvArg, audioArg] = process.argv.slice(2);

if (!srcRoot || !capturedPath || !stagingDir || !appVersion) {
  console.error(
    'usage: node build-marketplace.mjs <srcRoot> <capturedManifest> <stagingDir> <appVersion> <cuVariant|null> <lvVariant|null> <audio:0|1>',
  );
  process.exit(2);
}

const cu = cuArg === 'null' || cuArg === undefined ? null : cuArg;
const lv = lvArg === 'null' || lvArg === undefined ? null : lvArg;
const audio = audioArg === '1';
const VISUALIZE = 'visualize';
const MARKETPLACE_NAME = 'openai-bundled';

const sha256 = (text) => crypto.createHash('sha256').update(text).digest('hex');
const rmrf = (p) => fs.rmSync(p, { recursive: true, force: true });

// A copy that deliberately does NOT preserve the EFS attribute: read the bytes, write the bytes.
function copyTree(from, to) {
  const st = fs.lstatSync(from);
  if (st.isSymbolicLink()) {
    copyTree(fs.realpathSync(from), to);
    return;
  }
  if (st.isDirectory()) {
    fs.mkdirSync(to, { recursive: true });
    for (const name of fs.readdirSync(from)) copyTree(path.join(from, name), path.join(to, name));
    return;
  }
  fs.mkdirSync(path.dirname(to), { recursive: true });
  fs.writeFileSync(to, fs.readFileSync(from));
}

const manifestText = fs.readFileSync(capturedPath, 'utf8');
const manifest = JSON.parse(manifestText);

rmrf(stagingDir);
fs.mkdirSync(path.join(stagingDir, '.agents', 'plugins'), { recursive: true });
fs.writeFileSync(path.join(stagingDir, '.agents', 'plugins', 'marketplace.json'), manifestText);

const bundleId = fs.readFileSync(path.join(srcRoot, '.bundle-id'), 'utf8').trim();
fs.writeFileSync(path.join(stagingDir, '.bundle-id'), `${bundleId}\n`);

const plugins = [];
let copiedFiles = 0;
for (const entry of manifest.plugins) {
  const from = path.resolve(srcRoot, entry.source.path);
  const to = path.resolve(stagingDir, entry.source.path);
  copyTree(from, to);
  copiedFiles += countFiles(to);

  const pluginJsonPath = path.join(to, '.codex-plugin', 'plugin.json');
  const pluginJson = JSON.parse(fs.readFileSync(pluginJsonPath, 'utf8'));
  plugins.push({ name: pluginJson.name, version: pluginJson.version });

  // Same post-processing the app applies right after copying a plugin.
  let variant;
  if (pluginJson.name === 'computer-use') variant = cu;
  else if (pluginJson.name === VISUALIZE) variant = lv;
  if (variant == null) continue;
  if (pluginJson.name === VISUALIZE && lv === 'live-disabled') rmrf(path.join(to, 'skills', 'live'));
  fs.writeFileSync(
    pluginJsonPath,
    `${JSON.stringify({ ...pluginJson, bundledContentVariant: variant }, null, 2)}\n`,
  );
}
plugins.sort((a, b) => a.name.localeCompare(b.name));

function countFiles(dir) {
  let n = 0;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) n += countFiles(path.join(dir, e.name));
    else n += 1;
  }
  return n;
}

const visualize = manifest.plugins.find((p) => p.name === VISUALIZE);
const srcVisualizeSkill = visualize
  ? path.join(srcRoot, visualize.source.path, 'skills', 'visualize', 'SKILL.md')
  : null;
const srcVisualizeText = srcVisualizeSkill && fs.existsSync(srcVisualizeSkill)
  ? fs.readFileSync(srcVisualizeSkill, 'utf8')
  : undefined;

// Field order matters: the app compares the file against JSON.stringify(...) of its own object.
const key = JSON.stringify({
  version: 1,
  appVersion,
  bundleId,
  marketplaceName: MARKETPLACE_NAME,
  computerUseSkillVariant: cu,
  computerUseAudioEnabled: cu !== 'legacy-mcp' && plugins.some((p) => p.name === 'computer-use') && audio,
  liveVisualizationSkillVariant: lv,
  visualizeTreatment: false,
  ...(srcVisualizeText === undefined ? {} : { visualizeSkillContentHash: sha256(srcVisualizeText) }),
  plugins,
});
fs.writeFileSync(path.join(stagingDir, '.materialization-key'), `${key}\n`);

// ---- self-check: the three conditions _re() compares before reusing a runtime marketplace ----
// zod rebuilds objects in schema order and drops unknown keys, so normalise both sides the same way.
const normalize = (m) => ({
  name: m.name,
  ...(m.interface === undefined ? {} : { interface: m.interface }),
  plugins: m.plugins.map((p) => ({ name: p.name, source: { source: p.source.source, path: p.source.path } })),
});

const stagedManifest = JSON.parse(
  fs.readFileSync(path.join(stagingDir, '.agents', 'plugins', 'marketplace.json'), 'utf8'),
);
const stagedKey = fs.readFileSync(path.join(stagingDir, '.materialization-key'), 'utf8');
const stagedVisualizeText = visualize
  ? fs.readFileSync(path.join(stagingDir, visualize.source.path, 'skills', 'visualize', 'SKILL.md'), 'utf8')
  : undefined;

const checks = {
  keyMatches: stagedKey === `${key}\n`,
  manifestMatches: JSON.stringify(normalize(stagedManifest)) === JSON.stringify(normalize(manifest)),
  visualizeSkillMatches: visualize === undefined || stagedVisualizeText === srcVisualizeText,
  everyPluginRootValid: manifest.plugins.every((p) => {
    try {
      const pj = JSON.parse(
        fs.readFileSync(path.join(stagingDir, p.source.path, '.codex-plugin', 'plugin.json'), 'utf8'),
      );
      return pj.name === p.name;
    } catch {
      return false;
    }
  }),
};

const ok = Object.values(checks).every(Boolean);
console.log(
  JSON.stringify(
    {
      ok,
      checks,
      staging: stagingDir,
      appVersion,
      computerUseSkillVariant: cu,
      liveVisualizationSkillVariant: lv,
      computerUseAudioEnabled: audio,
      pluginCount: plugins.length,
      pluginNames: plugins.map((p) => `${p.name}@${p.version}`),
      copiedFiles,
      materializationKey: key,
    },
    null,
    2,
  ),
);
process.exit(ok ? 0 : 1);
