import { describePlayback, probeEngine, probeSourceHDR, type PlaybackDisclosure } from './media-capabilities.ts';
import type Hls from 'hls.js';
import { isWebOSPlatform } from './runtime.ts';
import type { RuntimePlatform } from './types.ts';
import { ApiError, JellyfinAPI } from './api.ts';
import { type MediaItem, type MediaSource, resumeSeconds } from './types.ts';

type ReportEvent = { sessionId: string; kind: 'start' | 'progress' | 'stop'; send: (signal?: AbortSignal) => Promise<void>; isAllowed?: () => boolean; cancelled?: boolean };

export class PlaybackReports {
  private queue: ReportEvent[] = [];
  private running?: Promise<boolean>;
  private retry?: ReturnType<typeof setTimeout>;
  private inFlight?: { event: ReportEvent; controller: AbortController };
  onFailure?: (message: string | null) => void;
  enqueue(event: ReportEvent): void {
    if (event.kind !== 'start') this.queue = this.queue.filter(pending => pending.sessionId !== event.sessionId || pending.kind === 'start');
    this.queue.push(event);
    void this.flush();
  }
  async flush(): Promise<boolean> {
    if (this.running) return this.running;
    const run = async (): Promise<boolean> => {
      while (this.queue.length) {
        const event = this.queue.shift()!;
        if (event.cancelled || event.isAllowed?.() === false) continue;
        const controller = new AbortController(); this.inFlight = { event, controller };
        try { await event.send(controller.signal); this.onFailure?.(null); }
        catch (error) {
          if (event.cancelled || controller.signal.aborted || event.isAllowed?.() === false) continue;
          if (error instanceof ApiError && (error.status === 401 || error.status === 403)) { this.onFailure?.('A previous sign-in expired. New playback reports can continue.'); continue; }
          const superseded = event.kind === 'progress' && this.queue.some(pending => pending.sessionId === event.sessionId && pending.kind !== 'start');
          if (!superseded) this.queue.unshift(event);
          this.onFailure?.('Watch progress is waiting for the server. Reel will retry while this app stays open.');
          if (!this.retry) this.retry = setTimeout(() => { this.retry = undefined; void this.flush(); }, 15000);
          return false;
        } finally { if (this.inFlight?.event === event) this.inFlight = undefined; }
      }
      if (this.retry) { clearTimeout(this.retry); this.retry = undefined; }
      return true;
    };
    this.running = run();
    try { return await this.running; } finally { this.running = undefined; }
  }
  get pendingCount(): number { return this.queue.length; }
  discard(): void {
    this.queue = [];
    if (this.inFlight) { this.inFlight.event.cancelled = true; this.inFlight.controller.abort(); }
    if (this.retry) { clearTimeout(this.retry); this.retry = undefined; }
    this.onFailure?.(null);
  }
  dispose(): void { this.discard(); }
}

interface ActivePlayback {
  api: JellyfinAPI; item: MediaItem; source: MediaSource; sessionId: string;
  method: string; generation: number; started: boolean; desiredStart: number; resourcesReleased: boolean; pausedIntent: boolean;
  scopedResumePending?: boolean; preloadPolicy?: { previous: HTMLVideoElement['preload']; applied: 'auto' };
  activationPolicy?: { muted: boolean; visibility: string };
}
export interface PlaybackOptions { bitrate: number; audio?: number; subtitle?: number; source?: string; start?: number; paused?: boolean }

