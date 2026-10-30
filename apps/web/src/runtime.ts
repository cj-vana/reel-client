import type { RuntimeConfig, RuntimePlatform } from './types.ts';

export function runtimeConfig(value: Partial<RuntimeConfig> = {}): RuntimeConfig {
  const platform = ['web', 'webos', 'tizen', 'desktop'].includes(value.platform ?? '') ? value.platform! : 'web';
  return { platform, previewMode: value.previewMode !== false, appName: typeof value.appName === 'string' ? value.appName : 'Reel' };
}

export function runtimeLayout(platform: RuntimePlatform): 'tv' | 'standard' {
  return platform === 'webos' || platform === 'tizen' ? 'tv' : 'standard';
}

export function isWebOSPlatform(platform: RuntimePlatform): boolean { return platform === 'webos'; }

export function requestPlatformBack(platform: RuntimePlatform, host: Pick<Window, 'PalmSystem' | 'ReelTizen'>): void {
  if (platform === 'webos') host.PalmSystem?.platformBack?.();
  else if (platform === 'tizen') host.ReelTizen?.platformBack?.();
}
