import test from 'node:test';
import assert from 'node:assert/strict';
import {Connections,browserStorage,type StorageLike} from '../src/storage.ts';
import type {Account} from '../src/types.ts';
const KEY='reel.connections.v1';
const account=(id:string,remember=true):Account=>({id,server:'https://fixture.invalid',token:'fixture-'+id,userId:id,name:'Name '+id,serverName:'Server '+id,remember});
const original=JSON.stringify({accounts:[account('kept')],activeId:'kept'});
function fixture(raw:string|null=original){
 let current=raw,failRead=false,failWrite=false,writes=0,reads=0;const other=new Map<string,string>();
 const storage:StorageLike={getItem(key){if(key!==KEY)return other.get(key)??null;reads++;if(failRead)throw Error('Synthetic read failure');return current;},setItem(key,value){if(key!==KEY){other.set(key,value);return;}if(failWrite)throw Error('Synthetic quota');writes++;current=value;},removeItem(key){if(key===KEY)throw Error('Unexpected saved removal');other.delete(key);}};
 return{storage,get raw(){return current;},set raw(value:string|null){current=value;},set failRead(value:boolean){failRead=value;},set failWrite(value:boolean){failWrite=value;},get writes(){return writes;},get reads(){return reads;},other};
}
test('missing saved key is a valid empty state and valid complete metadata restores',()=>{
 const empty=new Connections(fixture(null).storage);assert.equal(empty.recovery,null);assert.equal(empty.active,null);
 const restored=new Connections(fixture().storage);assert.equal(restored.active?.id,'kept');assert.deepEqual(restored.active,account('kept'));
});
for(const [name,raw]of Object.entries({malformed:'{broken',null:'null',array:'[]',missing:'{}',schema:'{"accounts":"invalid","activeId":null}',selection:JSON.stringify({accounts:[account('kept')],activeId:'missing'}),partial:JSON.stringify({accounts:[account('kept'),{id:'broken'}],activeId:'kept'}),duplicate:JSON.stringify({accounts:[account('kept'),account('kept')],activeId:'kept'}),url:JSON.stringify({accounts:[{...account('kept'),server:'javascript:alert(1)'}],activeId:'kept'}),rootMetadata:JSON.stringify({accounts:[account('kept')],activeId:'kept',futureVersion:2}),accountMetadata:JSON.stringify({accounts:[{...account('kept'),future:{preserve:true}}],activeId:'kept'})})){
 test(name+' saved bytes are quarantined as a whole and never silently filtered/replaced',()=>{
  const f=fixture(raw),c=new Connections(f.storage);assert.equal(c.recovery?.reason,'invalid');assert.equal(c.all.length,0);
  c.add(account('new'));assert.equal(c.active?.id,'new');assert.equal(c.recovery?.pendingRemember,1);assert.equal(f.raw,raw);assert.equal(f.writes,0);
  assert.throws(()=>c.retrySaved());assert.equal(c.active?.id,'new');assert.equal(f.raw,raw);assert.equal(f.writes,0);
 });
}
for(const remember of[false,true]){
 test('transient initial read then valid mutation merges existing account with Remember '+remember,()=>{
  const f=fixture();f.failRead=true;const c=new Connections(f.storage);assert.equal(c.recovery?.reason,'read');f.failRead=false;
  c.add(account('new',remember));assert.equal(c.active?.id,'new');assert.equal(c.recovery,null);assert.equal(c.all.length,2);
  const saved=JSON.parse(f.raw!);assert.deepEqual(saved.accounts.find((a:Account)=>a.id==='kept'),account('kept'));assert.equal(saved.accounts.some((a:Account)=>a.id==='new'),remember);
 });
 test('failed add read accepts active session and valid explicit retry merges Remember '+remember,()=>{
  const f=fixture();f.failRead=true;const c=new Connections(f.storage);c.add(account('new',remember));assert.equal(c.active?.id,'new');assert.equal(f.raw,original);assert.equal(f.writes,0);
  assert.throws(()=>c.retrySaved());assert.equal(c.active?.id,'new');assert.equal(f.raw,original);
  f.failRead=false;c.retrySaved();assert.equal(c.recovery,null);assert.equal(c.active?.id,'new');assert.equal(c.all.length,2);
  const saved=JSON.parse(f.raw!);assert.deepEqual(saved.accounts.find((a:Account)=>a.id==='kept'),account('kept'));assert.equal(saved.accounts.some((a:Account)=>a.id==='new'),remember);
  const cold=new Connections(f.storage);assert.equal(cold.all.some(a=>a.id==='new'),remember);assert.equal(cold.active?.id,remember?'new':'kept');
  if(!remember)assert.equal(f.raw,original);
 });
}
test('local pending additions and removal tombstones reconcile in order without resurrection',()=>{
 const f=fixture(),c=new Connections(f.storage);f.failRead=true;c.add(account('one'));c.add(account('two',false));c.remove('kept');assert.equal(c.active?.id,'two');assert.equal(c.recovery?.pendingRemovals,1);assert.equal(f.raw,original);
 f.failRead=false;c.retrySaved();assert.equal(c.active?.id,'two');assert.deepEqual(c.all.map(a=>a.id),['one','two']);assert.deepEqual(JSON.parse(f.raw!).accounts.map((a:Account)=>a.id),['one']);assert.equal(new Connections(f.storage).all.some(a=>a.id==='kept'),false);
});
test('fresh externally saved accounts and complete metadata survive the next client mutation',()=>{
 const f=fixture(),c=new Connections(f.storage);const external={...account('external'),name:'Updated display name',serverName:'Updated server'};f.raw=JSON.stringify({accounts:[account('kept'),external],activeId:'external'});
 c.add(account('session',false));assert.equal(c.active?.id,'session');assert.deepEqual(c.all.find(a=>a.id==='external'),external);assert.deepEqual(JSON.parse(f.raw!).accounts.find((a:Account)=>a.id==='external'),external);
});
test('external corruption fences durable mutations while current session remains usable',()=>{
 const f=fixture(),c=new Connections(f.storage);f.raw='{later-corruption';c.add(account('session',false));assert.equal(c.active?.id,'session');assert.equal(c.recovery?.reason,'invalid');assert.equal(f.raw,'{later-corruption');assert.equal(f.writes,0);
});
test('replacement requires explicit recovery method and writes only known remembered intents',()=>{
 const f=fixture('{preserved'),c=new Connections(f.storage);c.add(account('remembered'));c.add(account('session',false));assert.equal(f.writes,0);assert.equal(f.raw,'{preserved');
 c.replaceSaved();assert.equal(c.recovery,null);assert.equal(c.active?.id,'session');assert.deepEqual(JSON.parse(f.raw!).accounts,[account('remembered')]);assert.equal(JSON.parse(f.raw!).activeId,null);assert.equal(new Connections(f.storage).all.length,1);assert.throws(()=>c.replaceSaved());
});
test('quota failure during ordinary save preserves published account and old saved bytes',()=>{
 const f=fixture(),c=new Connections(f.storage);f.failWrite=true;assert.throws(()=>c.add(account('rejected')),/could not save/);assert.equal(c.active?.id,'kept');assert.equal(c.all.length,1);assert.equal(f.raw,original);
});
test('quota failure during reconciliation or explicit replacement preserves recovery/session state',()=>{
 const f=fixture();f.failRead=true;const c=new Connections(f.storage);c.add(account('new'));f.failRead=false;f.failWrite=true;
 assert.throws(()=>c.retrySaved());assert.equal(c.active?.id,'new');assert.equal(c.recovery?.reason,'read');assert.equal(f.raw,original);
 assert.throws(()=>c.replaceSaved());assert.equal(c.active?.id,'new');assert.equal(c.recovery?.reason,'read');assert.equal(f.raw,original);f.failWrite=false;c.retrySaved();assert.equal(new Connections(f.storage).active?.id,'new');
});
test('session fallback capability cannot claim Remember or reset an inaccessible persistent store',()=>{
 const f=fixture(null),storage={...f.storage,persistent:false},c=new Connections(storage);c.add(account('session',false));assert.equal(c.canRemember,false);assert.equal(c.recovery?.reason,'unavailable');assert.equal(c.recovery?.canReplace,false);assert.throws(()=>c.retrySaved());assert.throws(()=>c.replaceSaved());assert.equal(f.writes,0);
});
test('account quarantine leaves device/preferences keys independent',()=>{
 const f=fixture('null');f.other.set('reel.device.v1','synthetic-device');f.other.set('reel.quality','20000000');f.other.set('reel.history','false');const c=new Connections(f.storage);c.add(account('session',false));assert.equal(f.other.get('reel.device.v1'),'synthetic-device');assert.equal(f.other.get('reel.quality'),'20000000');assert.equal(f.other.get('reel.history'),'false');
});
test('desktop persistence cannot be retried/replaced through browser recovery controls',async()=>{
 const f=fixture('{preserved');let writes=0;const c=new Connections(f.storage,{snapshot:{accounts:[account('kept')],activeId:'kept'},save:async()=>{writes++;}});assert.equal(c.recovery,null);assert.throws(()=>c.retrySaved());assert.throws(()=>c.replaceSaved());await c.add(account('new'));assert.equal(writes,1);assert.equal(f.reads,0);assert.equal(f.raw,'{preserved');
});
test('browser storage fallback exposes session-only capability metadata',()=>{
 const before=Object.getOwnPropertyDescriptor(globalThis,'localStorage');Object.defineProperty(globalThis,'localStorage',{configurable:true,get(){throw Error('Synthetic denied storage');}});
 try{const storage=browserStorage();assert.equal(storage.persistent,false);storage.setItem('session','only');assert.equal(storage.getItem('session'),'only');}
 finally{if(before)Object.defineProperty(globalThis,'localStorage',before);else Reflect.deleteProperty(globalThis,'localStorage');}
});
