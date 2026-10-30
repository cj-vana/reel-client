import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const root = path.resolve(import.meta.dirname, '..');
const scenePath = 'channel/components/ReelScene.brs';
const scene = readFileSync(path.join(root, scenePath), 'utf8');
// Run the shipped handlers verbatim. Only native nodes and external effects are
// replaced; this catches callback orderings that pure rule tests cannot cover.
const handlers = [
  'updatePlayerActions', 'onPlayerResult', 'showEpisodePanel', 'closeEpisodePanel',
  'showPlayerSeasons', 'showPlayerEpisodes', 'queueEpisode', 'requestEpisodeDetail',
  'startPendingEpisode', 'showNextEpisode', 'onNextEpisodeTimer', 'onVideoState',
  'closePlayer', 'stoppedPlayer', 'maybeShowNextEpisode', 'showEpisodeTransitionError', 'onPlayerAction',
  'restoreFocus', 'focusArea', 'claimFocus',
  'pushPage', 'backPage', 'retryPage', 'focusButtonAt', 'restoreReloadFocus',
];
const extracted = handlers.map(name => {
  const match = scene.match(new RegExp(`^sub ${name}\\([^\\n]*\\)[\\s\\S]*?^end sub`, 'm'));
  assert.ok(match, `Missing shipped Scene handler: ${name}`);
  return match[0];
}).join('\n\n');
const owned = mkdtempSync(path.join(tmpdir(), 'reel-roku-episode-scene-'));
const sources = [
  'channel/source/Core.brs', 'channel/source/Format.brs', 'channel/source/EpisodePlayback.brs', scenePath,
  'scripts/test-episode-scene.mjs', 'tests/EpisodeSceneTests.brs',
];
const pins = () => Object.fromEntries(sources.map(file => [file,
  createHash('sha256').update(readFileSync(path.join(root, file))).digest('hex'),
]));
const before = pins();
assert.equal(createHash('sha256').update(scene).digest('hex'), before[scenePath], 'Scene changed while extracting handlers; rerun the tests');
try {
  writeFileSync(path.join(owned, 'manifest'), 'title=Reel episode Scene contract\nmajor_version=0\nminor_version=1\nbuild_version=1\n');
  writeFileSync(path.join(owned, 'SceneHandlers.brs'), extracted);
  const run = spawnSync(path.join(root, 'node_modules/.bin/brs'), [
    '-r', owned, path.join(root, 'channel/source/Core.brs'),
    path.join(root, 'channel/source/Format.brs'),
    path.join(root, 'channel/source/EpisodePlayback.brs'),
    path.join(owned, 'SceneHandlers.brs'), path.join(root, 'tests/EpisodeSceneTests.brs'),
  ], { cwd: root, encoding: 'utf8', timeout: 15_000, maxBuffer: 1024 * 1024 });
  assert.equal(run.error, undefined);
  assert.equal(run.signal, null);
  assert.equal(run.status, 0, run.stderr || run.stdout);
  assert.equal(run.stderr, '', run.stderr);
  const marker = 'REEL_SCENE_RESULTS:';
  assert.ok(run.stdout.includes(marker), run.stdout);
  const checks = JSON.parse(run.stdout.slice(run.stdout.indexOf(marker) + marker.length).trim());
  assert.ok(checks.length >= 20, 'Expected bounded lifecycle and ownership checks');
  assert.deepEqual(pins(), before, 'Source changed during verification; rerun the tests');
  mkdirSync(path.join(root, 'evidence'), { recursive: true });
  writeFileSync(path.join(root, 'evidence/episode-scene-results.json'), JSON.stringify({
    kind: 'exact-BrightScript-Scene-handlers-with-fake-node-fields', sourcePins: before,
    passed: checks.filter(check => check.passed).length,
    failed: checks.filter(check => !check.passed).length, checks,
    nativeUI: false, nativeDecoder: false, nativeTimers: false,
    explanation: 'The shipped callback bodies execute under brs. Fake node fields, manually ordered callbacks, and recorded requests test lifecycle logic; they do not emulate SceneGraph focus, Video, native timer scheduling, or Roku OS.',
  }, null, 2) + '\n');
  for (const check of checks) assert.equal(check.passed, true, `${check.id}: expected ${JSON.stringify(check.expected)}, got ${JSON.stringify(check.actual)}`);
  console.log(`${checks.length} exact Scene handler checks passed; fake node fields, no native Roku UI/decoder proof.`);
} finally {
  rmSync(owned, { recursive: true, force: true });
}
