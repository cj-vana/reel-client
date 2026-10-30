import test from 'node:test';
import assert from 'node:assert/strict';
import { runtimeConfig, runtimeLayout, isWebOSPlatform, requestPlatformBack } from '../src/runtime.ts';
import { ReelPlayer } from '../src/player.ts';
import type { RuntimeConfig, RuntimePlatform } from '../src/types.ts';

for (const platform of ['web', 'webos', 'tizen', 'desktop'] as const) {
  test(platform + ' actual identity, layout and platform-specific activation remain separate', () => {
    const config = runtimeConfig({ platform }); assert.equal(config.platform, platform);
    assert.equal(runtimeLayout(config.platform), platform === 'webos' || platform === 'tizen' ? 'tv' : 'standard');
    assert.equal(isWebOSPlatform(config.platform), platform === 'webos');
    const calls: string[] = [];
    requestPlatformBack(config.platform, { PalmSystem: { platformBack: () => calls.push('webos') }, ReelTizen: { platformBack: () => calls.push('tizen') } });
    assert.deepEqual(calls, platform === 'webos' || platform === 'tizen' ? [platform] : []);
  });
}
test('unknown platform cannot acquire TV layout or native capabilities from PalmSystem presence', () => {
  const config = runtimeConfig({ platform: 'unknown' } as unknown as Partial<RuntimeConfig>);
  assert.equal(config.platform, 'web'); assert.equal(runtimeLayout(config.platform), 'standard'); assert.equal(isWebOSPlatform(config.platform), false);
  requestPlatformBack(config.platform, { PalmSystem: { platformBack() { assert.fail('Foreign PalmSystem activated'); } }, ReelTizen: { platformBack() { assert.fail('Foreign Tizen bridge activated'); } } });
  assert.equal(runtimeConfig().previewMode, true); assert.equal(runtimeConfig({ previewMode: false }).previewMode, false);
});
for (const platform of ['web', 'webos', 'tizen', 'desktop'] as RuntimePlatform[]) {
  test(platform + ' player owns only its actual platform video attribute', () => {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'window');
    const attrs = new Map([['x-webos-video', 'stale']]);
    const video = { playsInline: false, preload: '', setAttribute: (name: string, value: string) => attrs.set(name, value), removeAttribute: (name: string) => attrs.delete(name) };
    const fake = new EventTarget() as EventTarget & { PalmSystem: object }; fake.PalmSystem = {};
    Object.defineProperty(globalThis, 'window', { configurable: true, value: fake });
    try {
      new ReelPlayer(video as unknown as HTMLVideoElement, platform);
      assert.equal(attrs.get('x-webos-video'), platform === 'webos' ? 'true' : undefined);
      assert.equal(video.playsInline, true); assert.equal(video.preload, 'metadata'); assert.equal(attrs.has('webkit-playsinline'), true);
    } finally { if (descriptor) Object.defineProperty(globalThis, 'window', descriptor); else Reflect.deleteProperty(globalThis, 'window'); }
  });
}
