// Writes and signs the manifest that tells installed desktop apps about a release:
//   DESKTOP_UPDATE_KEY=<base64 PKCS#8 Ed25519 key> node scripts/update-manifest.mjs <version> <out dir> <zip>...
// Each ZIP must be named reel-desktop-<label>-v<version>.zip. The manifest is checked with the public key in
// src/update-key.mjs before it is written, so a release can never carry a manifest the app would refuse.
import { createHash, createPrivateKey, sign } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { MANIFEST, REPOSITORY, SIGNATURE, TARGETS, extractZip, readManifest } from '../src/update-package.mjs';
import { UPDATE_PUBLIC_KEY } from '../src/update-key.mjs';

/** The manifest bytes for `version` from the release ZIPs: [{ name, bytes }]. */
export function manifestFor(version, zips, date = new Date().toISOString()) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error('A release version is MAJOR.MINOR.PATCH');
  const files = {};
  for (const { name, bytes } of zips) {
    const target = Object.keys(TARGETS).find(key => name === `reel-desktop-${TARGETS[key]}-v${version}.zip`);
    if (!target || files[target]) throw new Error('Unexpected desktop package ' + name);
    files[target] = { name, sha256: createHash('sha256').update(bytes).digest('hex'), size: bytes.length };
  }
  if (!Object.keys(files).length) throw new Error('No desktop packages');
  return Buffer.from(JSON.stringify({ schema: 1, product: 'reel-desktop', repository: REPOSITORY, version, tag: 'v' + version, date, files }, null, 2) + '\n');
}

export function signManifest(bytes, secret, publicKey) {
  const key = createPrivateKey({ key: Buffer.from(secret, 'base64'), format: 'der', type: 'pkcs8' });
  const signature = sign(null, bytes, key).toString('base64');
  // Every listed platform must read back exactly as the app will read it.
  const manifest = JSON.parse(bytes.toString('utf8'));
  for (const target of Object.keys(manifest.files)) readManifest(bytes, signature, publicKey, target);
  return signature;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [version, out, ...paths] = process.argv.slice(2);
  if (!process.env.DESKTOP_UPDATE_KEY) throw new Error('DESKTOP_UPDATE_KEY is not set');
  if (!UPDATE_PUBLIC_KEY) throw new Error('src/update-key.mjs has no public key; run scripts/update-signing-key.mjs first');
  const zips = await Promise.all(paths.map(async path => ({ name: basename(path), bytes: await readFile(path) })));
  const bytes = manifestFor(version, zips);
  const signature = signManifest(bytes, process.env.DESKTOP_UPDATE_KEY, UPDATE_PUBLIC_KEY);
  // Windows and Linux copies unpack updates with Reel's own ZIP reader, so each of those ZIPs must pass it here
  // first. (macOS uses ditto.)
  for (const path of paths) {
    const target = Object.keys(TARGETS).find(key => basename(path) === `reel-desktop-${TARGETS[key]}-v${version}.zip`);
    if (target.startsWith('darwin-')) continue;
    const folder = await mkdtemp(join(tmpdir(), 'reel-zip-check-'));
    try { await extractZip(path, join(folder, 'out'), 'Reel-' + target); } finally { await rm(folder, { recursive: true, force: true }); }
  }
  await writeFile(resolve(out, MANIFEST), bytes);
  await writeFile(resolve(out, SIGNATURE), signature + '\n');
  console.log(`Signed the desktop update manifest for ${version}: ${Object.keys(JSON.parse(bytes.toString('utf8')).files).join(', ')}`);
}
