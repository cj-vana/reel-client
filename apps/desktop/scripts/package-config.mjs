import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
export const runtimeConfig = qa => `window.REEL_CONFIG = Object.freeze({ previewMode: ${qa === true}, appName: 'Reel', platform: 'desktop' });\n`;

// signed: the package will be signed with a Developer ID (macOS only).
// test: QA builds only. updateKey is the update key an update test signs with, and version replaces the app version,
// so a test can build an older and a newer package from one source tree.
export async function applyPackageFlavor(input, qa, stagePayload, signed = false, test = {}) {
  const updateKey = qa && typeof test.updateKey === 'string' ? test.updateKey : undefined;
  const flavor = JSON.stringify({ qa, signed: signed === true, ...(updateKey ? { updateKey } : {}) }) + '\n', config = runtimeConfig(qa);
  const manifestPath = resolve(input, 'web/asset-manifest.json');
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  manifest.files['reel-config.js'] = { sha256: hash(config), bytes: Buffer.byteLength(config) };
  const manifestText = JSON.stringify(manifest, null, 2) + '\n';
  await writeFile(resolve(input, 'build-flavor.json'), flavor);
  await writeFile(resolve(input, 'web/reel-config.js'), config);
  await writeFile(manifestPath, manifestText);
  const payload = { ...stagePayload, 'build-flavor.json': hash(flavor), 'web/reel-config.js': hash(config), 'web/asset-manifest.json': hash(manifestText) };
  if (qa && test.version) {
    if (!/^\d+\.\d+\.\d+$/.test(test.version)) throw new Error('A test version is MAJOR.MINOR.PATCH');
    const packagePath = resolve(input, 'package.json'), packageText = JSON.stringify({ ...JSON.parse(await readFile(packagePath, 'utf8')), version: test.version }, null, 2) + '\n';
    await writeFile(packagePath, packageText);
    payload['package.json'] = hash(packageText);
  }
  return payload;
}