export class ReelPlayer {
  readonly video: HTMLVideoElement;
  private readonly platform: string;
  private generation = 0;
  private preparation?: AbortController;
  private preparationTasks = new Map<Promise<void>, string>();
  private cleanupTasks = new Map<Promise<void>, string>();
  private cleanupFailures = 0;
  private drainTask?: Promise<{ resourcesComplete: boolean; cleanupSucceeded: boolean; reportsFlushed: boolean }>;
  private current?: ActivePlayback;
  private hls?: Hls;
  private removeEvents?: () => void;
  private fallback?: 'audio' | 'video';
  private options?: PlaybackOptions;
  private latestPosition = 0;
  private last?: { api: JellyfinAPI; item: MediaItem };
  private lastReport = 0;
  private seeking = false;
  readonly reports = new PlaybackReports();
  onState?: (state: 'preparing' | 'buffering' | 'playing' | 'paused' | 'ended' | 'error', message?: string) => void;
  onPosition?: (item: MediaItem, seconds: number, accountId: string) => void;
  onMethod?: (method: string) => void;
  onFormat?: (format: PlaybackDisclosure | null) => void;

  constructor(video: HTMLVideoElement, platform: RuntimePlatform = 'web') {
    this.video = video; this.platform = platform;
    video.playsInline = true;
    video.preload = 'metadata';
    video.setAttribute('webkit-playsinline', '');
    if (isWebOSPlatform(platform)) video.setAttribute('x-webos-video', 'true');
    else video.removeAttribute('x-webos-video');
    window.addEventListener('online', () => { void this.reports.flush(); });
  }

  // A download playing from this device: no server session, report or transcode cleanup is involved.
  private local?: { item: MediaItem; generation: number };
  /** Where a download stopped, so it resumes there next time. */
  onLocalPosition?: (item: MediaItem, seconds: number) => void;

  async openLocal(item: MediaItem, url: string, start: number): Promise<void> {
    this.close();
    this.last = undefined;
    const generation = ++this.generation, local = { item, generation };
    this.local = local; this.latestPosition = start; this.seeking = false;
    this.onFormat?.(null); this.onMethod?.('Offline'); this.onState?.('preparing');
    const active = () => this.local === local && this.generation === generation;
    let started = false, saved = 0;
    const save = () => { if (active() && Number.isFinite(this.video.currentTime)) { this.latestPosition = this.video.currentTime; this.onLocalPosition?.(item, this.latestPosition); } };
    const fail = () => { if (active()) { this.releaseCurrent(); this.onState?.('error', 'This download could not be played. Remove it and download it again.'); } };
    const listeners: Array<[string, EventListener]> = [
      ['loadedmetadata', () => { if (active() && start > 0.5 && Number.isFinite(this.video.duration)) this.video.currentTime = Math.min(start, Math.max(0, this.video.duration - 1)); }],
      ['canplay', () => { if (!active() || started) return; started = true; void this.video.play().catch(() => { if (active()) this.onState?.('paused', 'Press Play to start watching.'); }); }],
      ['playing', () => { if (active()) this.onState?.('playing'); }],
      ['pause', () => { if (active() && started && !this.video.ended) { save(); this.onState?.('paused'); } }],
      ['timeupdate', () => { if (active() && started && Date.now() - saved > 5000) { saved = Date.now(); save(); } }],
      ['seeked', save],
      ['ended', () => { if (active()) { this.latestPosition = 0; this.onLocalPosition?.(item, 0); this.onState?.('ended'); } }],
      ['error', fail],
      ['waiting', () => { if (active()) this.onState?.(started ? 'buffering' : 'preparing', 'Loading from this computer.'); }]
    ];
    listeners.forEach(([event, listener]) => this.video.addEventListener(event, listener));
    this.removeEvents = () => listeners.forEach(([event, listener]) => this.video.removeEventListener(event, listener));
    const { default: HlsConstructor } = await import('hls.js');
    if (!active()) return;
    this.hls = new HlsConstructor({ maxBufferLength: 30, backBufferLength: 30, enableWorker: true });
    this.hls.on(HlsConstructor.Events.ERROR, (_event, data) => { if (data.fatal) fail(); });
    this.hls.loadSource(url); this.hls.attachMedia(this.video);
  }

  async open(api: JellyfinAPI, item: MediaItem, options: PlaybackOptions): Promise<void> {
    this.close();
    this.last = { api, item };
    this.options = options; this.fallback = undefined;
    await this.prepare(api, item, options.start ?? resumeSeconds(item));
  }

