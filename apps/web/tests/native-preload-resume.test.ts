import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { setImmediate as settle } from 'node:timers/promises';
import { JellyfinAPI } from '../src/api.ts';
import { ReelPlayer } from '../src/player.ts';
import type { Account, MediaItem, PlaybackInfo } from '../src/types.ts';

class NativeVideo extends EventTarget {
  playsInline = false; private preloadValue = ''; paused = true;
  readyState=0; mutations: string[]=[]; onPreload?: (value:string)=>void; onSrc?:()=>void; failNextLoad=false;
  get preload():string {return this.preloadValue;}
  set preload(value:string){this.preloadValue=value;this.mutations.push('preload:'+value);this.onPreload?.(value);}
   ended = false; duration = 7808.852; seeking = false;
  private sourceValue='';
  get src():string{return this.sourceValue;}
  set src(value:string){this.sourceValue=value;this.mutations.push('src:'+Boolean(value));if(value)this.onSrc?.();}
  value = 0; playCalls = 0; writes: number[] = []; events: string[] = [];
  seekMode: 'pending' | 'settled' | 'throw' = 'pending'; rejectPlay = false;
  onSeek?: () => void;
  handlers = new Map<string, Set<EventListenerOrEventListenerObject>>();
  get currentTime(): number { return this.value; }
  set currentTime(value: number) {
    if (this.seekMode === 'throw') throw new Error('Synthetic setter rejection');
    this.value = value; this.writes.push(value); this.seeking = true; this.events.push('assign');
    this.onSeek?.();
    if (this.seekMode === 'settled') { this.seeking = false; this.emit('seeked'); }
  }
  override addEventListener(type: string, listener: EventListenerOrEventListenerObject | null, options?: AddEventListenerOptions | boolean): void {
    super.addEventListener(type, listener, options);
    if (listener) { const set = this.handlers.get(type) ?? new Set(); set.add(listener); this.handlers.set(type, set); }
  }
  override removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null, options?: EventListenerOptions | boolean): void {
    super.removeEventListener(type, listener, options); if (listener) this.handlers.get(type)?.delete(listener);
  }
  snapshot(): Map<string, EventListenerOrEventListenerObject[]> { return new Map([...this.handlers].map(([key, listeners]) => [key, [...listeners]])); }
  stale(snapshot: Map<string, EventListenerOrEventListenerObject[]>, names: string[]): void {
    for (const name of names) for (const listener of snapshot.get(name) ?? []) {
      if (typeof listener === 'function') listener.call(this, new Event(name)); else listener.handleEvent(new Event(name));
    }
  }
  setAttribute(): void {}
  removeAttribute(name: string): void { if (name === 'src') this.sourceValue = ''; }
  pause(): void { this.paused = true; }
  play(): Promise<void> {
    this.playCalls++;
    if (this.rejectPlay) return Promise.reject(new Error('Synthetic autoplay denied'));
    this.paused = false; this.emit('play'); this.emit('playing'); return Promise.resolve();
  }
  load(): void { this.mutations.push('load:'+this.preload+':'+Boolean(this.src));if(this.failNextLoad){this.failNextLoad=false;throw new Error('Synthetic load rejected');} if (!this.src) { this.value = 0; this.seeking = false; this.ended = false; } }
  canPlayType(): string { return 'probably'; }
  emit(name: string): void { this.events.push(name); this.dispatchEvent(new Event(name)); }
  settleSeek(): void { this.seeking = false; this.emit('seeked'); }
}
const item: MediaItem = { Id: 'synthetic-title', Name: 'Synthetic title', UserData: { PlaybackPositionTicks: 13_990_000 } };
type Call = { path: string; query: Record<string, string>; method: string; body?: Record<string, unknown>; auth: string };
function connection(id = 'owned', history = false, remote = false): JellyfinAPI {
  const server = remote ? 'https://media.example/jellyfin' : 'http://127.0.0.1:18771/jellyfin';
  const account: Account = { id, server, token: 'fixture-' + id, userId: id, name: id, serverName: 'Synthetic', remember: false };
  return new JellyfinAPI(account, server, 'device-' + id, true, history);
}
function hlsInfo(session: string): PlaybackInfo {
  return { PlaySessionId: session, MediaSources: [{ Id: 'source-' + session, Container: 'mkv', SupportsDirectPlay: false, TranscodingUrl: '/jellyfin/Videos/synthetic-title/master.m3u8', LiveStreamId: 'live-' + session }] };
}
function harness(t: TestContext, settings: { history?: boolean; direct?: boolean; remote?: boolean; platform?:string } = {}) {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'window');
  Object.defineProperty(globalThis, 'window', { configurable: true, value: new EventTarget() });
  t.after(() => { if (descriptor) Object.defineProperty(globalThis, 'window', descriptor); else Reflect.deleteProperty(globalThis, 'window'); });
  const calls: Call[] = [], preparations: Array<{ session: string; fallback?: string }> = [];
  t.mock.method(globalThis, 'fetch', async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    assert.ok(['http://127.0.0.1:18771', 'https://media.example'].includes(url.origin));
    calls.push({ path: url.pathname, query: Object.fromEntries(url.searchParams), method: init?.method ?? 'GET', body: init?.body ? JSON.parse(String(init.body)) : undefined, auth: new Headers(init?.headers).get('Authorization') ?? '' });
    return new Response(null, { status: 204 });
  });
  const api = connection('owned', settings.history, settings.remote); let sequence = 0;
  t.mock.method(api, 'playback', async (_item: MediaItem, options: { fallback?: string }) => {
    const session = 'session-' + ++sequence; preparations.push({ session, fallback: options.fallback });
    const info = hlsInfo(session); if (settings.direct) info.MediaSources[0].SupportsDirectPlay = true; return info;
  });
  const video = new NativeVideo(), player = new ReelPlayer(video as unknown as HTMLVideoElement,settings.platform??'webos'), states: string[] = [], positions: number[] = [];
  player.onState = state => states.push(state); player.onPosition = (_item, seconds) => positions.push(seconds);
  t.after(async () => { await player.closeAndDrain(); player.reports.dispose(); });
  return { api, video, player, states, calls, preparations, positions };
}
async function open(h: ReturnType<typeof harness>, start = 31.794): Promise<void> { await h.player.open(h.api, item, { bitrate: 120_000_000, start }); }
function starts(h: ReturnType<typeof harness>): Call[] { return h.calls.filter(call => call.path.endsWith('/Sessions/Playing')); }
async function closed(h: ReturnType<typeof harness>, sessions = ['session-1']): Promise<void> {
  assert.equal((await h.player.closeAndDrain()).resourcesComplete, true); await settle();
  const encoders = h.calls.filter(call => call.path.endsWith('/Videos/ActiveEncodings'));
  assert.deepEqual(encoders.map(call => call.query.playSessionId).sort(), [...sessions].sort());
  assert.equal(new Set(encoders.map(call => call.query.playSessionId)).size, sessions.length);
  assert.deepEqual(h.calls.filter(call => call.path.endsWith('/LiveStreams/Close')).map(call => call.query.liveStreamId).sort(), sessions.map(value => 'live-' + value).sort());
  assert.equal(h.calls.filter(call => /^\/jellyfin\/User(?:Played|Favorite)Items/.test(call.path)).length, 0);
  if (!h.api.recordsHistory) assert.equal(h.calls.filter(call => call.path.includes('/Sessions/Playing')).length, 0);
  h.player.close(); await settle(); assert.equal(h.calls.filter(call => call.path.endsWith('/Videos/ActiveEncodings')).length, sessions.length);
}


