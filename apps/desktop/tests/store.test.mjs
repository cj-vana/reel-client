import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,readFile,writeFile,rm,symlink,readdir,chmod} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomBytes,createCipheriv,createDecipheriv} from 'node:crypto';
import {DesktopStore,validConnectionWrite,validPreferenceWrite,syncDirectory} from '../src/store.mjs';
const account={id:'https://jellyfin.example.com|qa-user',server:'https://jellyfin.example.com',token:'synthetic-secret-access-token',userId:'qa-user',name:'Test',serverName:'Test library',remember:true};
const value=(expectedRevision=0,accounts=[account])=>({expectedRevision,accounts,activeId:accounts[0]?.id??null});
function cryptoProvider(){const key=randomBytes(32);return{available:async()=>true,encrypt:async text=>{const iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',key,iv),data=Buffer.concat([cipher.update(text,'utf8'),cipher.final()]);return Buffer.concat([iv,cipher.getAuthTag(),data]);},decrypt:async bytes=>{const cipher=createDecipheriv('aes-256-gcm',key,bytes.subarray(0,12));cipher.setAuthTag(bytes.subarray(12,28));return Buffer.concat([cipher.update(bytes.subarray(28)),cipher.final()]).toString();}};}
async function fixture(run){const parent=await mkdtemp(join(tmpdir(),'reel-store-')),directory=join(parent,'store'),crypto=cryptoProvider();try{await run(new DesktopStore(directory,crypto),crypto,directory);}finally{await rm(parent,{recursive:true,force:true});}}
test('initialize is single-flight with a stable device id and no writable state when encryption is unavailable',async()=>fixture(async(store,crypto,dir)=>{let calls=0;crypto.available=async()=>{calls++;return false;};const[a,b]=await Promise.all([store.initialize(),store.initialize()]);assert.equal(calls,1);assert.equal(a.storeState,'unavailable');assert.equal('revision'in a,false);assert.equal('savedConnections'in a,false);assert.equal(a.deviceId,b.deviceId);const reopened=await new DesktopStore(dir,crypto).initialize();assert.equal(reopened.deviceId,a.deviceId);assert.deepEqual(await store.saveConnections(value(),()=>true),{ok:false,code:'unavailable'});}));
test('stalled availability fails closed, ignores late unlock and preserves the vault until a normal reopen',async()=>fixture(async(store,crypto,dir)=>{
 await store.initialize();await store.saveConnections(value(),()=>true);
 const before=await readFile(join(dir,'connections.vault'));let finish,calls=0;
 const pending=new DesktopStore(dir,{...crypto,available:()=>{calls++;return new Promise(resolve=>{finish=resolve;});}},{availabilityTimeoutMs:10});
 const [first,second]=await Promise.all([pending.initialize(),pending.initialize()]);
 assert.equal(first.storeState,'unavailable');assert.deepEqual(second,first);assert.equal(calls,1);
 assert.equal('savedConnections'in first,false);assert.equal('revision'in first,false);
 finish(true);await Promise.resolve();assert.equal((await pending.initialize()).storeState,'unavailable');
 assert.deepEqual(await pending.saveConnections(value(1,[]),()=>true),{ok:false,code:'unavailable'});
 assert.deepEqual(await pending.savePreferences({expectedRevision:0,quality:2000000,history:false,autoplay:false},()=>true),{ok:true,revision:1});
 assert.deepEqual(await readFile(join(dir,'connections.vault')),before);
 const reopened=await new DesktopStore(dir,crypto).initialize();assert.equal(reopened.storeState,'ready');assert.equal(reopened.revision,1);assert.deepEqual(reopened.savedConnections.accounts,[account]);assert.equal(reopened.preferences.autoplay,false);
}));
test('availability rejection is recoverable unavailable storage and does not classify a valid vault as corrupt',async()=>fixture(async(store,crypto,dir)=>{
 await store.initialize();await store.saveConnections(value(),()=>true);const before=await readFile(join(dir,'connections.vault'));
 const failed=new DesktopStore(dir,{...crypto,available:async()=>{throw Error('OS service unavailable');}});
 assert.equal((await failed.initialize()).storeState,'unavailable');assert.deepEqual(await readFile(join(dir,'connections.vault')),before);
 assert.equal((await new DesktopStore(dir,crypto).initialize()).storeState,'ready');
}));
test('remembered account persists only as encrypted bytes; reload reads current monotonic revision',async()=>fixture(async(store,crypto,dir)=>{await store.initialize();assert.deepEqual(await store.saveConnections(value(),()=>true),{ok:true,revision:1});const bytes=await readFile(join(dir,'connections.vault'));assert.equal(bytes.includes(Buffer.from(account.token)),false);assert.equal((await store.initialize()).revision,1);const reopened=await new DesktopStore(dir,crypto).initialize();assert.deepEqual(reopened.savedConnections.accounts,[account]);assert.equal(reopened.revision,1);}));
test('empty tombstone revision survives restart and rejects ABA stale restore',async()=>fixture(async(store,crypto,dir)=>{await store.initialize();await store.saveConnections(value(),()=>true);await store.saveConnections(value(1,[]),()=>true);const next=new DesktopStore(dir,crypto);const state=await next.initialize();assert.equal(state.revision,2);assert.deepEqual(state.savedConnections.accounts,[]);assert.deepEqual(await next.saveConnections(value(0),()=>true),{ok:false,code:'conflict'});}));
test('concurrent main-process CAS writes serialize and only one matching revision succeeds',async()=>fixture(async store=>{await store.initialize();const result=await Promise.all([store.saveConnections(value(),()=>true),store.saveConnections(value(),()=>true)]);assert.deepEqual(result,[{ok:true,revision:1},{ok:false,code:'conflict'}]);}));
test('same-URL document epoch change during async encryption cannot commit',async()=>fixture(async(store,crypto,dir)=>{await store.initialize();let release,epoch=0;const encrypt=crypto.encrypt;crypto.encrypt=async text=>{await new Promise(done=>{release=done;});return encrypt(text);};const write=store.saveConnections(value(),()=>epoch===0);while(!release)await new Promise(done=>setImmediate(done));epoch++;release();assert.deepEqual(await write,{ok:false,code:'closing'});assert.equal((await store.initialize()).revision,0);assert.deepEqual((await readdir(dir)).sort(),['preferences.json']);}));
test('encryption failure leaves the previous ciphertext and revision untouched',async()=>fixture(async(store,crypto,dir)=>{await store.initialize();await store.saveConnections(value(),()=>true);const before=await readFile(join(dir,'connections.vault'));crypto.encrypt=async()=>{throw new Error('temporarily unavailable');};assert.deepEqual(await store.saveConnections(value(1,[]),()=>true),{ok:false,code:'io'});assert.deepEqual(await readFile(join(dir,'connections.vault')),before);assert.equal((await store.initialize()).revision,1);}));
test('filesystem write failure preserves the previous durable snapshot',async()=>fixture(async(store,_crypto,dir)=>{await store.initialize();await store.saveConnections(value(),()=>true);const before=await readFile(join(dir,'connections.vault'));await chmod(dir,0o500);try{assert.deepEqual(await store.saveConnections(value(1,[]),()=>true),{ok:false,code:'io'});assert.deepEqual(await readFile(join(dir,'connections.vault')),before);}finally{await chmod(dir,0o700);}}));
test('locked ciphertext is preserved without a writable revision or silent empty merge',async()=>fixture(async(store,crypto,dir)=>{await store.initialize();await store.saveConnections(value(),()=>true);const before=await readFile(join(dir,'connections.vault'));const locked=new DesktopStore(dir,{...crypto,decrypt:async()=>{throw new Error('locked');}});const state=await locked.initialize();assert.equal(state.storeState,'locked');assert.equal('revision'in state,false);assert.deepEqual(await locked.saveConnections(value(),()=>true),{ok:false,code:'locked'});assert.deepEqual(await readFile(join(dir,'connections.vault')),before);}));
test('malformed decrypted document is corrupt and original ciphertext is retained',async()=>fixture(async(store,crypto,dir)=>{await store.initialize();const bytes=await crypto.encrypt('{"schema":1,"revision":-1}');await writeFile(join(dir,'connections.vault'),bytes,{mode:0o600});const other=new DesktopStore(dir,crypto),state=await other.initialize();assert.equal(state.storeState,'corrupt');assert.equal('revision'in state,false);assert.deepEqual(await readFile(join(dir,'connections.vault')),bytes);}));
test('vault symlink is rejected without reading its target',async()=>fixture(async(store,crypto,dir)=>{await store.initialize();const target=join(dir,'outside');await writeFile(target,'not-a-vault');await symlink(target,join(dir,'connections.vault'));const state=await new DesktopStore(dir,crypto).initialize();assert.equal(state.storeState,'corrupt');assert.equal(await readFile(target,'utf8'),'not-a-vault');}));
test('session-only accounts and unknown DTO fields never enter encrypted persistence',async()=>fixture(async store=>{await store.initialize();assert.equal(validConnectionWrite({...value(),extra:true}),false);assert.equal(validConnectionWrite(value(0,[{...account,remember:false}])),false);assert.deepEqual(await store.saveConnections(value(0,[{...account,remember:false}]),()=>true),{ok:false,code:'invalid'});assert.equal(validConnectionWrite(value(-1)),false);assert.equal(validPreferenceWrite({expectedRevision:0,quality:120000000,history:false,extra:0}),false);}));
test('preferences use CAS and persist history-off separately from connection ciphertext',async()=>fixture(async(store,crypto,dir)=>{await store.initialize();assert.deepEqual(await store.savePreferences({expectedRevision:0,quality:2000000,history:true},()=>true),{ok:true,revision:1});assert.deepEqual(await store.savePreferences({expectedRevision:0,quality:8000000,history:false},()=>true),{ok:false,code:'conflict'});assert.deepEqual(await store.savePreferences({expectedRevision:1,quality:8000000,history:false},()=>true),{ok:true,revision:2});const state=await new DesktopStore(dir,crypto).initialize();assert.deepEqual(state.preferences,{quality:8000000,history:false,autoplay:true,markers:true,autoSkip:false,updates:true});assert.equal(state.preferenceRevision,2);assert.equal((await readFile(join(dir,'preferences.json'),'utf8')).includes(account.token),false);}));
test('POSIX metadata sync brackets rename; Windows metadata durability stays explicitly unqualified',async()=>fixture(async store=>{await store.initialize();const phases=[];store.directorySync=(dir,phase)=>{phases.push(phase);const result=syncDirectory(dir);assert.equal(result,process.platform==='win32'?'platform-unverified':'synced');};assert.deepEqual(await store.saveConnections(value(),()=>true),{ok:true,revision:1});assert.deepEqual(phases,['before','after']);}));
test('directory sync failure before rename preserves the old ciphertext and writable revision',async()=>fixture(async(store,_crypto,dir)=>{await store.initialize();await store.saveConnections(value(),()=>true);const before=await readFile(join(dir,'connections.vault'));store.directorySync=()=>{throw Error('Synthetic pre-rename metadata failure');};assert.deepEqual(await store.saveConnections(value(1,[]),()=>true),{ok:false,code:'io'});assert.deepEqual(await readFile(join(dir,'connections.vault')),before);assert.equal((await store.initialize()).revision,1);assert.equal(store.quarantined,false);}));
test('post-rename sync failure preserves committed tombstone and quarantines every writer until native reopen',async()=>fixture(async(store,crypto,dir)=>{await store.initialize();await store.saveConnections(value(),()=>true);store.directorySync=(directory,phase)=>{syncDirectory(directory);if(phase==='after')throw Error('Synthetic post-rename failure');};assert.deepEqual(await store.saveConnections(value(1,[]),()=>true),{ok:false,code:'uncertain'});const committed=await readFile(join(dir,'connections.vault'));assert.deepEqual(await store.initialize(),{ok:false,code:'uncertain'});assert.deepEqual(await store.saveConnections(value(1),()=>true),{ok:false,code:'uncertain'});assert.deepEqual(await store.savePreferences({expectedRevision:0,quality:2000000,history:false},()=>true),{ok:false,code:'uncertain'});assert.deepEqual(await readFile(join(dir,'connections.vault')),committed);const reopened=await new DesktopStore(dir,crypto).initialize();assert.equal(reopened.revision,2);assert.deepEqual(reopened.savedConnections.accounts,[]);assert.equal((await readdir(dir)).some(name=>name.startsWith('.pending-')),false);}));
test('post-rename preference uncertainty fences later preferences without rewriting the committed value',async()=>fixture(async(store,crypto,dir)=>{await store.initialize();store.directorySync=(directory,phase)=>{syncDirectory(directory);if(phase==='after')throw Error('Synthetic post-rename failure');};const first=store.savePreferences({expectedRevision:0,quality:2000000,history:false,autoplay:false},()=>true),second=store.savePreferences({expectedRevision:1,quality:8000000,history:true,autoplay:true},()=>true);assert.deepEqual(await first,{ok:false,code:'uncertain'});assert.deepEqual(await second,{ok:false,code:'uncertain'});const reopened=await new DesktopStore(dir,crypto).initialize();assert.deepEqual(reopened.preferences,{quality:2000000,history:false,autoplay:false,markers:true,autoSkip:false,updates:true});assert.equal(reopened.preferenceRevision,1);}));
test('new preferences enable autoplay and persist that default across reopen',async()=>fixture(async(store,crypto,dir)=>{
 const first=await store.initialize();assert.equal(first.preferences.autoplay,true);
 assert.equal(JSON.parse(await readFile(join(dir,'preferences.json'),'utf8')).autoplay,true);
 assert.equal((await new DesktopStore(dir,crypto).initialize()).preferences.autoplay,true);
}));
test('legacy preferences acquire autoplay only on a normal atomic save while preserving device and vault identity',async()=>fixture(async(store,crypto,dir)=>{
 const first=await store.initialize();await store.saveConnections(value(),()=>true);
 const vault=await readFile(join(dir,'connections.vault'));
 const legacy=JSON.stringify({schema:1,revision:12,deviceId:first.deviceId,quality:8000000,history:true});
 await writeFile(join(dir,'preferences.json'),legacy,{mode:0o600});
 const migrated=new DesktopStore(dir,crypto),loaded=await migrated.initialize();
 assert.equal(loaded.preferences.autoplay,true);assert.equal(loaded.preferenceRevision,12);assert.equal(loaded.deviceId,first.deviceId);
 assert.deepEqual(loaded.savedConnections,{accounts:[account],activeId:account.id});assert.equal(loaded.revision,1);
 assert.equal(await readFile(join(dir,'preferences.json'),'utf8'),legacy);assert.deepEqual(await readFile(join(dir,'connections.vault')),vault);
 assert.deepEqual(await migrated.savePreferences({expectedRevision:12,quality:8000000,history:true,autoplay:false},()=>true),{ok:true,revision:13});
 const reopened=await new DesktopStore(dir,crypto).initialize();
 assert.deepEqual(reopened.preferences,{quality:8000000,history:true,autoplay:false,markers:true,autoSkip:false,updates:true});assert.equal(reopened.preferenceRevision,13);assert.equal(reopened.deviceId,first.deviceId);
 assert.deepEqual(reopened.savedConnections,loaded.savedConnections);assert.equal(reopened.revision,1);assert.deepEqual(await readFile(join(dir,'connections.vault')),vault);
}));
test('preference validation accepts omitted autoplay but rejects malformed present values and unknown fields before writing',async()=>fixture(async(store,_crypto,dir)=>{
 await store.initialize();const before=await readFile(join(dir,'preferences.json'));
 const base={expectedRevision:0,quality:120000000,history:false};
 assert.equal(validPreferenceWrite(base),true);
 for(const autoplay of [undefined,null,0,1,'false',[],{}]){
  const input={...base,autoplay};assert.equal(validPreferenceWrite(input),false);
  assert.deepEqual(await store.savePreferences(input,()=>true),{ok:false,code:'invalid'});
 }
 assert.equal(validPreferenceWrite({...base,autoplay:false,other:true}),false);
 assert.deepEqual(await readFile(join(dir,'preferences.json')),before);assert.equal((await store.initialize()).preferenceRevision,0);
}));
test('malformed persisted autoplay remains untouched with its encrypted vault',async()=>fixture(async(store,crypto,dir)=>{
 const first=await store.initialize();await store.saveConnections(value(),()=>true);const vault=await readFile(join(dir,'connections.vault'));
 for(const autoplay of [null,0,'false',{},[]]){
  const bytes=JSON.stringify({schema:1,revision:4,deviceId:first.deviceId,quality:8000000,history:false,autoplay});
  await writeFile(join(dir,'preferences.json'),bytes,{mode:0o600});
  const state=await new DesktopStore(dir,crypto).initialize();assert.equal(state.storeState,'corrupt');assert.equal('savedConnections'in state,false);
  assert.equal(await readFile(join(dir,'preferences.json'),'utf8'),bytes);assert.deepEqual(await readFile(join(dir,'connections.vault')),vault);
 }
}));
test('failed atomic autoplay save preserves both durable files and permits a revision-correct retry',async()=>fixture(async(store,crypto,dir)=>{
 await store.initialize();await store.saveConnections(value(),()=>true);
 const before=await readFile(join(dir,'preferences.json')),vault=await readFile(join(dir,'connections.vault'));
 const input={expectedRevision:0,quality:8000000,history:false,autoplay:false};
 store.directorySync=()=>{throw Error('Synthetic pre-rename preference failure');};
 assert.deepEqual(await store.savePreferences(input,()=>true),{ok:false,code:'io'});
 assert.deepEqual(await readFile(join(dir,'preferences.json')),before);assert.deepEqual(await readFile(join(dir,'connections.vault')),vault);
 assert.equal((await store.initialize()).preferences.autoplay,true);assert.equal((await store.initialize()).preferenceRevision,0);
 assert.equal((await readdir(dir)).some(name=>name.startsWith('.pending-')),false);
 store.directorySync=syncDirectory;
 assert.deepEqual(await store.savePreferences(input,()=>true),{ok:true,revision:1});
 assert.deepEqual(await store.savePreferences({...input,autoplay:true},()=>true),{ok:false,code:'conflict'});
 assert.equal((await new DesktopStore(dir,crypto).initialize()).preferences.autoplay,false);
 assert.deepEqual(await readFile(join(dir,'connections.vault')),vault);
}));
test('intro switches default to finding markers without skipping, persist, and refuse malformed values',async()=>fixture(async(store,crypto,dir)=>{
 const first=await store.initialize();assert.equal(first.preferences.markers,true);assert.equal(first.preferences.autoSkip,false);
 assert.deepEqual(await store.savePreferences({expectedRevision:0,quality:8000000,history:true,autoplay:true,markers:false,autoSkip:true},()=>true),{ok:true,revision:1});
 assert.deepEqual((await new DesktopStore(dir,crypto).initialize()).preferences,{quality:8000000,history:true,autoplay:true,markers:false,autoSkip:true,updates:true});
 for(const bad of[{markers:'no'},{autoSkip:1},{updates:'yes'},{skipIntros:true}])assert.deepEqual(await store.savePreferences({expectedRevision:1,quality:8000000,history:true,...bad},()=>true),{ok:false,code:'invalid'});
}));