  private prepare(api: JellyfinAPI, item: MediaItem, start: number): Promise<void> {
    const task = this.prepareStream(api, item, start);
    this.preparationTasks.set(task, api.account?.id ?? '');
    void task.then(() => this.preparationTasks.delete(task), () => this.preparationTasks.delete(task));
    return task;
  }

  private async prepareStream(api: JellyfinAPI, item: MediaItem, start: number): Promise<void> {
    this.releaseCurrent();
    const generation = ++this.generation;
    const controller = new AbortController(); this.preparation = controller;
    this.latestPosition = start; this.seeking = false;
    this.onFormat?.(null);
    this.onState?.('preparing');
    const options = this.options!;
    let pending: { sessionId: string; source?: MediaSource } | undefined;
    try {
      const itemSources = Array.isArray(item.MediaSources) ? item.MediaSources.filter(source => source && typeof source === 'object' && typeof source.Id === 'string' && source.Id.length > 0) : [];
      const requestedSource = itemSources.find(source => source.Id === options.source) ?? itemSources[0];
      const requestedStreams = Array.isArray(requestedSource?.MediaStreams) ? requestedSource.MediaStreams.filter(stream => stream && typeof stream === 'object') : [];
      const mediaCapabilities = typeof navigator !== 'undefined' ? navigator.mediaCapabilities : undefined;
      let capabilities = probeEngine(mime => this.video.canPlayType(mime));
      if (requestedStreams.some(stream => stream.Type === 'Video' && ['HDR10', 'HLG', 'HDR10Plus'].includes(stream.VideoRangeType ?? ''))) {
        capabilities = await probeSourceHDR(capabilities, requestedSource, controller.signal,
          mediaCapabilities?.decodingInfo ? configuration => mediaCapabilities.decodingInfo(configuration) : undefined);
        if (generation !== this.generation || controller.signal.aborted) return;
      }
      const info = await api.playback(item, { ...options, fallback: this.fallback, capabilities, signal: controller.signal });
      const sources = Array.isArray(info.MediaSources) ? info.MediaSources.filter(source => source && typeof source === 'object' && typeof source.Id === 'string' && source.Id.length > 0) : [];
      const matching = options.source === undefined ? sources : sources.filter(candidate => candidate.Id === options.source);
      const source = options.source !== undefined && matching.length !== 1 ? undefined : matching.find(candidate => candidate.SupportsDirectPlay || candidate.TranscodingUrl);
      const sessionId = info.PlaySessionId ?? `${api.deviceId}-${Date.now()}`;
      const requestedSourceID = options.source ?? itemSources[0]?.Id;
      pending = { sessionId, source: sources.find(candidate => candidate.Id === requestedSourceID) ?? source ?? (sources.length === 1 ? sources[0] : undefined) };
      if (!source || info.ErrorCode) throw new ApiError('Jellyfin could not prepare this title. Check server conversion settings, or choose another track.');
      if (generation !== this.generation || controller.signal.aborted) return;
      const stream = api.streamURL(item, source, sessionId);
      const hlsStream = stream.method === 'Transcode' && /m3u8(?:\?|$)/i.test(stream.url);
      const nativeHLS = hlsStream && Boolean(this.video.canPlayType('application/vnd.apple.mpegurl'));
      const positiveResume = this.platform === 'webos' && Number.isFinite(start) && start > 0;
      const audioItem = item.MediaType === 'Audio' || ['Audio', 'MusicAlbum', 'AudioBook'].includes(item.Type ?? '');
      const directResume = positiveResume && stream.method === 'DirectPlay' && source.Container?.trim().toLowerCase() === 'mp4' && !audioItem;
      const scopedResume = positiveResume && (nativeHLS || directResume);
      const current: ActivePlayback = { api, item, source, sessionId, method: stream.method, generation, started: false, desiredStart: start, resourcesReleased: false, pausedIntent: options.paused === true, scopedResumePending: scopedResume };
      this.current = current; pending = undefined; this.onMethod?.(stream.method);
      this.onFormat?.(describePlayback(source, stream.method, options.audio));
      const active = () => this.current === current && this.generation === generation;
      let nativeReady = false, initialSeekAttempted = false, admitting = false;
      let activationIssued = false, activationReady = false, resumeTimer: ReturnType<typeof setTimeout> | undefined;
      const failResume = (message: string) => {
        if (!active() || !current.scopedResumePending) return;
        this.releaseCurrent();
        this.onState?.('error', message);
      };
      const clearResumeTimer = () => { if (resumeTimer) { clearTimeout(resumeTimer); resumeTimer = undefined; } };
      const targetPosition = () => Number.isFinite(this.video.duration) ? Math.min(start, Math.max(0, this.video.duration - 0.25)) : start;
      const targetReady = () => active() && !current.resourcesReleased && !this.video.ended && nativeReady && this.video.readyState >= 3
        && (!directResume || activationReady && !this.video.paused)
        && !this.seeking && !this.video.seeking && Number.isFinite(this.video.currentTime) && this.video.currentTime > 0
        && Math.abs(this.video.currentTime - targetPosition()) <= 0.5;
      const loaded = () => {
        if (!active() || (nativeHLS || directResume) && (initialSeekAttempted || current.started)) return;
        if (directResume && !activationReady) return;
        if (nativeHLS || directResume) initialSeekAttempted = true;
        const duration = this.video.duration;
        const target = Number.isFinite(duration) ? Math.min(start, Math.max(0, duration - 0.25)) : start;
        const needsSeek = scopedResume
          ? target > 0 && (!Number.isFinite(this.video.currentTime) || this.video.currentTime <= 0 || Math.abs(this.video.currentTime - target) > 0.5)
          : target > 0.05 && Math.abs(this.video.currentTime - target) > 0.5;
        if (needsSeek) {
          this.seeking = true;
          try { this.video.currentTime = target; } catch {
            if (!nativeHLS && !directResume) this.seeking = false;
            else if (active()) {
              this.releaseCurrent();
              this.onState?.('error', 'The resume position could not be selected. Retry from your saved position, or choose Start over.');
            }
          }
        }
      };
      const metadata = () => { if (!nativeHLS && !directResume) loaded(); };
      const canPlay = () => {
        if (!active() || this.seeking || current.started || admitting) return;
        if (directResume) {
          if (!nativeReady || this.video.readyState < 3 || current.resourcesReleased) return;
          if (!activationIssued) {
            activationIssued = true;
            resumeTimer = setTimeout(() => failResume('The saved position could not be confirmed. Retry from your saved position, or choose Start over.'), 15000);
            // LG direct MP4 cannot finish an initial seek before its decoder runs.
            // The owned mute/visibility policy keeps this activation private until
            // the target is confirmed; no playback report is admitted at zero.
            if (!activationReady) void this.video.play().catch(() => failResume('Playback could not start at the saved position. Retry, or choose Start over.'));
          }
          if (!active() || !activationReady) return;
          loaded();
          if (!active() || this.seeking || this.video.seeking || current.started) return;
        }
        if (nativeHLS) {
          if (!nativeReady || this.video.seeking || current.resourcesReleased || scopedResume && this.video.readyState < 3) return;
          loaded();
          if (!active() || this.seeking || this.video.seeking || current.started) return;
        }
        const begin = () => {
          // LG must activate its decoder before a positive seek, even when the
          // requested result is paused. Pause while that activation is concealed.
          if (options.paused) {
            this.video.pause();
            if (!active()) return;
            this.restoreActivation(current);
            if (!active()) return;
          }
          current.started = true; current.scopedResumePending = false; clearResumeTimer();
          this.enqueue(current, 'start');
          if (options.paused) { if (active()) this.onState?.('paused'); }
          else if (directResume) { if (active()) this.onState?.('playing'); }
          else void this.video.play().catch(() => { if (active()) { current.pausedIntent = true; this.onState?.('paused', 'Press Play to start watching.'); } });
        };
        if (scopedResume) {
          if (!targetReady()) return;
          admitting = true;
          try {
            this.latestPosition = this.video.currentTime;
            this.onPosition?.(current.item, this.latestPosition, current.api.account?.id ?? '');
            if (!targetReady()) return;
            if (!options.paused) {
              this.restoreActivation(current);
              if (!targetReady()) return;
            }
            begin();
          } finally { admitting = false; }
        } else begin();
      };
      const ready = () => { nativeReady = true; canPlay(); };
      const seeked = () => { if (active() && (!(nativeHLS || directResume) || !this.video.seeking)) { const pending = current.scopedResumePending; this.seeking = false; canPlay(); if (!pending) this.capturePosition(current); } };
      const play = () => { if (active() && current.started && !current.scopedResumePending && !this.video.paused && !this.video.error) current.pausedIntent = false; };
      const playing = () => {
        if (!active()) return;
        if (directResume && current.scopedResumePending) { activationReady = true; canPlay(); return; }
        canPlay();
        if (!this.video.paused && !this.video.error && (!(nativeHLS || directResume) || current.started && !this.seeking && !this.video.seeking)) { current.pausedIntent = false; this.onState?.('playing'); }
      };
      const pause = () => { if (active() && current.started && this.video.paused && !this.video.ended && this.video.readyState !== 0 && !this.video.error) { current.pausedIntent = true; this.capturePosition(current); this.enqueue(current, 'progress'); this.onState?.('paused'); } };
      const progress = () => {
        if (active() && current.scopedResumePending) { canPlay(); return; }
        if (!active() || !current.started || this.seeking) return;
        this.capturePosition(current);
        if (Date.now() - this.lastReport >= 10000) this.enqueue(current, 'progress');
      };
      const ended = () => { if (active()) {
        if (scopedResume && current.resourcesReleased) return;
        if (current.scopedResumePending) { this.releaseCurrent(); this.onState?.('error', 'The saved position could not be confirmed. Retry from your saved position, or choose Start over.'); return; }
        this.capturePosition(current); this.enqueue(current, 'stop'); current.started = false; this.latestPosition = 0; this.onPosition?.(current.item, 0, current.api.account?.id ?? ''); this.onState?.('ended'); this.releaseResources(current); } };
      const failed = () => { if (active() && (!scopedResume || !current.resourcesReleased)) void this.recover(api, item); };
      const stalled = () => { if (active()) this.onState?.(current.started ? 'buffering' : 'preparing', 'Buffering. Your position is safe on this device.'); };
      const listeners: Array<[string, EventListener]> = [['loadedmetadata', metadata], ['canplay', ready], ['seeked', seeked], ['play', play], ['playing', playing], ['pause', pause], ['timeupdate', progress], ['ended', ended], ['error', failed], ['waiting', stalled]];
      listeners.forEach(([event, listener]) => this.video.addEventListener(event, listener));
      this.removeEvents = () => { clearResumeTimer(); listeners.forEach(([event, listener]) => this.video.removeEventListener(event, listener)); };
      if (hlsStream && !nativeHLS) {
        if (__REEL_NATIVE_HLS_ONLY__) throw new ApiError('Native HLS playback is unavailable on this TV. Try a compatible direct-play version.');
        else {
          const { default: HlsConstructor } = await import('hls.js');
          if (!active()) return;
          if (!HlsConstructor.isSupported()) throw new ApiError('This browser does not provide HLS playback. Try a current desktop browser or the native TV app.');
          this.hls = new HlsConstructor({ maxBufferLength: 30, backBufferLength: 30, enableWorker: true });
          this.hls.on(HlsConstructor.Events.ERROR, (_event, data) => { if (active() && data.fatal) failed(); });
          this.hls.loadSource(stream.url); this.hls.attachMedia(this.video);
        }
      } else {
        if (directResume) {
          current.activationPolicy = { muted: this.video.muted, visibility: this.video.style.visibility };
          this.video.muted = true;
          if (!active()) return;
          this.video.style.visibility = 'hidden';
          if (!active()) return;
        }
        if (scopedResume && nativeHLS) {
          current.preloadPolicy = { previous: this.video.preload, applied: 'auto' };
          this.video.preload = 'auto';
          if (!active()) return;
        }
        this.video.src = stream.url;
        if (!active()) return;
        this.video.load();
      }
    } catch (error) {
      if (generation !== this.generation || controller.signal.aborted) return;
      this.releaseCurrent();
      this.onState?.('error', error instanceof Error ? error.message : 'Playback could not start.');
    } finally {
      if (pending) this.cleanup(api, pending.sessionId, pending.source);
    }
  }

