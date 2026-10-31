// Creates the key that signs desktop update manifests. Run it once, from anywhere in the repository:
//   node apps/desktop/scripts/update-signing-key.mjs [--backup <file>] [--replace]
// The private key goes straight to the repository secret DESKTOP_UPDATE_KEY through the GitHub CLI and is never
// printed. The public key is written to src/update-key.mjs, which must then be committed. --backup also saves the
// private key to a new file only you can read; keep it somewhere safe, because a lost key cannot be recovered.
import { generateKeyPairSync } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { REPOSITORY } from '../src/update-package.mjs';

const root = resolve(import.meta.dirname, '..'), keyFile = resolve(root, 'src/update-key.mjs');
const backupAt = process.argv.indexOf('--backup'), backup = backupAt > 0 ? process.argv[backupAt + 1] : undefined;
if (backupAt > 0 && !backup) throw new Error('--backup needs a file name');

if (!/UPDATE_PUBLIC_KEY = null;/.test(await readFile(keyFile, 'utf8')) && !process.argv.includes('--replace')) {
  console.error('An update key is already set. Replacing it stops every installed copy from updating itself; pass --replace if that is what you want.');
  process.exit(1);
}
const { publicKey, privateKey } = generateKeyPairSync('ed25519');
const secret = privateKey.export({ type: 'pkcs8', format: 'der' }).toString('base64');
const result = spawnSync('gh', ['secret', 'set', 'DESKTOP_UPDATE_KEY', '--repo', REPOSITORY], { input: secret, stdio: ['pipe', 'inherit', 'inherit'] });
if (result.status !== 0) { console.error('The GitHub CLI could not set the secret. Nothing was changed.'); process.exit(1); }
if (backup) await writeFile(resolve(backup), privateKey.export({ type: 'pkcs8', format: 'pem' }), { flag: 'wx', mode: 0o600 });
const text = (await readFile(keyFile, 'utf8')).replace(/UPDATE_PUBLIC_KEY = (null|'[A-Za-z0-9+/=]+');/, `UPDATE_PUBLIC_KEY = '${publicKey.export({ type: 'spki', format: 'der' }).toString('base64')}';`);
await writeFile(keyFile, text);
console.log('Set DESKTOP_UPDATE_KEY on ' + REPOSITORY + ' and wrote the public key to apps/desktop/src/update-key.mjs. Commit that file.');