function ready(h:ReturnType<typeof harness>){h.video.readyState=4;h.video.emit('canplay');}
function settled(h:ReturnType<typeof harness>,clock=31.794){h.video.value=clock;h.video.seeking=false;h.video.emit('seeked');}

test('owned webOS positive native HLS sets auto before src/load and restores exact prior policy',async t=>{
 const h=harness(t);h.video.preload='none';await open(h);
 const auto=h.video.mutations.indexOf('preload:auto'),src=h.video.mutations.indexOf('src:true'),load=h.video.mutations.indexOf('load:auto:true');
 assert.ok(auto>=0&&src>auto&&load>src);assert.equal(h.video.preload,'auto');assert.equal(h.video.playCalls,0);
 ready(h);assert.deepEqual(h.video.writes,[31.794]);settled(h);assert.equal(h.video.playCalls,1);await closed(h);assert.equal(h.video.preload,'none');
});
for(const [label,clock]of [['zero',0],['wrong',8],['unknown',NaN]]as const)test('real settled seeked at '+label+' clock does not admit or publish',async t=>{
 const h=harness(t,{history:true});await open(h);ready(h);settled(h,clock);
 for(const name of ['canplay','playing','timeupdate','loadedmetadata','seeked'])h.video.emit(name);
 h.player.seek(4);h.player.skip(15);h.player.toggle();await h.player.reports.flush();
 assert.equal(h.video.playCalls,0);assert.deepEqual(h.positions,[]);assert.equal(starts(h).length,0);assert.deepEqual(h.video.writes,[31.794]);await closed(h);assert.equal(h.video.preload,'metadata');
});
test('actual correct clock after a rejected seeked may admit without repeating the seek',async t=>{
 const h=harness(t,{history:true});await open(h);ready(h);settled(h,0);h.video.value=31.794;h.video.emit('timeupdate');await h.player.reports.flush();
 assert.equal(h.video.playCalls,1);assert.deepEqual(h.video.writes,[31.794]);assert.equal(starts(h).length,1);assert.equal(starts(h)[0].body?.PositionTicks,317940000);await closed(h);
});
test('matching target still needs actual readyState at least3 and native seeking false',async t=>{
 const h=harness(t);await open(h);ready(h);h.video.readyState=2;settled(h);assert.equal(h.video.playCalls,0);h.video.readyState=3;h.video.seeking=true;h.video.emit('seeked');assert.equal(h.video.playCalls,0);settled(h);assert.equal(h.video.playCalls,1);await closed(h);
});
test('duration clamp and finite positive clock are required before start',async t=>{
 const h=harness(t,{history:true});h.video.duration=14;await open(h);ready(h);assert.deepEqual(h.video.writes,[13.75]);settled(h,13.75);await h.player.reports.flush();assert.equal(h.video.playCalls,1);assert.equal(starts(h)[0].body?.PositionTicks,137500000);await closed(h);
});
test('tiny positive target never admits an actual zero clock despite half-second tolerance',async t=>{
 const h=harness(t);await open(h,.1);ready(h);assert.deepEqual(h.video.writes,[.1]);settled(h,0);assert.equal(h.video.playCalls,0);assert.deepEqual(h.positions,[]);settled(h,.1);assert.equal(h.video.playCalls,1);await closed(h);
});
test('duplicate readiness cannot rewind a started owner',async t=>{
 const h=harness(t,{history:true});await open(h);ready(h);settled(h);h.video.value=45;for(const n of ['canplay','loadedmetadata','seeked','playing','timeupdate'])h.video.emit(n);await h.player.reports.flush();assert.equal(h.video.playCalls,1);assert.equal(starts(h).length,1);assert.deepEqual(h.video.writes,[31.794]);assert.equal(h.video.currentTime,45);await closed(h);
});
test('onPosition reentrant Close cannot enqueue start or play an invalid owner',async t=>{
 const h=harness(t,{history:true});await open(h);ready(h);let calls=0;h.player.onPosition=()=>{if(++calls===1)h.player.close();};settled(h);await h.player.reports.flush();assert.equal(calls,1);assert.equal(h.video.playCalls,0);assert.equal(starts(h).length,0);assert.equal(h.video.preload,'metadata');await closed(h);
});
test('onPosition reentrant ready events admit once',async t=>{
 const h=harness(t,{history:true});await open(h);ready(h);let calls=0;h.player.onPosition=()=>{calls++;h.video.emit('canplay');};settled(h);await h.player.reports.flush();assert.equal(calls,1);assert.equal(h.video.playCalls,1);assert.equal(starts(h).length,1);await closed(h);
});
test('reentrant Close during preload mutation prevents stale src/load',async t=>{
 const h=harness(t);h.video.onPreload=value=>{if(value==='auto')h.player.close();};await open(h);assert.equal(h.video.src,'');assert.ok(!h.video.mutations.includes('src:true'));assert.ok(!h.video.mutations.includes('load:auto:true'));assert.equal(h.video.playCalls,0);assert.equal(h.video.preload,'metadata');await closed(h);
});
test('reentrant Close during src mutation prevents stale load',async t=>{
 const h=harness(t);h.video.onSrc=()=>h.player.close();await open(h);assert.ok(!h.video.mutations.includes('load:auto:true'));assert.equal(h.video.src,'');assert.equal(h.video.preload,'metadata');assert.equal(h.video.playCalls,0);await closed(h);
});
test('a newer external preload policy is not overwritten by old restoration',async t=>{
 const h=harness(t);await open(h);h.video.preload='none';await closed(h);assert.equal(h.video.preload,'none');
});
test('old callbacks cannot start or restore preload over a replacement account',async t=>{
 const h=harness(t);await open(h);const snap=h.video.snapshot();const b=connection('second');t.mock.method(b,'playback',async()=>hlsInfo('session-b'));await h.player.open(b,item,{bitrate:120000000,start:5});assert.equal(h.video.preload,'auto');h.video.stale(snap,['canplay','seeked','playing','timeupdate','error']);assert.equal(h.video.playCalls,0);assert.equal(h.video.preload,'auto');ready(h);settled(h,5);assert.equal(h.video.playCalls,1);await closed(h,['session-1','session-b']);assert.equal(h.video.preload,'metadata');
});
test('retry removes old policy and reapplies auto with desired target intact',async t=>{
 const h=harness(t);await open(h);ready(h);settled(h,0);h.player.retry();await settle();const changes=h.video.mutations.filter(x=>x.startsWith('preload:'));assert.deepEqual(changes,['preload:metadata','preload:auto','preload:metadata','preload:auto']);ready(h);settled(h);assert.equal(h.video.playCalls,1);await closed(h,['session-1','session-2']);
});
test('native error fallback preserves target and exact owned restoration',async t=>{
 const h=harness(t);await open(h);h.video.emit('error');await settle();assert.equal(h.preparations[1].fallback,'audio');assert.equal(h.video.preload,'auto');ready(h);assert.equal(h.video.writes.at(-1),31.794);settled(h);await closed(h,['session-1','session-2']);assert.equal(h.video.preload,'metadata');
});
test('load exception restores owned policy and releases session',async t=>{
 const h=harness(t);h.video.onSrc=()=>{h.video.failNextLoad=true;};await open(h);assert.ok(h.states.includes('error'));assert.equal(h.video.preload,'metadata');assert.equal(h.video.src,'');assert.equal(h.video.playCalls,0);await closed(h);
});
test('preload setter exception restores applied owned value and releases session',async t=>{
 const h=harness(t);h.video.onPreload=value=>{if(value==='auto')throw Error('Synthetic preload setter rejection');};await open(h);assert.ok(h.states.includes('error'));assert.equal(h.video.preload,'metadata');assert.equal(h.video.playCalls,0);await closed(h);
});
for(const platform of ['web','desktop','tizen','unknown'])test(platform+' retains metadata preload and historical seek behavior',async t=>{
 const h=harness(t,{platform});await open(h);assert.equal(h.video.preload,'metadata');ready(h);assert.deepEqual(h.video.writes,[31.794]);settled(h);assert.equal(h.video.playCalls,1);await closed(h);
});
test('webOS zeroStart remains metadata/no-seek normal playback',async t=>{
 const h=harness(t);await open(h,0);assert.equal(h.video.preload,'metadata');ready(h);assert.deepEqual(h.video.writes,[]);assert.equal(h.video.playCalls,1);await closed(h);
});
test('webOS direct file retains metadata and loadedmetadata seek',async t=>{
 const h=harness(t,{direct:true});await open(h);assert.equal(h.video.preload,'metadata');h.video.emit('loadedmetadata');assert.deepEqual(h.video.writes,[31.794]);settled(h);assert.equal(h.video.playCalls,1);await closed(h);
});
test('nonfinite resume is excluded from new policy, not silently converted to zero',async t=>{
 const h=harness(t);await open(h,NaN);assert.equal(h.video.preload,'metadata');assert.ok(!h.video.mutations.includes('preload:auto'));await closed(h);
});
test('protected history remains disabled after confirmed target admission',async t=>{
 const h=harness(t,{history:true,remote:true});await open(h);ready(h);settled(h);await h.player.reports.flush();assert.equal(starts(h).length,0);await closed(h);
});
test('unadmitted EOF retains desired target and never starts from stale callbacks',async t=>{
 const h=harness(t);await open(h);const snap=h.video.snapshot();h.video.ended=true;h.video.emit('ended');assert.ok(h.states.includes('error'));assert.deepEqual(h.positions,[]);assert.equal(h.video.preload,'metadata');h.video.value=31.794;h.video.readyState=4;h.video.ended=false;h.video.stale(snap,['canplay','seeked','playing']);assert.equal(h.video.playCalls,0);h.player.retry();await settle();ready(h);settled(h);assert.equal(h.video.playCalls,1);await closed(h,['session-1','session-2']);
});
test('admitted EOF cannot restart from late errors or readiness',async t=>{
 const h=harness(t,{history:true});await open(h);ready(h);settled(h);h.video.ended=true;h.video.emit('ended');for(const n of ['error','canplay','playing','ended'])h.video.emit(n);await settle();assert.equal(h.preparations.length,1);assert.equal(h.video.playCalls,1);await closed(h);
});

test('canplay with insufficient actual readiness cannot consume the scoped initial seek',async t=>{
 const h=harness(t);await open(h);h.video.readyState=2;h.video.emit('canplay');assert.deepEqual(h.video.writes,[]);assert.equal(h.video.playCalls,0);ready(h);assert.deepEqual(h.video.writes,[31.794]);settled(h);assert.equal(h.video.playCalls,1);await closed(h);
});
