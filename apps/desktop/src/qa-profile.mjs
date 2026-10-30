import { lstat,readFile,readdir,realpath } from 'node:fs/promises';
import { basename,dirname,join } from 'node:path';
import { validQAProfile } from './policy.mjs';
export async function assertQAProfile(profile, temporaryRoot, owner, { checkContents = true } = {}) {
  if (!validQAProfile(profile, temporaryRoot) || typeof owner !== 'string' || !/^[a-f0-9]{64}$/.test(owner)) throw new Error('Invalid private QA profile');
  const parent = await realpath(temporaryRoot), info = await lstat(profile);
  if (!info.isDirectory() || info.isSymbolicLink() || await realpath(dirname(profile)) !== parent || await realpath(profile) !== join(parent, basename(profile))) throw new Error('QA profile must be an owned temporary directory');
  if (process.getuid && info.uid !== process.getuid() || process.platform !== 'win32' && (info.mode & 0o077) !== 0) throw new Error('QA profile permissions are not private');
  const marker = join(profile, '.reel-qa-owner'), markerInfo = await lstat(marker);
  if (!markerInfo.isFile() || markerInfo.isSymbolicLink() || markerInfo.size !== 64 || await readFile(marker, 'utf8') !== owner) throw new Error('QA profile ownership marker missing');
  // A previous owned QA run may be relaunched, but not through nested profile links.
  async function noLinks(folder, isRoot = false) {
    for (const entry of await readdir(folder, { withFileTypes: true })) {
      // Chromium creates these root coordination links while taking its own instance lock.
      // They are never traversed as profile data; no nested directory link is accepted.
      if (isRoot && entry.isSymbolicLink() && ['SingletonLock', 'SingletonSocket', 'SingletonCookie'].includes(entry.name)) continue;
      if (entry.isSymbolicLink() || !entry.isDirectory() && !entry.isFile()) throw new Error('QA profile contains an unexpected link or special file');
      if (entry.isDirectory()) await noLinks(join(folder, entry.name));
    }
  }
  if (checkContents) await noLinks(profile, true);
}
