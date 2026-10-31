import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign, createHash } from 'node:crypto';
import { mkdtemp, mkdir, readFile, readdir, readlink, rm, stat, symlink, writeFile, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { crc32, deflateRawSync } from 'node:zlib';
import { compareVersions, downloadFile, extractZip, installLocation, readManifest, readSmall, releaseURLs, RELEASES, UpdateError } from '../src/update-package.mjs';

const keys = generateKeyPairSync('ed25519');
const publicKey = keys.publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
const signed = value => { const bytes = Buffer.from(JSON.stringify(value)); return { bytes, signature: sign(null, bytes, keys.privateKey).toString('base64') }; };
const digest = 'a'.repeat(64);
const manifest = (change = {}) => ({ schema: 1, product: 'reel-desktop', repository: 'cj-vana/reel-client', version: '0.2.0', tag: 'v0.2.0', date: '2026-10-30T00:00:00Z',
  files: { 'darwin-arm64': { name: 'reel-desktop-macos-arm64-v0.2.0.zip', sha256: digest, size: 1000 }, 'linux-x64': { name: 'reel-desktop-linux-x64-v0.2.0.zip', sha256: digest, size: 1000 } }, ...change });
const code = expected => error => error instanceof UpdateError && error.code === expected;
async function folder() { return mkdtemp(join(tmpdir(), 'reel-update-')); }

// A small ZIP writer, so each test can describe exactly the entries a hostile or broken package would hold.
function zip(entries) {
  const locals = [], centrals = [];
  let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name), content = entry.link !== undefined ? Buffer.from(entry.link) : entry.data ?? Buffer.alloc(0);
    const method = entry.method ?? (content.length ? 8 : 0), body = method === 8 ? deflateRawSync(content) : content;
    const crc = (entry.crc ?? crc32(content)) >>> 0;
    const type = entry.link !== undefined ? 0o120000 : entry.dir ? 0o040000 : 0o100000;
    const external = ((type | (entry.mode ?? (entry.dir ? 0o755 : 0o644))) << 16) >>> 0;
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt16LE(0x800, 6); local.writeUInt16LE(method, 8);
    local.writeUInt32LE(crc, 14); local.writeUInt32LE(body.length, 18); local.writeUInt32LE(content.length, 22); local.writeUInt16LE(name.length, 26);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0); central.writeUInt16LE((3 << 8) | 20, 4); central.writeUInt16LE(20, 6); central.writeUInt16LE(0x800, 8);
    central.writeUInt16LE(method, 10); central.writeUInt32LE(crc, 16); central.writeUInt32LE(body.length, 20); central.writeUInt32LE(content.length, 24);
    central.writeUInt16LE(name.length, 28); central.writeUInt32LE(external, 38); central.writeUInt32LE(offset, 42);
    locals.push(local, name, body); centrals.push(central, name);
    offset += local.length + name.length + body.length;
  }
  const directory = Buffer.concat(centrals), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}

test('versions and release addresses', () => {
  assert.equal(compareVersions('0.2.0', 'v0.1.9'), 1); assert.equal(compareVersions('v1.0.0', '1.0.0'), 0); assert.equal(compareVersions('1.0.0-beta', '1.0.0'), -1);
  assert.ok(Number.isNaN(compareVersions('latest', '1.0.0')));
  const urls = releaseURLs();
  assert.equal(urls.manifest, RELEASES + '/latest/download/reel-desktop-update.json');
  assert.equal(urls.signature, RELEASES + '/latest/download/reel-desktop-update.json.sig');
  assert.equal(urls.asset('v0.2.0', 'reel-desktop-linux-x64-v0.2.0.zip'), RELEASES + '/download/v0.2.0/reel-desktop-linux-x64-v0.2.0.zip');
  assert.equal(releaseURLs('http://127.0.0.1:19700/releases/').manifest, 'http://127.0.0.1:19700/releases/latest/download/reel-desktop-update.json');
});