  private async recover(api: JellyfinAPI, item: MediaItem): Promise<void> {
    const current = this.current;
    if (current) {
      this.capturePosition(current);
      if (current.started && this.options) this.options = { ...this.options, paused: current.pausedIntent };
    }
    const position = this.latestPosition;
    if (!this.fallback) this.fallback = 'audio';
    else if (this.fallback === 'audio') this.fallback = 'video';
    else { this.releaseCurrent(); this.onState?.('error', 'This stream could not be played. Retry from your saved position, or choose a different audio or subtitle track.'); return; }
    await this.prepare(api, item, position);
  }

  retry(): void { if (this.last) void this.prepare(this.last.api, this.last.item, this.latestPosition); }
  seek(seconds: number): void {
    if (this.local && Number.isFinite(seconds)) {
      const total = this.video.duration;
      this.video.currentTime = this.latestPosition = Math.max(0, Math.min(Number.isFinite(total) ? total : Infinity, seconds));
      return;
    }
    const current = this.current;
    if (!current || current.scopedResumePending || !Number.isFinite(seconds)) return;
    const total = this.video.duration;
    const target = Math.max(0, Math.min(Number.isFinite(total) ? total : Infinity, seconds));
    this.video.currentTime = target;
    this.latestPosition = target;
    this.onPosition?.(current.item, target, current.api.account?.id ?? '');
  }
  skip(seconds: number): void { this.seek((Number.isFinite(this.video.currentTime) ? this.video.currentTime : this.latestPosition) + seconds); }
  toggle(): void {
    if (this.local) { if (this.video.paused) void this.video.play().catch(() => undefined); else this.video.pause(); return; }
    const current = this.current;
    if (!current || current.scopedResumePending) return;
    current.pausedIntent = !this.video.paused;
    if (this.video.paused) void this.video.play().catch(() => { if (this.current === current) { current.pausedIntent = true; this.onState?.('paused', 'Press the native Play control to start.'); } });
    else this.video.pause();
  }
  close(): void {
    ++this.generation; this.preparation?.abort(); this.preparation = undefined;
    this.releaseCurrent();
  }
  closeAndDrain(timeoutMs = 5000): Promise<{ resourcesComplete: boolean; cleanupSucceeded: boolean; reportsFlushed: boolean }> {
    if (this.drainTask) return this.drainTask;
    const failures = this.cleanupFailures;
    this.close();
    const deadline = Date.now() + Math.max(0, timeoutMs);
    const bounded = async <T>(task: Promise<T>): Promise<{ complete: true; value: T } | { complete: false }> => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      try { return await Promise.race([task.then(value => ({ complete: true as const, value })), new Promise<{ complete: false }>(resolve => { timer = setTimeout(() => resolve({ complete: false }), Math.max(0, deadline - Date.now())); })]); }
      finally { if (timer) clearTimeout(timer); }
    };
    const operation = (async () => {
      const released = await bounded(this.waitForResources());
      if (!released.complete) return { resourcesComplete: false, cleanupSucceeded: false, reportsFlushed: false };
      const reports = await bounded(this.reports.flush());
      return { resourcesComplete: true, cleanupSucceeded: this.cleanupFailures === failures, reportsFlushed: reports.complete && reports.value };
    })();
    this.drainTask = operation;
    void operation.then(() => { if (this.drainTask === operation) this.drainTask = undefined; }, () => { if (this.drainTask === operation) this.drainTask = undefined; });
    return operation;
  }
  async drainAccountResources(accountId: string, timeoutMs = 5000): Promise<boolean> {
    if (this.current?.api.account?.id === accountId) this.close();
    let timer: ReturnType<typeof setTimeout> | undefined;
    try { return await Promise.race([this.waitForResources(accountId).then(() => true), new Promise<boolean>(resolve => { timer = setTimeout(() => resolve(false), Math.max(0, timeoutMs)); })]); }
    finally { if (timer) clearTimeout(timer); }
  }
  private async waitForResources(accountId?: string): Promise<void> {
    // Preparation may create an owned cleanup after close. Recheck both maps until
    // every task for the requested account has settled, without stopping another account.
    while (true) {
      const tasks = [...this.preparationTasks, ...this.cleanupTasks].filter(([, owner]) => accountId === undefined || owner === accountId).map(([task]) => task);
      if (!tasks.length) return;
      await Promise.allSettled(tasks);
    }
  }
  private releaseResources(current: ActivePlayback): void {
    if (current.resourcesReleased) return;
    current.resourcesReleased = true;
    this.cleanup(current.api, current.sessionId, current.source);
  }
  private cleanup(api: JellyfinAPI, sessionId: string, source?: MediaSource): void {
    const task = api.cleanup(sessionId, source).catch(() => { this.cleanupFailures++; });
    this.cleanupTasks.set(task, api.account?.id ?? '');
    void task.then(() => this.cleanupTasks.delete(task));
  }
  private capturePosition(current: ActivePlayback): void {
    // A native load/error can reset paused and time to zero before its error
    // event. Keep the last usable position and user intent for recovery.
    if (this.seeking || !current.started || this.video.readyState === 0 || this.video.error) return;
    const seconds = this.video.currentTime;
    if (Number.isFinite(seconds)) { this.latestPosition = Math.max(0, seconds); this.onPosition?.(current.item, this.latestPosition, current.api.account?.id ?? ''); }
  }
  private enqueue(current: ActivePlayback, kind: ReportEvent['kind']): void {
    if (!current.api.recordsHistory) return;
    const seconds = this.latestPosition, paused = this.video.paused;
    const event = kind === 'start' ? '' : kind === 'stop' ? '/Stopped' : '/Progress';
    this.reports.enqueue({ sessionId: current.sessionId, kind, isAllowed: () => current.api.recordsHistory, send: signal => current.api.report(current.item, current.source, current.sessionId, current.method, event, seconds, paused, signal) });
    this.lastReport = Date.now();
  }
  private restoreActivation(current: ActivePlayback): void {
    const policy = current.activationPolicy;
    if (!policy) return;
    current.activationPolicy = undefined;
    const owner = this.current;
    if (owner && owner !== current) return;
    if (this.video.muted) this.video.muted = policy.muted;
    if (this.current !== owner) return;
    if (this.video.style.visibility === 'hidden') this.video.style.visibility = policy.visibility;
  }
  private releaseCurrent(): void {
    this.removeEvents?.(); this.removeEvents = undefined;
    const local = this.local;
    this.local = undefined;
    if (local && !this.video.ended && Number.isFinite(this.video.currentTime) && this.video.currentTime > 0) this.onLocalPosition?.(local.item, this.video.currentTime);
    const current = this.current;
    if (current) {
      this.capturePosition(current);
      if (current.started) this.enqueue(current, 'stop');
      this.releaseResources(current);
    }
    this.current = undefined;
    this.hls?.destroy(); this.hls = undefined;
    this.video.pause();
    if (current) this.restoreActivation(current);
    if (current?.preloadPolicy && this.video.preload === current.preloadPolicy.applied) this.video.preload = current.preloadPolicy.previous;
    this.video.removeAttribute('src'); this.video.load();
  }
}
