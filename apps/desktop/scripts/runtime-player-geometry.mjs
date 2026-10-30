import assert from 'node:assert/strict';

export function assertViewportPicture(snapshot) {
  const { width, height } = snapshot.viewport;
  assert.ok(Number.isFinite(width) && width > 0 && Number.isFinite(height) && height > 0, 'Actual viewport must have finite positive dimensions');
  const expected = { x: 0, y: 0, width, height };
  assert.deepEqual(snapshot.player, expected, 'Player must cover the actual viewport');
  const { x, y, width: videoWidth, height: videoHeight, fit } = snapshot.video;
  assert.deepEqual({ x, y, width: videoWidth, height: videoHeight, fit }, { ...expected, fit: 'contain' }, 'Overlays must not shrink or crop the video');
}

export function assertFullscreenWindow(snapshot) {
  assertViewportPicture(snapshot);
  assert.equal(snapshot.fullscreen, 'player', 'Fullscreen must include the app player and its controls');
  assert.equal(snapshot.nativeWindow?.fullscreen, true, 'Native window must have completed its fullscreen transition');
  for (const dimension of ['width', 'height']) {
    assert.ok(Number.isFinite(snapshot.screen[dimension]) && snapshot.screen[dimension] > 0, 'Screen dimensions must be finite and positive');
    assert.ok(Math.abs(snapshot.viewport[dimension] - snapshot.nativeWindow.contentBounds[dimension]) <= 1, 'Player must fill the native fullscreen content area, including system display insets');
    assert.ok(snapshot.viewport[dimension] <= snapshot.screen[dimension] + 1, 'Content area cannot extend beyond the display');
  }
  assert.ok(Math.abs(snapshot.viewport.width - snapshot.screen.width) <= 1, 'Fullscreen must span the display width');
}