test('a manifest is used only with a valid signature from the app key, and only in the expected shape', () => {
  const { bytes, signature } = signed(manifest());
  assert.deepEqual(readManifest(bytes, signature, publicKey, 'linux-x64'), { version: '0.2.0', tag: 'v0.2.0', file: { name: 'reel-desktop-linux-x64-v0.2.0.zip', sha256: digest, size: 1000 } });
  assert.throws(() => readManifest(Buffer.concat([bytes, Buffer.from(' ')]), signature, publicKey, 'linux-x64'), code('signature'));
  const other = generateKeyPairSync('ed25519').publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
  assert.throws(() => readManifest(bytes, signature, other, 'linux-x64'), code('signature'));
  assert.throws(() => readManifest(bytes, 'not a signature', publicKey, 'linux-x64'), code('signature'));
  assert.throws(() => readManifest(bytes, signature, 'not a key', 'linux-x64'), code('signature'));
  const rsa = generateKeyPairSync('rsa', { modulusLength: 1024 }).publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
  assert.throws(() => readManifest(bytes, signature, rsa, 'linux-x64'), code('signature'));
  // A platform the release does not cover.
  assert.throws(() => readManifest(bytes, signature, publicKey, 'win32-x64'), code('manifest'));
  for (const change of [{ schema: 2 }, { product: 'other' }, { repository: 'someone/else' }, { version: '0.2' }, { tag: 'v0.3.0' },
    { files: { 'linux-x64': { name: 'reel-desktop-linux-x64-v0.1.0.zip', sha256: digest, size: 1000 } } },
    { files: { 'linux-x64': { name: 'reel-desktop-linux-x64-v0.2.0.zip', sha256: 'A'.repeat(64), size: 1000 } } },
    { files: { 'linux-x64': { name: 'reel-desktop-linux-x64-v0.2.0.zip', sha256: digest, size: 0 } } },
    { files: { 'linux-x64': { name: 'reel-desktop-linux-x64-v0.2.0.zip', sha256: digest, size: 2 * 1024 ** 3 } } }]) {
    const tampered = signed(manifest(change));
    assert.throws(() => readManifest(tampered.bytes, tampered.signature, publicKey, 'linux-x64'), code('manifest'), JSON.stringify(change));
  }
});

const respond = (body, status = 200) => async () => new Response(body, { status });

test('small reads stop at their limit, and a missing manifest reads as none', async () => {
  assert.equal(await readSmall(respond('missing', 404), 'https://example.test/m'), null);
  assert.deepEqual(await readSmall(respond('hello'), 'https://example.test/m'), Buffer.from('hello'));
  await assert.rejects(readSmall(respond('x'.repeat(70_000)), 'https://example.test/m'), code('manifest'));
  await assert.rejects(readSmall(respond('error', 500), 'https://example.test/m'), code('manifest'));
});

