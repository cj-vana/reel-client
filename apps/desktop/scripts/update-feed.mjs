// Writes the feed Squirrel.Mac reads to update a signed macOS build: the release's version and its ZIP, with the
// ZIP's SHA-256 and size so a download that does not match is discarded before it is unpacked.
//   node scripts/update-feed.mjs <version> <zip> <download url> <feed path>
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

export function updateFeed({ version, url, sha256, size, date }) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error('A release version is MAJOR.MINOR.PATCH');
  if (!/^https:\/\/github\.com\/[^/]+\/[^/]+\/releases\/download\/v\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?\/[^/]+\.zip$/.test(url)) throw new Error('The update must download from this release');
  if (!/^[a-f0-9]{64}$/.test(sha256) || !Number.isSafeInteger(size) || size <= 0) throw new Error('The update needs its digest and size');
  const update = { version, pub_date: date, notes: '', name: version, url, sha256, size };
  return { currentRelease: version, releases: [{ version, updateTo: update }] };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [version, zip, url, out] = process.argv.slice(2);
  const bytes = await readFile(zip);
  const feed = updateFeed({ version, url, sha256: createHash('sha256').update(bytes).digest('hex'), size: bytes.length, date: new Date().toISOString() });
  await writeFile(out, JSON.stringify(feed, null, 2) + '\n');
  console.log(`Wrote the update feed for ${version}`);
}
