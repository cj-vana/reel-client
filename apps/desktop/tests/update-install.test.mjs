import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { crc32, deflateRawSync } from 'node:zlib';
import { executableInside, helperScript, removeLeftovers, stageRelease, takeResult } from '../src/update-install.mjs';
import { UpdateError } from '../src/update-package.mjs';

async function folder() { return mkdtemp(join(tmpdir(), "reel-install-o'k ")); }
const posix = process.platform !== 'win32';

// Lays out an installed copy and a staged new one the way the updater leaves them before the helper runs.
async function layout(root) {
  const app = join(root, 'Reel-linux-x64'), staging = join(root, '.reel-update-0.2.0-abcd1234'), staged = join(staging, 'Reel-linux-x64');
  await mkdir(app, { recursive: true }); await writeFile(join(app, 'version.txt'), 'old');
  await mkdir(staged, { recursive: true }); await writeFile(join(staged, 'version.txt'), 'new');
  return { app, staging, staged, resultFile: join(root, 'update-result.json') };
}
// The pid of a process that has already exited, so the helper does not wait.
const finished = () => spawnSync(process.execPath, ['-e', '']).pid;

test('the helper swaps the copies once Reel has quit and records the outcome', { skip: !posix }, async () => {
  const root = await folder();
  try {
    const paths = await layout(root);
    const script = helperScript({ platform: 'linux', pid: finished(), folder: paths.app, staging: paths.staging, staged: paths.staged, version: '0.2.0', resultFile: paths.resultFile, relaunch: false, executable: 'Reel' });
    await writeFile(join(paths.staging, 'finish-update.sh'), script);
    assert.equal(spawnSync('/bin/sh', [join(paths.staging, 'finish-update.sh')]).status, 0);
    assert.equal(await readFile(join(paths.app, 'version.txt'), 'utf8'), 'new');
    assert.deepEqual(JSON.parse(await readFile(paths.resultFile, 'utf8')), { version: '0.2.0', ok: true });
    // The staging folder, with the old copy in it, is gone.
    assert.deepEqual((await readdir(root)).sort(), ['Reel-linux-x64', 'update-result.json']);
    assert.deepEqual(await takeResult(root), { version: '0.2.0', ok: true });
    assert.equal(await takeResult(root), null);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('when the new copy cannot move in, the old one goes back and the failure is recorded', { skip: !posix }, async () => {
  const root = await folder();
  try {
    const paths = await layout(root);
    await rm(paths.staged, { recursive: true });
    const script = helperScript({ platform: 'linux', pid: finished(), folder: paths.app, staging: paths.staging, staged: paths.staged, version: '0.2.0', resultFile: paths.resultFile, relaunch: false, executable: 'Reel' });
    await writeFile(join(paths.staging, 'finish-update.sh'), script);
    spawnSync('/bin/sh', [join(paths.staging, 'finish-update.sh')]);
    assert.equal(await readFile(join(paths.app, 'version.txt'), 'utf8'), 'old');
    assert.deepEqual(JSON.parse(await readFile(paths.resultFile, 'utf8')), { version: '0.2.0', ok: false });
  } finally { await rm(root, { recursive: true, force: true }); }
});

// The same PowerShell command line startHelper uses.
const powershell = file => spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', file], { encoding: 'utf8' });
const windows = process.platform === 'win32';

test('on Windows the helper swaps the copies once Reel has quit and records the outcome', { skip: !windows }, async () => {
  const root = await folder();
  try {
    const paths = await layout(root);
    const script = helperScript({ platform: 'win32', pid: finished(), folder: paths.app, staging: paths.staging, staged: paths.staged, version: '0.2.0', resultFile: paths.resultFile, relaunch: false, executable: 'Reel.exe' });
    await writeFile(join(paths.staging, 'finish-update.ps1'), script);
    const run = powershell(join(paths.staging, 'finish-update.ps1'));
    assert.equal(run.status, 0, run.stderr);
    assert.equal(await readFile(join(paths.app, 'version.txt'), 'utf8'), 'new');
    assert.deepEqual(await takeResult(root), { version: '0.2.0', ok: true });
    assert.deepEqual(await readdir(root), ['Reel-linux-x64']);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('on Windows a copy that cannot move in leaves the old one and records the failure', { skip: !windows }, async () => {
  const root = await folder();
  try {
    const paths = await layout(root);
    await rm(paths.staged, { recursive: true });
    const script = helperScript({ platform: 'win32', pid: finished(), folder: paths.app, staging: paths.staging, staged: paths.staged, version: '0.2.0', resultFile: paths.resultFile, relaunch: false, executable: 'Reel.exe' });
    await writeFile(join(paths.staging, 'finish-update.ps1'), script);
    powershell(join(paths.staging, 'finish-update.ps1'));
    assert.equal(await readFile(join(paths.app, 'version.txt'), 'utf8'), 'old');
    assert.deepEqual(await takeResult(root), { version: '0.2.0', ok: false });
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('a ZIP made by 7-Zip, as the Windows release is, unpacks under its top folder', { skip: !windows || spawnSync('7z', ['i']).status !== 0 }, async () => {
  const root = await folder();
  try {
    const source = join(root, 'Reel-win32-x64');
    await mkdir(join(source, 'locales'), { recursive: true });
    await writeFile(join(source, 'Reel.exe'), 'binary'); await writeFile(join(source, 'locales', 'en-US.pak'), 'pak');
    assert.equal(spawnSync('7z', ['a', '-tzip', join(root, 'release.zip'), 'Reel-win32-x64'], { cwd: root }).status, 0);
    const location = { parent: root, folder: join(root, 'installed'), top: 'Reel-win32-x64' };
    const { staged } = await stageRelease({ platform: 'win32', zip: join(root, 'release.zip'), location, version: '0.2.0' });
    assert.equal(await readFile(join(staged, 'locales', 'en-US.pak'), 'utf8'), 'pak');
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('paths and arguments are quoted for each shell, and only Reel itself is started again', () => {
  const common = { pid: 42, folder: "/Apps/Sam's Reel", staging: "/Apps/.reel-update-1", staged: "/Apps/.reel-update-1/Reel-linux-x64", version: '0.2.0', resultFile: '/data/update-result.json' };
  const linux = helperScript({ ...common, platform: 'linux', relaunch: true, executable: 'Reel', args: ['--reel-qa-port=19700'] });
  assert.match(linux, /app='\/Apps\/Sam'\\''s Reel'/);
  assert.match(linux, /nohup "\$app"\/'Reel' '--reel-qa-port=19700' > \/dev\/null 2>&1 &/);
  const mac = helperScript({ ...common, platform: 'darwin', relaunch: true, executable: 'Contents/MacOS/Reel' });
  assert.match(mac, /\/usr\/bin\/open -n "\$app"$/m);
  assert.doesNotMatch(helperScript({ ...common, platform: 'darwin', relaunch: false, executable: 'Contents/MacOS/Reel' }), /open/);
  // A QA build carries its temporary folder through open, which otherwise starts Reel with the login environment.
  assert.match(helperScript({ ...common, platform: 'darwin', relaunch: true, executable: 'Contents/MacOS/Reel', env: { TMPDIR: "/tmp/qa o'k" } }), /\/usr\/bin\/open -n --env 'TMPDIR=\/tmp\/qa o'\\''k' "\$app"$/m);
  assert.throws(() => helperScript({ ...common, platform: 'darwin', relaunch: true, executable: 'Contents/MacOS/Reel', env: { 'BAD NAME': 'x' } }));
  const windows = helperScript({ ...common, platform: 'win32', folder: "C:\\Users\\Sam O'Neil\\Reel", relaunch: true, executable: 'Reel.exe' });
  assert.match(windows, /\$app = 'C:\\Users\\Sam O''Neil\\Reel'/);
  assert.match(windows, /Wait-Process -Id 42/);
  assert.match(windows, /Start-Process -FilePath \(Join-Path \$app 'Reel\.exe'\)/);
  assert.equal(executableInside('/Applications/Reel.app/Contents/MacOS/Reel', '/Applications/Reel.app'), 'Contents/MacOS/Reel');
});

// One stored entry and a folder, enough for the Linux staging path.
function zip(entries) {
  const locals = [], centrals = []; let offset = 0;
  for (const { name, data = Buffer.alloc(0), dir = false } of entries) {
    const nameBytes = Buffer.from(name), body = data.length ? deflateRawSync(data) : data, method = data.length ? 8 : 0;
    const local = Buffer.alloc(30), central = Buffer.alloc(46);
    local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt16LE(method, 8); local.writeUInt32LE(crc32(data) >>> 0, 14);
    local.writeUInt32LE(body.length, 18); local.writeUInt32LE(data.length, 22); local.writeUInt16LE(nameBytes.length, 26);
    central.writeUInt32LE(0x02014b50, 0); central.writeUInt16LE((3 << 8) | 20, 4); central.writeUInt16LE(20, 6); central.writeUInt16LE(method, 10);
    central.writeUInt32LE(crc32(data) >>> 0, 16); central.writeUInt32LE(body.length, 20); central.writeUInt32LE(data.length, 24); central.writeUInt16LE(nameBytes.length, 28);
    central.writeUInt32LE((((dir ? 0o040755 : 0o100755)) << 16) >>> 0, 38); central.writeUInt32LE(offset, 42);
    locals.push(local, nameBytes, body); centrals.push(central, nameBytes); offset += 30 + nameBytes.length + body.length;
  }
  const directory = Buffer.concat(centrals), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10); end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}

test('staging unpacks beside the installed copy, and a bad package leaves nothing', async () => {
  const root = await folder();
  try {
    const location = { parent: root, folder: join(root, 'Reel-linux-x64'), top: 'Reel-linux-x64' };
    await writeFile(join(root, 'good.zip'), zip([{ name: 'Reel-linux-x64/', dir: true }, { name: 'Reel-linux-x64/Reel', data: Buffer.from('binary') }]));
    const { staging, staged } = await stageRelease({ platform: 'linux', zip: join(root, 'good.zip'), location, version: '0.2.0' });
    assert.ok(staging.startsWith(join(root, '.reel-update-0.2.0-')));
    assert.equal(await readFile(join(staged, 'Reel'), 'utf8'), 'binary');
    await writeFile(join(root, 'bad.zip'), zip([{ name: 'Elsewhere/Reel', data: Buffer.from('x') }]));
    await assert.rejects(stageRelease({ platform: 'linux', zip: join(root, 'bad.zip'), location, version: '0.3.0' }), error => error instanceof UpdateError && error.code === 'package');
    assert.equal((await readdir(root)).filter(name => name.startsWith('.reel-update-0.3.0')).length, 0);
    await removeLeftovers(root);
    assert.equal((await readdir(root)).filter(name => name.startsWith('.reel-update-')).length, 0);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('on macOS the bundle is unpacked by ditto without quarantine and must pass its signature check', async () => {
  const root = await folder();
  try {
    const location = { parent: root, folder: join(root, 'Reel.app'), top: 'Reel.app' };
    const calls = [];
    const run = async (command, args) => {
      calls.push([command, ...args]);
      if (command.endsWith('ditto')) await mkdir(join(args.at(-1), 'Reel.app'), { recursive: true });
      return '';
    };
    const { staged } = await stageRelease({ platform: 'darwin', zip: '/downloads/reel.zip', location, version: '0.2.0', run });
    assert.ok((await stat(staged)).isDirectory());
    assert.deepEqual(calls.map(call => call[0]), ['/usr/bin/ditto', '/usr/bin/find', '/usr/bin/codesign']);
    assert.deepEqual(calls[0].slice(1, 4), ['-x', '-k', '--noqtn']);
    // A quarantined copy, or one whose signature fails, is refused and removed.
    const quarantined = async (command, args) => { if (command.endsWith('ditto')) await mkdir(join(args.at(-1), 'Reel.app'), { recursive: true }); return command.endsWith('find') ? '/x/Reel.app/Contents/Info.plist\n' : ''; };
    await assert.rejects(stageRelease({ platform: 'darwin', zip: '/downloads/reel.zip', location, version: '0.3.0', run: quarantined }), error => error.code === 'package');
    assert.equal((await readdir(root)).filter(name => name.startsWith('.reel-update-0.3.0')).length, 0);
  } finally { await rm(root, { recursive: true, force: true }); }
});
