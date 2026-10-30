import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { projectRoot } from './source-revision.mjs';
const read = path => readFile(resolve(projectRoot, path), 'utf8');
const notice = await read('public/THIRD_PARTY_NOTICES.txt');
const dependency = JSON.parse(await read('node_modules/hls.js/package.json'));
assert.equal(dependency.version, '1.7.3');
assert.deepEqual(dependency.dependencies ?? {}, {});
assert.ok(notice.includes((await read('node_modules/hls.js/LICENSE')).trim()));
for (const file of ['utf8-utils.ts', 'vttcue.ts', 'cea-608-parser.ts']) {
  const text = await read('node_modules/hls.js/src/utils/' + file);
  const comment = Array.from(text.matchAll(/\/\*[\s\S]*?\*\//g)).map(match => match[0]).find(comment => comment.includes('Copyright'));
  assert.ok(comment && notice.includes(comment), 'Missing embedded attribution: ' + file);
}
assert.ok(notice.includes((await read('node_modules/typescript/LICENSE')).replaceAll('\r\n', '\n').trim()));
const viteCore = (await read('node_modules/vite/LICENSE.md')).split('# Licenses of bundled dependencies')[0].trim();
assert.ok(notice.includes(viteCore));
assert.equal(await read('dist/THIRD_PARTY_NOTICES.txt'), notice);
await mkdir(resolve(projectRoot, '.cache'), { recursive: true });
await writeFile(resolve(projectRoot, '.cache/notices-verification.json'), JSON.stringify({ hlsVersion: dependency.version, webDistributionMatches: true, sha256: createHash('sha256').update(notice).digest('hex'), embeddedNotices: ['Dailymotion', 'Brightcove', 'DASH Industry Forum', 'vtt.js Contributors', 'Masanao Izumo'], apache2FullTerms: true, viteGeneratedHelperLicense: true }, null, 2) + '\n');
console.log('Runtime notices match upstream license/embedded attributions and built web distribution.');
