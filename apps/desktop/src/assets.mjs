import { createHash } from 'node:crypto';
import { lstat, readFile, realpath } from 'node:fs/promises';
import { resolve, sep } from 'node:path';
import { assetMime, assetPath, SECURITY_HEADERS } from './policy.mjs';

export async function loadAssets(root) {
  const rootInfo = await lstat(root);
  if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) throw new Error('Invalid app asset root');
  const base = await realpath(root), manifestPath = resolve(base, 'asset-manifest.json');
  const manifestInfo = await lstat(manifestPath);
  if (!manifestInfo.isFile() || manifestInfo.isSymbolicLink() || manifestInfo.size > 65536) throw new Error('Invalid app asset manifest file');
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  if (manifest.schema !== 1 || !manifest.files || Object.keys(manifest.files).length > 100) throw new Error('Invalid app asset manifest');
  const assets = new Map(); let total = 0;
  for (const [name, record] of Object.entries(manifest.files)) {
    if (assetPath('reel://app/' + name) !== name || !/^[a-f0-9]{64}$/.test(record.sha256) || !Number.isInteger(record.bytes) || record.bytes < 0 || record.bytes > 8 * 1024 * 1024) throw new Error('Invalid app asset record');
    let ancestor = base;
    for (const part of name.split('/').slice(0, -1)) { ancestor = resolve(ancestor, part); if ((await lstat(ancestor)).isSymbolicLink()) throw new Error('App asset parent is a link'); }
    const file = resolve(base, name), info = await lstat(file), canonical = await realpath(file);
    if (!info.isFile() || info.isSymbolicLink() || !canonical.startsWith(base + sep)) throw new Error('App asset escapes owned root');
    const bytes = await readFile(file); total += bytes.length;
    if (total > 16 * 1024 * 1024 || bytes.length !== record.bytes || createHash('sha256').update(bytes).digest('hex') !== record.sha256) throw new Error('App asset integrity failed');
    assets.set(name, { bytes, type: assetMime(name) });
  }
  if (!assets.has('index.html') || !assets.has('reel-config.js') || !assets.has('THIRD_PARTY_NOTICES.txt')) throw new Error('Required app assets missing');
  return assets;
}
export function assetResponse(assets, request) {
  const name = assetPath(request.url, request.method), asset = name && assets.get(name);
  if (!asset) return new Response('Not found', { status: 404, headers: { ...SECURITY_HEADERS, 'Content-Type': 'text/plain; charset=utf-8' } });
  return new Response(request.method === 'HEAD' ? null : asset.bytes, { headers: { ...SECURITY_HEADERS, 'Content-Type': asset.type, 'Content-Length': String(asset.bytes.length) } });
}
