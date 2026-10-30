import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
export const runtimeConfig = qa => `window.REEL_CONFIG = Object.freeze({ previewMode: ${qa === true}, appName: 'Reel', platform: 'desktop' });\n`;

export async function applyPackageFlavor(input, qa, stagePayload) {
  const flavor = JSON.stringify({ qa }) + '\n', config = runtimeConfig(qa);
  const manifestPath = resolve(input, 'web/asset-manifest.json');
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  manifest.files['reel-config.js'] = { sha256: hash(config), bytes: Buffer.byteLength(config) };
  const manifestText = JSON.stringify(manifest, null, 2) + '\n';
  await writeFile(resolve(input, 'build-flavor.json'), flavor);
  await writeFile(resolve(input, 'web/reel-config.js'), config);
  await writeFile(manifestPath, manifestText);
  return { ...stagePayload, 'build-flavor.json': hash(flavor), 'web/reel-config.js': hash(config), 'web/asset-manifest.json': hash(manifestText) };
}
