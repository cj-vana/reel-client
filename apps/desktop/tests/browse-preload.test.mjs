import{test}from'node:test';
import assert from'node:assert/strict';
import{readFile}from'node:fs/promises';
import vm from'node:vm';
import{EventEmitter}from'node:events';
import{setImmediate as settle}from'node:timers/promises';
const source=await readFile(new URL('../src/preload.cjs',import.meta.url),'utf8');
const account={server:'https://fixture.example/base',userId:'a'};
const lease='11111111-1111-4111-8111-111111111111';
const notice={id:lease,accountId:'a'.repeat(64),count:1,code:'preserved'};
function fixture(reply=async()=>({ok:true,notices:[]})){
 const ipc=new EventEmitter(),exposed=new Map(),calls=[];ipc.invoke=(channel,message)=>{calls.push({channel,message});return reply(channel,message);};
 vm.runInNewContext(source,{require:name=>{assert.equal(name,'electron');return{contextBridge:{exposeInMainWorld:(name,value)=>exposed.set(name,value)},ipcRenderer:ipc};},URL,TextEncoder});
 return{ipc,exposed,calls,bridge:exposed.get('ReelBrowsePreferences')};
}
test('preload exposes a frozen separate purpose-built interface and retains exact credential methods',async()=>{
 const f=fixture();assert.equal(Object.isFrozen(f.bridge),true);assert.deepEqual(Object.keys(f.bridge).sort(),['commit','onCleanupNotice','open','reset','revoke']);assert.deepEqual(Object.keys(f.exposed.get('ReelDesktop')).sort(),['acknowledgeClose','initialize','onCloseRequested','saveConnections','savePreferences']);
 await f.bridge.open({account,generation:0});assert.equal(f.calls[0].channel,'reel:browse-preferences:v1');assert.deepEqual(JSON.parse(JSON.stringify(f.calls[0].message)),{operation:'open',account,generation:0});
});
test('invalid shapes, credential URLs, extra secret fields and arbitrary paths are rejected before IPC',async()=>{
 const f=fixture();
 for(const value of[{account:{...account,token:'synthetic-secret'},generation:0},{account:{...account,server:'https://name:secret@fixture.example'},generation:0},{account,generation:0,path:'/tmp/forbidden'},{account,generation:Infinity}])assert.equal((await f.bridge.open(value)).ok,false);
 for(const value of[{lease,expectedRevision:'absent',path:'/tmp/x'},{lease:'/tmp/x',expectedRevision:'absent'},{lease,expectedRevision:'bad'}])assert.equal((await f.bridge.reset(value)).ok,false);
 const doc={schema:1,account,entries:[]};assert.equal((await f.bridge.commit({lease,expectedRevision:'absent',document:{...doc,token:'secret'}})).ok,false);assert.equal((await f.bridge.commit({lease,expectedRevision:'absent',document:{...doc,account:{...account,password:'secret'}}})).ok,false);
 assert.equal(f.calls.length,0);
});
test('notice subscription attaches before initial snapshot, deduplicates overlap and disposes pending delivery',async()=>{
 let finish;const f=fixture(()=>new Promise(done=>{finish=done;})),seen=[];const dispose=f.bridge.onCleanupNotice(value=>seen.push(value));assert.equal(f.ipc.listenerCount('reel:browse-preferences:notice:v1'),1);
 f.ipc.emit('reel:browse-preferences:notice:v1',{},notice);finish({ok:true,notices:[notice]});await settle();assert.equal(seen.length,1);assert.equal(Object.isFrozen(seen[0]),true);assert.equal(f.calls[0].message.operation,'notices');
 dispose();dispose();assert.equal(f.ipc.listenerCount('reel:browse-preferences:notice:v1'),0);f.ipc.emit('reel:browse-preferences:notice:v1',{}, {...notice,id:'22222222-2222-4222-8222-222222222222'});assert.equal(seen.length,1);
 let late;const g=fixture(()=>new Promise(done=>{late=done;})),values=[];g.bridge.onCleanupNotice(value=>values.push(value))();late({ok:true,notices:[notice]});await settle();assert.equal(values.length,0);
});
test('only one bounded subscription is active; unsafe notices never invoke callback',async()=>{
 const f=fixture(),first=[],second=[];f.bridge.onCleanupNotice(value=>first.push(value));const dispose=f.bridge.onCleanupNotice(value=>second.push(value));assert.equal(f.ipc.listenerCount('reel:browse-preferences:notice:v1'),1);
 for(const value of[{...notice,path:'/tmp'},{...notice,code:'raw OS detail'},{...notice,count:100},{...notice,accountId:account.server}])f.ipc.emit('reel:browse-preferences:notice:v1',{},value);
 f.ipc.emit('reel:browse-preferences:notice:v1',{},notice);assert.equal(first.length,0);assert.equal(second.length,1);dispose();await settle();
});
