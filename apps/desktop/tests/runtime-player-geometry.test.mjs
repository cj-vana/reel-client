import { test } from 'node:test';
import assert from 'node:assert/strict';
import { assertViewportPicture, assertFullscreenWindow } from '../scripts/runtime-player-geometry.mjs';

const frame = () => ({ fullscreen: 'player', viewport: { width: 1440, height: 900 }, screen: { width: 1440, height: 900 }, nativeWindow: { fullscreen: true, contentBounds: { width: 1440, height: 900 } },
  player: { x: 0, y: 0, width: 1440, height: 900 }, video: { x: 0, y: 0, width: 1440, height: 900, fit: 'contain', controls: true } });

test('geometry keeps native controls separate from the unchanged video rectangle', () => {
  const value = frame(); assertViewportPicture(value); assertFullscreenWindow(value);
  value.video.controls = false; assertViewportPicture(value); assertFullscreenWindow(value);
  value.screen.height = 933; assertFullscreenWindow(value);
});
test('video geometry rejects inline layout, cropped video, offsets and invalid dimensions', () => {
  for (const mutate of [value => { value.player.height = 800; }, value => { value.video.height = 800; },
    value => { value.video.x = 1; }, value => { value.video.fit = 'cover'; }, value => { value.viewport.width = 0; },
    value => { value.viewport.height = NaN; }, value => { value.video.width = Infinity; }]) {
    const value = frame(); mutate(value); assert.throws(() => assertViewportPicture(value));
  }
});
test('DOM fullscreen alone cannot qualify a still-windowed app or native-video-only fullscreen', () => {
  for (const mutate of [value => { value.fullscreen = 'video'; }, value => { value.fullscreen = null; },
    value => { value.screen.width = 1920; }, value => { value.nativeWindow.fullscreen = false; }, value => { value.nativeWindow = null; }, value => { value.nativeWindow.contentBounds.height = 1080; },
    value => { value.screen.width = NaN; }, value => { value.screen.height = 0; }]) {
    const value = frame(); mutate(value); assert.throws(() => assertFullscreenWindow(value));
  }
});
