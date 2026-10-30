import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import { resolve, relative } from 'node:path';
import { projectRoot } from './source-revision.mjs';

const digest = data => createHash('sha256').update(data).digest('hex');
const canonical = entries => JSON.stringify(Object.entries(entries).sort(([a], [b]) => a.localeCompare(b)));
export async function verifyPayloadFiles(folder, expected) {
  const files = {};
  async function walk(path) {
    for (const entry of await readdir(path, { withFileTypes: true })) {
      const child = resolve(path, entry.name);
      if (entry.isDirectory()) await walk(child);
      else if (entry.isFile()) files[relative(folder, child).split('\\').join('/')] = digest(await readFile(child));
      else throw new Error('Unexpected link or special file in unpacked application');
    }
  }
  await walk(folder);
  if (canonical(files) !== canonical(expected)) throw new Error('Unpacked application differs from the inspected package');
  return files;
}
export async function packageProof(revision) {
  const inspection = JSON.parse(await readFile(resolve(projectRoot, '.cache/package-inspection.json'), 'utf8'));
  const stage = JSON.parse(await readFile(resolve(projectRoot, '.cache/webos-stage-manifest.json'), 'utf8'));
  if (inspection.source_revision !== revision || stage.source_revision !== revision || typeof stage.protected_preview !== 'boolean' || inspection.protected_preview !== stage.protected_preview || inspection.png_annotation_exif_metadata !== false || inspection.payload_matches_stage_manifest !== true || inspection.control_metadata_only !== true || inspection.generated_package_metadata_only !== true) throw new Error('Current inspected/staged package proof is missing');
  if (canonical(stage.files) !== canonical(inspection.payload_hashes)) throw new Error('Inspection does not match staged payload');
  const ipkSha256 = digest(await readFile(resolve(projectRoot, '.cache/packages/app.reelclient.tv_0.1.0_all.ipk')));
  if (inspection.ipk_sha256 !== ipkSha256) throw new Error('IPK changed after inspection');
  const payloadHashes = await verifyPayloadFiles(resolve(projectRoot, '.cache/package-unpacked'), inspection.payload_hashes);
  return { ipkSha256, protectedPreview: stage.protected_preview, payloadHashes: Object.fromEntries(Object.entries(payloadHashes).sort(([a], [b]) => a.localeCompare(b))), revision };
}
