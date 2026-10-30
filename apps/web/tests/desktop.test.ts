import test from 'node:test';
import assert from 'node:assert/strict';
import {setImmediate as settle} from 'node:timers/promises';
import {DesktopSession,DesktopLifecycle,desktopBridge,memoryStorage,uncertainDesktopError,type DesktopBridge,type DesktopInitialization} from '../src/desktop.ts';
import {Connections} from '../src/storage.ts';
import type {Account} from '../src/types.ts';
const account=(name:string,remember=true):Account=>({id:'https://jellyfin.example.com|'+name,server:'https://jellyfin.example.com',token:'synthetic-'+name,userId:name,name,serverName:'Test',remember});
const initial=(state:'ready'|'locked'|'corrupt'|'unavailable'='ready'):Extract<DesktopInitialization,{ok:true}>=>({ok:true,storeState:state,...(state==='ready'?{revision:0,savedConnections:{accounts:[],activeId:null}}:{}),deviceId:'12345678-1234-1234-1234-123456789abc',preferences:{quality:120000000,history:false},preferenceRevision:0});
function bridge():DesktopBridge{return{initialize:async()=>initial(),saveConnections:async value=>({ok:true,revision:value.expectedRevision+1}),savePreferences:async value=>({ok:true,revision:value.expectedRevision+1}),acknowledgeClose:async()=>({ok:true}),onCloseRequested:()=>()=>{}};}
test('desktop platform requires the complete fixed bridge while ordinary web remains optional',()=>{
  assert.equal(desktopBridge(undefined),undefined);
  assert.throws(()=>desktopBridge(undefined,true),/interface could not start/);
  assert.throws(()=>desktopBridge({initialize:async()=>initial()},true),/interface could not start/);
  const api=bridge();assert.equal(desktopBridge(api,true),api);
});
test('desktop account intents serialize without publishing before encrypted acknowledgement',async()=>{
  const api=bridge();let release!:()=>void;const writes:number[]=[];api.saveConnections=async value=>{writes.push(value.expectedRevision);if(writes.length===1)await new Promise<void>(done=>{release=done;});return{ok:true,revision:value.expectedRevision+1};};
  const desktop=new DesktopSession(api,initial()),connections=new Connections(desktop.storage,desktop.persistence);
  const first=connections.add(account('one')),second=connections.add(account('two'));await settle();assert.equal(connections.all.length,0);assert.deepEqual(writes,[0]);release();await Promise.all([first,second]);assert.deepEqual(writes,[0,1]);assert.equal(connections.all.length,2);assert.equal(connections.active?.userId,'two');assert.equal(desktop.storage.getItem('reel.connections.v1'),null);
});
test('failed desktop save preserves current account and never retries a stale snapshot',async()=>{
  const api=bridge();let calls=0;api.saveConnections=async()=>{calls++;return{ok:false,code:'conflict'};};const desktop=new DesktopSession(api,initial()),connections=new Connections(desktop.storage,desktop.persistence);
  await assert.rejects(connections.add(account('one')));assert.equal(calls,1);assert.equal(connections.all.length,0);
});
for(const state of ['locked','corrupt','unavailable'] as const)test(state+' desktop store offers session-only memory without persisting or deleting its vault',async()=>{
  const api=bridge();let calls=0;api.saveConnections=async()=>{calls++;return{ok:false,code:'unavailable'};};const desktop=new DesktopSession(api,initial(state)),connections=new Connections(desktop.storage,desktop.persistence);assert.equal(desktop.canRemember,false);await connections.add(account('session',false));assert.equal(connections.active?.userId,'session');await connections.remove(account('session').id);assert.equal(calls,0);assert.equal(desktop.storage.getItem('reel.connections.v1'),null);
});
test('session-only account never crosses an available desktop vault bridge',async()=>{
  const api=bridge();let calls=0;api.saveConnections=async value=>{calls++;return{ok:true,revision:value.expectedRevision+1};};const desktop=new DesktopSession(api,initial()),connections=new Connections(desktop.storage,desktop.persistence);await connections.add(account('session',false));assert.equal(calls,0);assert.equal(connections.active?.remember,false);
});
test('ordered preferences commit the later history-off after a delayed history-on',async()=>{
  const api=bridge();const writes:Array<{expectedRevision:number;history:boolean}>=[];let release!:()=>void;api.savePreferences=async value=>{writes.push(value);if(writes.length===1)await new Promise<void>(done=>{release=done;});return{ok:true,revision:value.expectedRevision+1};};const desktop=new DesktopSession(api,initial());const first=desktop.savePreferences(120000000,true),last=desktop.savePreferences(2000000,false);await settle();assert.equal(writes.length,1);release();await Promise.all([first,last]);assert.deepEqual(writes.map(value=>[value.expectedRevision,value.history]),[[0,true],[1,false]]);
});
test('desktop close fences new account/preference intents and drains ones already accepted',async()=>{
  const api=bridge(),desktop=new DesktopSession(api,initial()),connections=new Connections(desktop.storage,desktop.persistence);desktop.close();connections.close();await assert.rejects(desktop.savePreferences(120000000,false));assert.throws(()=>connections.add(account('closed')));await Promise.all([desktop.drain(),connections.drain()]);
});
test('lifecycle registers before initialization and repeated native closes share one drain',async()=>{
  const api=bridge(),events:string[]=[];let close!:(nonce:string)=>void,release!:()=>void;api.onCloseRequested=callback=>{events.push('listen');close=callback;return()=>{};};api.initialize=async()=>{events.push('initialize');return initial();};api.acknowledgeClose=async nonce=>{events.push(nonce);return{ok:true};};const lifecycle=new DesktopLifecycle(api);const boot=api.initialize();let calls=0;lifecycle.setDrain(async()=>{calls++;await new Promise<void>(done=>{release=done;});});close('one');close('one');assert.equal(lifecycle.closing,true);await boot;await settle();assert.deepEqual(events.slice(0,2),['listen','initialize']);assert.equal(calls,1);release();await settle();assert.ok(events.includes('one'));
});
test('native lifecycle deadline acknowledges even when a renderer task cannot finish',async()=>{
  const api=bridge();let close!:(nonce:string)=>void,ack=false;api.onCloseRequested=callback=>{close=callback;return()=>{};};api.acknowledgeClose=async()=>{ack=true;return{ok:true};};const lifecycle=new DesktopLifecycle(api,5);lifecycle.setDrain(()=>new Promise(()=>{}));close('deadline');await new Promise(done=>setTimeout(done,15));assert.equal(ack,true);
});
test('ordinary browser memory storage remains independent of desktop persistence',()=>{const storage=memoryStorage(),connections=new Connections(storage);connections.add(account('browser'));assert.equal(new Connections(storage).active?.userId,'browser');});
test('desktop autoplay hydration defaults older preload responses on and preserves an explicit off choice',()=>{
  for(const autoplay of [undefined,false,true]){
    const state=initial();if(autoplay!==undefined)state.preferences.autoplay=autoplay;
    const desktop=new DesktopSession(bridge(),state);
    assert.equal(desktop.storage.getItem('reel.autoplay'),String(autoplay??true));
    assert.equal(desktop.storage.getItem('reel.history'),'false');
  }
});
test('autoplay saves carry explicit choices and the legacy default in revision order through close drain',async()=>{
  const api=bridge(),writes:Parameters<DesktopBridge['savePreferences']>[0][]=[];let release!:()=>void;
  api.savePreferences=async value=>{writes.push(value);if(writes.length===1)await new Promise<void>(done=>{release=done;});return{ok:true,revision:value.expectedRevision+1};};
  const desktop=new DesktopSession(api,initial());
  const off=desktop.savePreferences(8000000,true,false),on=desktop.savePreferences(2000000,false);
  await settle();assert.equal(writes.length,1);desktop.close();release();await Promise.all([off,on,desktop.drain()]);
  assert.deepEqual(writes,[{quality:8000000,history:true,autoplay:false,markers:true,autoSkip:false,updates:true,expectedRevision:0},{quality:2000000,history:false,autoplay:true,markers:true,autoSkip:false,updates:true,expectedRevision:1}]);
  await assert.rejects(desktop.savePreferences(120000000,false,false));assert.equal(writes.length,2);
});
test('uncertain account commit quarantines writes and preserves provisional token ownership for authoritative reopen',async()=>{
  const api=bridge();let calls=0;api.saveConnections=async()=>{calls++;return{ok:false,code:'uncertain'};};const desktop=new DesktopSession(api,initial()),connections=new Connections(desktop.storage,desktop.persistence);
  await assert.rejects(connections.add(account('uncertain')),error=>uncertainDesktopError(error));assert.equal(desktop.requiresReopen,true);assert.equal(desktop.canRemember,false);assert.equal(connections.active,null);
  await assert.rejects(connections.add(account('retry')),error=>uncertainDesktopError(error));await assert.rejects(desktop.savePreferences(120000000,false),error=>uncertainDesktopError(error));assert.equal(calls,1);
});
test('uncertain preference result prevents queued later values from crossing the bridge',async()=>{
  const api=bridge();let calls=0;api.savePreferences=async()=>{calls++;return{ok:false,code:'uncertain'};};const desktop=new DesktopSession(api,initial());const first=desktop.savePreferences(120000000,true),second=desktop.savePreferences(2000000,false);await assert.rejects(first,error=>uncertainDesktopError(error));await assert.rejects(second,error=>uncertainDesktopError(error));assert.equal(calls,1);assert.equal(desktop.requiresReopen,true);
});

test('hydrating acknowledged server aliases preserves each credential tuple while API identity normalizes independently', async () => {
  const canonical = account('same'), alias = { ...canonical, server: 'https://JELLYFIN.example.com:443', id: 'https://JELLYFIN.example.com:443|same' };
  const api = bridge(), state = initial(); state.savedConnections = { accounts: [canonical, alias], activeId: alias.id };
  const writes: unknown[] = []; api.saveConnections = async value => { assert(value.accounts.every(item => item.id === item.server + '|' + item.userId)); writes.push(value); return { ok: true, revision: value.expectedRevision + 1 }; };
  const desktop = new DesktopSession(api, state), connections = new Connections(desktop.storage, desktop.persistence);
  assert.deepEqual(connections.all, [canonical, alias]); assert.equal(connections.active!.server, alias.server);
  const { JellyfinAPI } = await import('../src/api.ts'); const runtime = new JellyfinAPI(connections.active, connections.active!.server, 'synthetic-device', true);
  assert.equal(runtime.server, canonical.server);
  await connections.switch(canonical.id); await connections.remove(canonical.id); assert.equal(connections.active!.id, alias.id); assert.equal(writes.length, 2);
  assert.equal(connections.active!.server, alias.server); assert.equal(connections.all.length, 1);
});
