import { createHash } from 'node:crypto';
import { readFile, writeFile, mkdir, cp, rm } from 'node:fs/promises';
import { resolve, relative, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { packager } from '@electron/packager';
import { flipFuses, getCurrentFuseWire, FuseVersion, FuseV1Options } from '@electron/fuses';
import { listPackage, extractFile, statFile } from '@electron/asar';
import { packageManifest } from './package-manifest.mjs';
import { applyPackageFlavor } from './package-config.mjs';
import { root, payloadManifest, manifestsEqual, assertBuildCurrent } from './source-revision.mjs';

const argument = key => process.argv.find(value => value.startsWith('--' + key + '='))?.slice(key.length + 3);
const platform = argument('platform') ?? process.platform, arch = argument('arch') ?? process.arch, qa = process.argv.includes('--qa');
const checksums = JSON.parse(await readFile(resolve(root, 'scripts/electron-checksums.json'))), target = platform + '-' + arch;
if (!Object.hasOwn(checksums.sha256, target)) throw new Error('Unsupported platform/architecture');
const build = JSON.parse(await readFile(resolve(root, '.cache/build.json'))), stage = resolve(root, '.cache/stage');
const source = await assertBuildCurrent(build, { stage });
const zipDir = resolve(root, '.cache/electron'), zipName = `electron-v${checksums.version}-${target}.zip`, zip = resolve(zipDir, zipName);
await mkdir(zipDir, { recursive: true });
try { await readFile(zip); } catch {
  const response = await fetch(`https://github.com/electron/electron/releases/download/v${checksums.version}/${zipName}`, { signal: AbortSignal.timeout(180000) });
  if (!response.ok) throw new Error('Electron download failed');
  await writeFile(zip, new Uint8Array(await response.arrayBuffer()), { flag: 'wx' });
}
const runtimeSha256 = createHash('sha256').update(await readFile(zip)).digest('hex');
if (runtimeSha256 !== checksums.sha256[target]) throw new Error('Electron archive checksum mismatch');
const flavor = qa ? 'qa' : 'production', input = resolve(root, '.cache/package-input-' + flavor);
// The release workflow sets REEL_MACOS_SIGN=1 once it has imported a Developer ID certificate. Local and QA
// packages stay ad hoc signed.
const sign = platform === 'darwin' && !qa && process.env.REEL_MACOS_SIGN === '1';
await rm(input, { recursive: true, force: true }); await cp(stage, input, { recursive: true });
const expected = await applyPackageFlavor(input, qa, build.stagePayload, sign);
if (!manifestsEqual(await payloadManifest(input), expected)) throw new Error('Package input does not match verified build');
const name = qa ? 'Reel Desktop QA' : 'Reel';
let icon;
if (process.platform === 'darwin') {
  const icons = resolve(root, '.cache/icons'), iconset = resolve(icons, 'Reel.iconset');
  await mkdir(iconset, { recursive: true });
  const png = resolve(input, 'web/brand/icon.png');
  for (const size of [16, 32, 128, 256, 512]) for (const multiplier of [1, 2]) {
    const result = spawnSync('/usr/bin/sips', ['-z', String(size * multiplier), String(size * multiplier), png, '--out', join(iconset, `icon_${size}x${size}${multiplier === 2 ? '@2x' : ''}.png`)], { stdio: 'ignore' });
    if (result.status !== 0) throw new Error('Icon conversion failed');
  }
  icon = resolve(icons, 'Reel.icns');
  if (spawnSync('/usr/bin/iconutil', ['-c', 'icns', iconset, '-o', icon], { stdio: 'inherit' }).status !== 0) throw new Error('macOS icon build failed');
  if (platform === 'win32') {
    const png256 = await readFile(join(iconset, 'icon_256x256.png'));
    const header = Buffer.alloc(22); header.writeUInt16LE(1, 2); header.writeUInt16LE(1, 4); header.writeUInt16LE(1, 10); header.writeUInt16LE(32, 12); header.writeUInt32LE(png256.length, 14); header.writeUInt32LE(22, 18);
    icon = resolve(icons, 'Reel.ico'); await writeFile(icon, Buffer.concat([header, png256]));
  } else if (platform === 'linux') icon = png;
}
const paths = await packager({ dir: input, out: resolve(root, '.cache/packages', flavor), platform, arch, electronVersion: checksums.version, electronZipDir: zipDir, name, executableName: 'Reel', appBundleId: qa ? 'app.reelclient.desktop.qa' : 'app.reelclient.desktop', appCategoryType: 'public.app-category.entertainment', appCopyright: 'Copyright 2026 Reel Client contributors', buildVersion: '1', appVersion: '0.1.0', asar: true, overwrite: true, prune: false, ...(icon ? { icon } : {}), osxSign: false, osxNotarize: false });
const output = paths[0], app = platform === 'darwin' ? join(output, name + '.app') : output;
const binary = platform === 'darwin' ? app : join(output, platform === 'win32' ? 'Reel.exe' : 'Reel');
await flipFuses(binary, { version: FuseVersion.V1, resetAdHocDarwinSignature: true, strictlyRequireAllFuses: true,
  [FuseV1Options.RunAsNode]: false, [FuseV1Options.EnableCookieEncryption]: false,
  [FuseV1Options.EnableNodeOptionsEnvironmentVariable]: false, [FuseV1Options.EnableNodeCliInspectArguments]: false,
  [FuseV1Options.EnableEmbeddedAsarIntegrityValidation]: platform !== 'linux', [FuseV1Options.OnlyLoadAppFromAsar]: true,
  [FuseV1Options.LoadBrowserProcessSpecificV8Snapshot]: false, [FuseV1Options.GrantFileProtocolExtraPrivileges]: false,
  [FuseV1Options.WasmTrapHandlers]: true
});
// A Developer ID signature with the hardened runtime, then Apple's notarization, let macOS open the download
// without a warning and let Squirrel.Mac install later releases, which it only accepts when signed by the same team.
let codeSigning = 'No Developer ID or Windows signature; local ad-hoc macOS runtime only';
if (sign) {
  for (const key of ['APPLE_API_KEY_PATH', 'APPLE_API_KEY_ID', 'APPLE_API_ISSUER']) if (!process.env[key]) throw new Error('Notarization needs ' + key);
  const { sign: signApp } = await import('@electron/osx-sign');
  const { notarize } = await import('@electron/notarize');
  const entitlements = resolve(root, 'signing/entitlements.mac.plist');
  await signApp({ app, platform: 'darwin', type: 'distribution', ...(process.env.REEL_MACOS_KEYCHAIN ? { keychain: process.env.REEL_MACOS_KEYCHAIN } : {}), optionsForFile: () => ({ hardenedRuntime: true, entitlements }) });
  await notarize({ appPath: app, appleApiKey: process.env.APPLE_API_KEY_PATH, appleApiKeyId: process.env.APPLE_API_KEY_ID, appleApiIssuer: process.env.APPLE_API_ISSUER });
  codeSigning = 'Developer ID signed with the hardened runtime, notarized and stapled';
}
const archive = platform === 'darwin' ? join(app, 'Contents/Resources/app.asar') : join(output, 'resources/app.asar');
const actual = {};
for (const member of listPackage(archive)) {
  const file = member.replace(/^[/\\]/, '').split('\\').join('/'), info = statFile(archive, file, false);
  if (info.files) continue;
  if (info.link || info.unpacked || !(file in expected)) throw new Error('Unexpected packaged payload: ' + file);
  actual[file] = createHash('sha256').update(extractFile(archive, file)).digest('hex');
}
if (!manifestsEqual(actual, expected)) throw new Error('Packaged app payload does not match stage');
const appAsarSha256 = createHash('sha256').update(await readFile(archive)).digest('hex');
const installedPackage = await packageManifest(output);
const receipt = { packageSha256: installedPackage.sha256, installedPackage: installedPackage.files, desktopRevision: source.desktopRevision, webRevision: source.webRevision, platform, arch, qa, appAsarSha256, runtimeSha256, payload: actual, fuses: await getCurrentFuseWire(binary), packageDirectory: relative(root, output), codeSigning, recordedAt: new Date().toISOString() };
try { await assertBuildCurrent(build, { stage }); } catch (error) { throw new Error('Source or stage changed during packaging', { cause: error }); }
if (!manifestsEqual(await payloadManifest(input), expected)) throw new Error('Source or stage changed during packaging');
await writeFile(resolve(root, `.cache/package-${flavor}-${target}.json`), JSON.stringify(receipt, null, 2) + '\n');
console.log(JSON.stringify(receipt, null, 2));