test('a download is kept only when its size and SHA-256 match', async () => {
  const root = await folder(), body = Buffer.from('reel update package'), hash = createHash('sha256').update(body).digest('hex');
  try {
    const progress = [];
    await downloadFile(respond(body), 'https://example.test/p.zip', join(root, 'p.zip'), { sha256: hash, size: body.length }, { onProgress: value => progress.push(value) });
    assert.deepEqual(await readFile(join(root, 'p.zip')), body);
    assert.equal(progress.at(-1), 1);
    for (const [name, expected] of [['wrong.zip', { sha256: 'b'.repeat(64), size: body.length }], ['short.zip', { sha256: hash, size: body.length + 1 }], ['long.zip', { sha256: hash, size: body.length - 1 }]]) {
      await assert.rejects(downloadFile(respond(body), 'https://example.test/p.zip', join(root, name), expected), code('download'), name);
    }
    await assert.rejects(downloadFile(respond('gone', 404), 'https://example.test/p.zip', join(root, 'missing.zip'), { sha256: hash, size: body.length }), code('download'));
    assert.deepEqual((await readdir(root)).sort(), ['p.zip']);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('a package unpacks with its modes and inside links, all under its top folder', async () => {
  const root = await folder();
  try {
    const archive = join(root, 'package.zip');
    await writeFile(archive, zip([
      { name: 'Reel-linux-x64/', dir: true },
      { name: 'Reel-linux-x64/Reel', data: Buffer.from('#!/bin/sh\necho reel\n'), mode: 0o755 },
      { name: 'Reel-linux-x64/resources/app.asar', data: Buffer.alloc(200_000, 7) },
      { name: 'Reel-linux-x64/stored.txt', data: Buffer.from('stored'), method: 0 },
      { name: 'Reel-linux-x64/lib/current', link: '../resources' }
    ]));
    await extractZip(archive, join(root, 'out'), 'Reel-linux-x64');
    const app = join(root, 'out', 'Reel-linux-x64');
    assert.equal((await readFile(join(app, 'Reel'), 'utf8')).split('\n')[1], 'echo reel');
    if (process.platform !== 'win32') assert.equal((await stat(join(app, 'Reel'))).mode & 0o777, 0o755);
    assert.deepEqual(await readFile(join(app, 'resources/app.asar')), Buffer.alloc(200_000, 7));
    assert.equal(await readFile(join(app, 'stored.txt'), 'utf8'), 'stored');
    if (process.platform !== 'win32') assert.equal(await readlink(join(app, 'lib/current')), '../resources');
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('a hostile or broken package is refused and leaves nothing behind', async () => {
  const root = await folder();
  try {
    const cases = {
      'climbs out': [{ name: 'Reel-linux-x64/../evil', data: Buffer.from('x') }],
      'absolute': [{ name: '/etc/evil', data: Buffer.from('x') }],
      'drive letter': [{ name: 'C:/evil', data: Buffer.from('x') }],
      'other folder': [{ name: 'Reel-linux-x64/ok', data: Buffer.from('x') }, { name: 'Other/evil', data: Buffer.from('x') }],
      'duplicate': [{ name: 'Reel-linux-x64/a', data: Buffer.from('x') }, { name: 'Reel-linux-x64/a', data: Buffer.from('y') }],
      'link out': [{ name: 'Reel-linux-x64/escape', link: '../../outside' }],
      'absolute link': [{ name: 'Reel-linux-x64/escape', link: '/etc' }],
      'write through link': [{ name: 'Reel-linux-x64/lib', link: 'resources' }, { name: 'Reel-linux-x64/lib/evil', data: Buffer.from('x') }],
      'bad checksum': [{ name: 'Reel-linux-x64/a', data: Buffer.from('content'), crc: 1234 }],
      'backslash': [{ name: 'Reel-linux-x64\\evil', data: Buffer.from('x') }]
    };
    for (const [label, entries] of Object.entries(cases)) {
      const archive = join(root, 'case.zip'), out = join(root, 'out');
      await writeFile(archive, zip(entries));
      await assert.rejects(extractZip(archive, out, 'Reel-linux-x64'), code('package'), label);
      await assert.rejects(stat(out), { code: 'ENOENT' }, label);
    }
    await writeFile(join(root, 'junk.zip'), Buffer.from('not a zip at all'));
    await assert.rejects(extractZip(join(root, 'junk.zip'), join(root, 'out'), 'Reel-linux-x64'), code('package'));
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('a package made by the system zip tool unpacks the same', { skip: spawnSync('zip', ['-v']).status !== 0 || process.platform === 'win32' }, async () => {
  const root = await folder();
  try {
    const source = join(root, 'Reel-linux-x64');
    await mkdir(join(source, 'resources'), { recursive: true });
    await writeFile(join(source, 'Reel'), 'binary'); await chmod(join(source, 'Reel'), 0o755);
    await writeFile(join(source, 'resources', 'app.asar'), Buffer.alloc(100_000, 3));
    await symlink('resources/app.asar', join(source, 'current'));
    assert.equal(spawnSync('zip', ['-qry', 'package.zip', 'Reel-linux-x64'], { cwd: root }).status, 0);
    await extractZip(join(root, 'package.zip'), join(root, 'out'), 'Reel-linux-x64');
    const app = join(root, 'out', 'Reel-linux-x64');
    assert.equal((await stat(join(app, 'Reel'))).mode & 0o777, 0o755);
    assert.deepEqual(await readFile(join(app, 'resources', 'app.asar')), Buffer.alloc(100_000, 3));
    assert.equal(await readlink(join(app, 'current')), 'resources/app.asar');
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('the install location: a writable bundle or folder, never a translocated copy', async () => {
  const yes = async () => true, no = async () => false;
  assert.deepEqual(await installLocation({ platform: 'darwin', arch: 'arm64', execPath: '/Applications/Reel.app/Contents/MacOS/Reel', name: 'Reel', writable: yes }),
    { ok: true, folder: '/Applications/Reel.app', parent: '/Applications', top: 'Reel.app', target: 'darwin-arm64' });
  assert.deepEqual(await installLocation({ platform: 'darwin', arch: 'arm64', execPath: '/var/folders/x/AppTranslocation/ABC/d/Reel.app/Contents/MacOS/Reel', name: 'Reel', writable: yes }), { ok: false, reason: 'translocated' });
  assert.deepEqual(await installLocation({ platform: 'darwin', arch: 'arm64', execPath: '/usr/local/bin/Reel', name: 'Reel', writable: yes }), { ok: false, reason: 'location' });
  assert.deepEqual(await installLocation({ platform: 'darwin', arch: 'arm64', execPath: '/Applications/Reel.app/Contents/MacOS/Reel', name: 'Reel', writable: no }), { ok: false, reason: 'permission' });
  assert.deepEqual(await installLocation({ platform: 'darwin', arch: 'x64', execPath: '/Applications/Reel.app/Contents/MacOS/Reel', name: 'Reel', writable: yes }), { ok: false, reason: 'platform' });
  assert.deepEqual(await installLocation({ platform: 'linux', arch: 'x64', execPath: '/home/example/Apps/Reel-linux-x64/Reel', name: 'Reel', writable: yes }),
    { ok: true, folder: '/home/example/Apps/Reel-linux-x64', parent: '/home/example/Apps', top: 'Reel-linux-x64', target: 'linux-x64' });
  assert.deepEqual(await installLocation({ platform: 'win32', arch: 'x64', execPath: 'C:\\Programs\\Reel\\Reel.exe', name: 'Reel', writable: yes }),
    { ok: true, folder: 'C:\\Programs\\Reel', parent: 'C:\\Programs', top: 'Reel-win32-x64', target: 'win32-x64' });
  assert.deepEqual(await installLocation({ platform: 'win32', arch: 'x64', execPath: 'C:\\Program Files\\Reel\\Reel.exe', name: 'Reel', writable: async path => path !== 'C:\\Program Files' }), { ok: false, reason: 'permission' });
  // A Mac copy outside an Applications folder, such as one opened from a disk image.
  assert.deepEqual(await installLocation({ platform: 'darwin', arch: 'arm64', execPath: '/Volumes/Reel/Reel.app/Contents/MacOS/Reel', name: 'Reel', inApplications: false, writable: yes }), { ok: false, reason: 'location' });
  // Linux: a setuid root sandbox helper keeps the copy as it is; an ordinary one does not.
  const linux = { platform: 'linux', arch: 'x64', execPath: '/home/example/Apps/Reel-linux-x64/Reel', name: 'Reel', writable: yes };
  assert.deepEqual(await installLocation({ ...linux, info: async () => ({ uid: 0, mode: 0o104755 }) }), { ok: false, reason: 'sandbox' });
  assert.equal((await installLocation({ ...linux, info: async () => ({ uid: 1000, mode: 0o100755 }) })).ok, true);
  assert.equal((await installLocation({ ...linux, info: async () => { throw Object.assign(new Error('missing'), { code: 'ENOENT' }); } })).ok, true);
});
