import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { installFullscreenSync } from '../src/fullscreen-sync.mjs';

function fixture(options = {}) {
  const window = new EventEmitter(), contents = new EventEmitter(), tasks = [], changes = [];
  let bounds = { x: 30, y: 40, width: 1440, height: 940 };
  Object.assign(contents, { isDestroyed: () => false, getURL: () => 'reel://app/index.html', mainFrame: { url: 'reel://app/index.html' } });
  Object.assign(window, { webContents: contents, isDestroyed: () => false, isFullScreen: () => false,
    getBounds: () => ({ ...bounds }), getMinimumSize: () => [320, 560], getMaximumSize: () => [0, 0],
    setBounds: (next, animate) => { changes.push({ ...next, animate }); bounds = { ...next }; } });
  const dispose = installFullscreenSync(window, { platform: 'darwin', schedule: task => tasks.push(task), ...options });
  const exit = () => { window.emit('enter-html-full-screen'); window.emit('leave-full-screen'); };
  const flush = () => { while (tasks.length) tasks.shift()(); };
  return { window, contents, changes, tasks, dispose, exit, flush };
}

test('HTML fullscreen departure resynchronizes once and restores exact native bounds without animation', () => {
  const f = fixture(); f.exit(); f.flush();
  assert.deepEqual(f.changes, [{ x: 30, y: 40, width: 1441, height: 940, animate: false }, { x: 30, y: 40, width: 1440, height: 940, animate: false }]);
  f.window.emit('leave-full-screen'); f.flush(); assert.equal(f.changes.length, 2);
});
test('native-only fullscreen and non-macOS windows do not resize', () => {
  const native = fixture(); native.window.emit('leave-full-screen'); native.flush(); assert.deepEqual(native.changes, []);
  const linux = fixture({ platform: 'linux' }); linux.exit(); linux.flush(); assert.deepEqual(linux.changes, []);
});
test('stale, closing, foreign and newly fullscreen windows cannot be resized by an earlier departure', () => {
  for (const change of [f => f.window.emit('enter-html-full-screen'), f => f.contents.emit('did-start-navigation'), f => f.window.emit('closed'), f => { f.window.isDestroyed = () => true; }, f => { f.contents.isDestroyed = () => true; }, f => { f.contents.getURL = () => 'https://example.invalid/'; }, f => { f.contents.mainFrame.url = 'reel://app/other.html'; }, f => { f.window.isFullScreen = () => true; }]) {
    const f = fixture(); f.exit(); change(f); f.flush(); assert.deepEqual(f.changes, []);
  }
});
test('resynchronization respects size limits and restores bounds even when the nudge throws', () => {
  const limited = fixture(); limited.window.getMaximumSize = () => [1440, 940]; limited.exit(); limited.flush(); assert.equal(limited.changes[0].width, 1439); assert.equal(limited.changes[1].width, 1440);
  const fixed = fixture(); fixed.window.getMaximumSize = fixed.window.getMinimumSize = () => [1440, 940]; fixed.exit(); fixed.flush(); assert.deepEqual(fixed.changes, []);
  const throwing = fixture(), original = throwing.window.setBounds; let count = 0;
  throwing.window.setBounds = (...args) => { original(...args); if (++count === 1) throw Error('native transition'); };
  throwing.exit(); throwing.flush(); assert.equal(throwing.window.getBounds().width, 1440); assert.equal(count, 2);
});
