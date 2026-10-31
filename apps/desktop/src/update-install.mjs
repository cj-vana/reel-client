// Puts a verified release in place without a code-signing certificate. The ZIP is unpacked next to the installed
// copy, on the same volume, so the swap is two renames. A small helper script does the renames once Reel has quit:
// it moves the installed copy aside, moves the new one into its place, puts the old one back if either step fails,
// records the outcome for the next launch, and can start Reel again.
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { lstat, mkdir, readdir, readFile, rm } from 'node:fs/promises';
import { join, relative } from 'node:path';
import { extractZip, UpdateError } from './update-package.mjs';

export const RESULT_FILE = 'update-result.json';
const STAGING_PREFIX = '.reel-update-';

/** Runs a tool and resolves with its standard output, or throws an UpdateError('package'). */
export function runTool(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'ignore'] });
    let output = '';
    child.stdout.on('data', chunk => { output += chunk; });
    child.on('error', error => reject(new UpdateError('package', error)));
    child.on('close', code => code === 0 ? resolve(output) : reject(new UpdateError('package')));
  });
}

/**
 * Unpacks the release next to the installed copy and checks it. Returns the staging folder and the new copy in it.
 * macOS: ditto keeps the bundle's links and attributes, --noqtn keeps quarantine off the new copy, and the bundle's
 * own signature must verify. Windows and Linux: Reel's own ZIP reader, which refuses any entry outside the package.
 */
export async function stageRelease({ platform, zip, location, version, run = runTool }) {
  const staging = join(location.parent, `${STAGING_PREFIX}${version}-${randomUUID().slice(0, 8)}`);
  try {
    if (platform === 'darwin') {
      await mkdir(staging, { mode: 0o755 });
      await run('/usr/bin/ditto', ['-x', '-k', '--noqtn', zip, staging]);
      const app = join(staging, location.top);
      // A quarantined copy would meet Gatekeeper again on its first launch, so it is not used.
      if ((await run('/usr/bin/find', [app, '-xattrname', 'com.apple.quarantine', '-print'])).trim()) throw new UpdateError('package');
      await run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
    } else {
      await extractZip(zip, staging, location.top);
    }
    const staged = join(staging, location.top);
    if (!(await lstat(staged)).isDirectory()) throw new UpdateError('package');
    return { staging, staged };
  } catch (error) {
    await rm(staging, { recursive: true, force: true });
    throw error instanceof UpdateError ? error : new UpdateError('package', error);
  }
}

/** Removes staging folders that an interrupted update left beside the installed copy. */
export async function removeLeftovers(parent) {
  let entries;
  try { entries = await readdir(parent, { withFileTypes: true }); } catch { return; }
  for (const entry of entries) {
    if (entry.isDirectory() && !entry.isSymbolicLink() && entry.name.startsWith(STAGING_PREFIX)) await rm(join(parent, entry.name), { recursive: true, force: true }).catch(() => undefined);
  }
}

/** Reads and clears the outcome the helper recorded. Null when no update ran. */
export async function takeResult(userData) {
  const file = join(userData, RESULT_FILE);
  try {
    const text = await readFile(file, 'utf8');
    await rm(file, { force: true });
    const result = JSON.parse(text.charCodeAt(0) === 0xfeff ? text.slice(1) : text);
    return result && typeof result.ok === 'boolean' && typeof result.version === 'string' ? { ok: result.ok, version: result.version } : null;
  } catch { return null; }
}

const shell = value => "'" + String(value).split("'").join("'\\''") + "'";
const powershell = value => "'" + String(value).split("'").join("''") + "'";

/**
 * The helper script for this platform. `executable` is the path of Reel's executable inside the new copy, relative
 * to its top folder; `args` are passed when Reel starts again (none for a normal build). On macOS, `open` starts
 * Reel with the login session's environment, so `env` names the variables to carry over (QA builds only); the
 * Windows and Linux helpers start Reel with their own environment, which is Reel's.
 */
