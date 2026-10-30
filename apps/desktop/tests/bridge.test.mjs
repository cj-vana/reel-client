import {test} from 'node:test';
import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {randomBytes,createCipheriv,createDecipheriv} from 'node:crypto';
import {setImmediate as settle} from 'node:timers/promises';
import {installBridge,CHANNEL} from '../src/bridge.mjs';
import {DesktopStore,syncDirectory} from '../src/store.mjs';
import {APP_URL} from '../src/policy.mjs';
const account={id:'https://jellyfin.example.com|bridge',server:'https://jellyfin.example.com',token:'synthetic-bridge-only',userId:'bridge',name:'Bridge',serverName:'Fixture',remember:true};
const value={expectedRevision:0,accounts:[account],activeId:account.id};
function windowFixture(store){
 const window=new EventEmitter(),contents=new EventEmitter(),handlers=new Map(),messages=[];
 window.webContents=contents;window.isDestroyed=()=>window.destroyed===true;contents.isDestroyed=()=>false;contents.mainFrame={url:APP_URL};contents.send=(channel,nonce)=>messages.push({channel,nonce});
 const ipc={handle:(channel,handler)=>handlers.set(channel,handler),removeHandler:channel=>handlers.delete(channel)};
 const bridge=installBridge(window,store,ipc),owned={sender:contents,senderFrame:contents.mainFrame};
 return{window,contents,bridge,messages,owned,invoke:(message,event=owned)=>handlers.get(CHANNEL)(event,message),close:()=>{window.destroyed=true;window.emit('closed');}};
}
function fakeStore(){return{initialize:async()=>{},drain:async()=>{},snapshot:()=>({ok:true,storeState:'ready',revision:0}),saveConnections:async(_value,context)=>context()?{ok:true,revision:1}:{ok:false,code:'closing'},savePreferences:async()=>({ok:true,revision:1})};}
async function withStore(run){const root=await mkdtemp(join(tmpdir(),'reel-bridge-')),key=randomBytes(32),provider={
 available:async()=>true,
 encrypt:async text=>{const iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',key,iv),bytes=Buffer.concat([cipher.update(text,'utf8'),cipher.final()]);return Buffer.concat([iv,cipher.getAuthTag(),bytes]);},
 decrypt:async bytes=>{const cipher=createDecipheriv('aes-256-gcm',key,bytes.subarray(0,12));cipher.setAuthTag(bytes.subarray(12,28));return Buffer.concat([cipher.update(bytes.subarray(28)),cipher.final()]).toString();}
 };
 const directory=join(root,'store'),store=new DesktopStore(directory,provider);try{await store.initialize();await run(store,provider,directory);}finally{await rm(root,{recursive:true,force:true});}}
test('fixed bridge accepts only owned main-frame documents and exact operation shapes',async()=>{
 const f=windowFixture(fakeStore());assert.equal((await f.invoke({operation:'initialize'})).ok,true);
 for(const event of [{sender:{},senderFrame:f.contents.mainFrame},{sender:f.contents,senderFrame:{url:APP_URL}},{sender:f.contents,senderFrame:{url:'https://foreign.invalid/'}}])assert.deepEqual(await f.invoke({operation:'initialize'},event),{ok:false,code:'invalid'});
 for(const message of [null,[],{}, {operation:'initialize',extra:true},{operation:'fetch',value:'https://foreign.invalid/'}])assert.deepEqual(await f.invoke(message),{ok:false,code:'invalid'});
 f.contents.mainFrame.url='reel://app/other.html';assert.deepEqual(await f.invoke({operation:'initialize'}),{ok:false,code:'invalid'});f.close();
});
test('bridge normalizes rejected native work to a safe Result rather than thrown Error details',async()=>{const store=fakeStore();store.initialize=async()=>{throw Error('synthetic private detail');};const f=windowFixture(store);assert.deepEqual(await f.invoke({operation:'initialize'}),{ok:false,code:'io'});f.close();});
test('real store post-crypto fence rejects a same-URL reload through the bridge epoch',async()=>withStore(async(store,provider,dir)=>{
 const f=windowFixture(store);let release;const encrypt=provider.encrypt;provider.encrypt=async text=>{await new Promise(done=>{release=done;});return encrypt(text);};
 const saving=f.invoke({operation:'saveConnections',value});while(!release)await settle();f.contents.emit('did-start-navigation',{},APP_URL,false,true);release();assert.deepEqual(await saving,{ok:false,code:'closing'});assert.equal((await f.invoke({operation:'initialize'})).revision,0);await assert.rejects(readFile(join(dir,'connections.vault')),{code:'ENOENT'});f.close();
}));
test('initialize drains accepted writes and returns the current authoritative revision',async()=>withStore(async store=>{const f=windowFixture(store),saving=f.invoke({operation:'saveConnections',value}),initializing=f.invoke({operation:'initialize'});assert.deepEqual(await saving,{ok:true,revision:1});assert.equal((await initializing).revision,1);f.close();}));
test('one close nonce and Promise include store drain; duplicate and stale acknowledgements cannot bypass it',async()=>{
 const store=fakeStore();let release;store.drain=()=>new Promise(done=>{release=done;});const f=windowFixture(store),first=f.bridge.requestClose();assert.equal(f.bridge.requestClose(),first);assert.equal(f.messages.length,1);
 const nonce=f.messages[0].nonce;assert.deepEqual(await f.invoke({operation:'acknowledgeClose',nonce:'wrong'}),{ok:false,code:'invalid'});assert.deepEqual(await f.invoke({operation:'saveConnections',value}),{ok:false,code:'closing'});
 assert.deepEqual(await f.invoke({operation:'acknowledgeClose',nonce}),{ok:true});assert.deepEqual(await f.invoke({operation:'acknowledgeClose',nonce}),{ok:false,code:'invalid'});assert.equal(f.bridge.requestClose(),first);assert.deepEqual(await f.invoke({operation:'savePreferences',value:{}}),{ok:false,code:'closing'});let completed=false;void first.then(()=>{completed=true;});await settle();assert.equal(completed,false);release();await first;f.close();
});
test('navigation invalidates a pending close nonce and closing the window releases the wait',async()=>{const f=windowFixture(fakeStore()),waiting=f.bridge.requestClose(),nonce=f.messages[0].nonce;f.contents.emit('did-start-navigation',{},APP_URL,false,true);assert.deepEqual(await f.invoke({operation:'acknowledgeClose',nonce}),{ok:false,code:'invalid'});f.close();await waiting;});
test('process-owned uncertainty survives last-window close and a replacement bridge until a fresh owner reopens disk',async()=>withStore(async(store,provider,dir)=>{
 store.directorySync=(directory,phase)=>{syncDirectory(directory);if(phase==='after')throw Error('Synthetic metadata failure');};
 const first=windowFixture(store);assert.deepEqual(await first.invoke({operation:'saveConnections',value}),{ok:false,code:'uncertain'});const bytes=await readFile(join(dir,'connections.vault'));first.close();
 const replacement=windowFixture(store);assert.deepEqual(await replacement.invoke({operation:'initialize'}),{ok:false,code:'uncertain'});assert.deepEqual(await replacement.invoke({operation:'saveConnections',value}),{ok:false,code:'uncertain'});assert.deepEqual(await readFile(join(dir,'connections.vault')),bytes);replacement.close();
 const restarted=await new DesktopStore(dir,provider).initialize();assert.equal(restarted.revision,1);assert.equal(restarted.savedConnections.accounts[0].token,account.token);
}));