export function helperScript({ platform, pid, folder, staging, staged, version, resultFile, relaunch, executable, args = [], env = {} }) {
  for (const name of Object.keys(env)) if (!/^[A-Z_][A-Z0-9_]*$/.test(name)) throw new Error('Unexpected environment variable name');
  const ok = JSON.stringify({ version, ok: true }), failed = JSON.stringify({ version, ok: false });
  if (platform === 'win32') {
    const start = relaunch ? `  Start-Process -FilePath (Join-Path $app ${powershell(executable)})${args.length ? ' -ArgumentList ' + args.map(powershell).join(',') : ''}` : '';
    return [
      '# Written by Reel to finish an update once it has quit.',
      `$app = ${powershell(folder)}; $staged = ${powershell(staged)}; $staging = ${powershell(staging)}; $result = ${powershell(resultFile)}`,
      '$previous = Join-Path $staging \'previous\'',
      `try { Wait-Process -Id ${Number(pid)} -Timeout 120 -ErrorAction Stop } catch { <# Reel has already exited. #> }`,
      '$ok = $false',
      // Child processes, an antivirus scan or an Explorer window can hold the folder for a moment after Reel quits.
      'for ($attempt = 0; $attempt -lt 60 -and -not $ok; $attempt++) {',
      '  if (-not (Test-Path -LiteralPath $staged)) { break }',
      '  try {',
      '    Move-Item -LiteralPath $app -Destination $previous -ErrorAction Stop',
      '    try { Move-Item -LiteralPath $staged -Destination $app -ErrorAction Stop; $ok = $true }',
      '    catch { Move-Item -LiteralPath $previous -Destination $app -ErrorAction SilentlyContinue }',
      '  } catch { <# The folder is still in use: try again. #> }',
      '  if (-not $ok) { Start-Sleep -Seconds 1 }',
      '}',
      // WriteAllText writes UTF-8 without the byte order mark that Set-Content adds in Windows PowerShell.
      `if ($ok) { [System.IO.File]::WriteAllText($result, ${powershell(ok)}) } else { [System.IO.File]::WriteAllText($result, ${powershell(failed)}) }`,
      ...(relaunch ? ['if (Test-Path -LiteralPath $app) {', start, '}'] : []),
      'Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue',
      ''
    ].join('\r\n');
  }
  const start = platform === 'darwin'
    ? `/usr/bin/open -n${Object.entries(env).map(([name, value]) => ' --env ' + shell(name + '=' + value)).join('')} "$app"${args.length ? ' --args ' + args.map(shell).join(' ') : ''}`
    : `nohup "$app"/${shell(executable)}${args.length ? ' ' + args.map(shell).join(' ') : ''} > /dev/null 2>&1 &`;
  return [
    '#!/bin/sh',
    '# Written by Reel to finish an update once it has quit.',
    `app=${shell(folder)}; staged=${shell(staged)}; staging=${shell(staging)}; result=${shell(resultFile)}`,
    `waited=0; while kill -0 ${Number(pid)} 2> /dev/null && [ "$waited" -lt 600 ]; do sleep 0.2; waited=$((waited + 1)); done`,
    'ok=0',
    'if mv "$app" "$staging/previous"; then',
    '  if mv "$staged" "$app"; then ok=1; else mv "$staging/previous" "$app"; fi',
    'fi',
    `if [ "$ok" = 1 ]; then printf '%s' ${shell(ok)} > "$result"; else printf '%s' ${shell(failed)} > "$result"; fi`,
    ...(relaunch ? [`[ -d "$app" ] && ${start}`] : []),
    'rm -rf "$staging"',
    ''
  ].join('\n');
}

/**
 * Writes the helper into the staging folder and starts it, detached, so it outlives Reel. Synchronous, because it
 * runs while Reel quits, when nothing can wait for a promise.
 */
export function startHelper({ platform, staging, script, launch = spawn }) {
  const file = join(staging, platform === 'win32' ? 'finish-update.ps1' : 'finish-update.sh');
  writeFileSync(file, script, { mode: 0o700 });
  const [command, args] = platform === 'win32'
    ? ['powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', file]]
    : ['/bin/sh', [file]];
  const child = launch(command, args, { detached: true, stdio: 'ignore', windowsHide: true });
  child.unref?.();
}

/** The path of Reel's executable inside its top folder, from the running executable and the installed copy. */
export function executableInside(execPath, folder) {
  return relative(folder, execPath).split('\\').join('/');
}
