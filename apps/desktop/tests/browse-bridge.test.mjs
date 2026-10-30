import {test}from'node:test';
import assert from'node:assert/strict';
import {EventEmitter}from'node:events';
import {mkdtemp,realpath,rm,readFile,lstat,writeFile}from'node:fs/promises';
import {join}from'node:path';
import {tmpdir}from'node:os';
import {setImmediate as settle}from'node:timers/promises';
import {BrowseOwner}from'../src/browse-owner.mjs';
import {installBrowseBridge,BROWSE_CHANNEL,BROWSE_NOTICE_CHANNEL}from'../src/browse-bridge.mjs';
import {installBridge,CHANNEL}from'../src/bridge.mjs';
import {APP_URL}from'../src/policy.mjs';
import {emptyDocument,accountFilename}from'../src/browse-schema.mjs';
const a={server:'https://fixture.example/base',userId:'a'},b={...a,userId:'b'};
const credential=account=>({id:account.server+'|'+account.userId,...account,token:'synthetic-private-token',name:'Synthetic',serverName:'Fixture',remember:true});
function credentials(accounts=[],state='ready'){
 return{accounts:accounts.map(credential),state,revision:0,initializations:0,writes:0,
 snapshot(){return{ok:true,storeState:this.state,revision:this.revision,...(this.state==='ready'?{savedConnections:{accounts:this.accounts,activeId:this.accounts[0]?.id??null}}:{})};},
 async initialize(){this.initializations++;return this.snapshot();},async drain(){},async saveConnections(value,context){this.writes++;if(!context())return{ok:false,code:'closing'};if(this.state!=='ready')return{ok:false,code:this.state};if(value.expectedRevision!==this.revision)return{ok:false,code:'conflict'};this.accounts=structuredClone(value.accounts);return{ok:true,revision:++this.revision};},async savePreferences(){return{ok:true,revision:1};}};
}
function windowFor(owner){
 const window=new EventEmitter(),contents=new EventEmitter(),handlers=new Map(),messages=[];window.webContents=contents;window.isDestroyed=()=>!!window.destroyed;contents.isDestroyed=()=>false;contents.mainFrame={url:APP_URL};contents.send=(channel,value)=>messages.push({channel,value});
 const ipc={handle:(channel,handle)=>{assert.equal(handlers.has(channel),false);handlers.set(channel,handle);},removeHandler:channel=>handlers.delete(channel)};
 const bridge=installBrowseBridge(window,owner,ipc),event={sender:contents,senderFrame:contents.mainFrame};
 return{window,contents,bridge,ipc,handlers,event,messages,invoke:(message,who=event)=>handlers.get(BROWSE_CHANNEL)(who,message),close:()=>{window.destroyed=true;window.emit('closed');},navigation:()=>contents.emit('did-start-navigation',{},APP_URL,false,true)};
}
async function fixture(accounts,run,state='ready'){
 const root=await realpath(await mkdtemp(join(tmpdir(),'reel-browse-bridge-'))),store=credentials(accounts,state),owner=new BrowseOwner(root,store);try{await run(owner,store,root);}finally{for(const session of owner.windows)session.dispose();await owner.drain();await rm(root,{recursive:true,force:true});}
}
const open=(f,account=a,generation=0)=>f.invoke({operation:'open',account,generation});
const commit=(f,snapshot,document=emptyDocument(a))=>f.invoke({operation:'commit',lease:snapshot.lease,expectedRevision:snapshot.revision,document});
const conn=(store,accounts)=>({expectedRevision:store.revision,accounts,activeId:accounts[0]?.id??null});
test('strict owned frame and exact operation shapes reject unknown paths,keys and credentials',async()=>fixture([],async owner=>{
 const f=windowFor(owner);
 for(const event of[{sender:{},senderFrame:f.contents.mainFrame},{sender:f.contents,senderFrame:{url:APP_URL}},{sender:f.contents,senderFrame:{url:'https://foreign.invalid/'}}])assert.equal((await open({...f,invoke:m=>f.invoke(m,event)})).code,'invalid');
 for(const message of[null,[],{}, {operation:'notices',extra:true},{operation:'open',account:{...a,token:'no'},generation:0},{operation:'revoke',generation:NaN},{operation:'reset',lease:'/tmp/file',expectedRevision:'absent'}])assert.equal((await f.invoke(message)).code,'invalid');
 f.close();assert.equal(owner.windows.size,0);assert.equal(owner.listeners.size,0);assert.equal(f.handlers.has(BROWSE_CHANNEL),false);
}));
test('only ready genuinely remembered identities get device retention; unavailable states do no browse I/O',async()=>{
 await fixture([a],async(owner,store,root)=>{const f=windowFor(owner);assert.equal((await open(f)).retention,'device');assert.equal(store.initializations,0);f.close();});
 for(const state of['locked','corrupt','unavailable'])await fixture([a],async(owner,store,root)=>{const f=windowFor(owner),snapshot=await open(f);assert.equal(snapshot.retention,'session');assert.equal((await commit(f,snapshot)).ok,true);assert.equal(store.initializations,0);await assert.rejects(lstat(join(root,'browse-preferences')),{code:'ENOENT'});f.close();},state);
});
test('session retention survives same-window account switches but loses data at window recreation with no disk',async()=>fixture([],async(owner,store,root)=>{
 const f=windowFor(owner),first=await open(f),document=emptyDocument(a);const saved=await commit(f,first,document);assert.equal(saved.ok,true);await open(f,b,1);const back=await open(f,a,2);assert.equal(back.revision,saved.revision);f.close();const next=windowFor(owner);assert.equal((await open(next)).revision,'absent');await assert.rejects(lstat(join(root,'browse-preferences')),{code:'ENOENT'});next.close();
}));
test('new generation revokes old authority immediately even while its device write awaits preparation',async()=>fixture([a,b],async owner=>{
 const f=windowFor(owner),first=await open(f);let release;owner.disk.beforeCommit=()=>new Promise(done=>{release=done;});const writing=commit(f,first);const end=Date.now()+1000;while(!release){assert.ok(Date.now()<end);await settle();}
 const second=open(f,b,1);release();assert.deepEqual(await writing,{ok:false,code:'stale'});assert.equal((await second).document.account.userId,'b');assert.equal((await open(f,a,2)).revision,'absent');f.close();
}));
test('Home activation then no-active revoke rejects old session lease and performs no disk work',async()=>fixture([],async(owner,store,root)=>{
 const f=windowFor(owner),first=await open(f);assert.deepEqual(await f.invoke({operation:'revoke',generation:1}),{ok:true});assert.deepEqual(await commit(f,first),{ok:false,code:'stale'});assert.equal((await open(f,a,0)).code,'stale');await assert.rejects(lstat(join(root,'browse-preferences')),{code:'ENOENT'});f.close();
}));
test('navigation/close fences queued work and close drain includes already accepted work',async()=>fixture([a],async owner=>{
 const f=windowFor(owner),first=await open(f);f.navigation();assert.deepEqual(await commit(f,first),{ok:false,code:'stale'});const fresh=await open(f,a,0);assert.equal(fresh.ok,true);const drain=f.bridge.beginClose();assert.equal((await open(f,a,1)).code,'closing');await drain;f.close();
}));
test('successful reset consumes even absent lease and queued old patches cannot undo reset',async()=>fixture([],async owner=>{
 const f=windowFor(owner),first=await open(f);const reset=f.invoke({operation:'reset',lease:first.lease,expectedRevision:first.revision}),old=commit(f,first);assert.deepEqual(await reset,{ok:true,revision:'absent'});assert.deepEqual(await old,{ok:false,code:'stale'});const fresh=await open(f,a,1);assert.equal(fresh.revision,'absent');f.close();
}));
test('inactive session removal reset/reactivate flow means same-window re-add starts empty',async()=>fixture([],async owner=>{
 const f=windowFor(owner),first=await open(f);assert.equal((await commit(f,first)).ok,true);await open(f,b,1);const removed=await open(f,a,2);assert.equal(removed.retention,'session');assert.equal((await f.invoke({operation:'reset',lease:removed.lease,expectedRevision:removed.revision})).ok,true);await open(f,b,3);assert.equal((await open(f,a,4)).revision,'absent');f.close();
}));
test('only successful authoritative Connections removal runs cleanup; failed commit preserves file',async()=>fixture([a,b],async(owner,store)=>{
 const f=windowFor(owner),first=await open(f);await commit(f,first);const target=join(owner.disk.directory,accountFilename(a)),bytes=await readFile(target);
 assert.equal((await owner.commitConnections({...conn(store,[credential(b)]),expectedRevision:9},()=>true)).code,'conflict');assert.deepEqual(await readFile(target),bytes);
 assert.deepEqual(await owner.commitConnections(conn(store,[credential(b)]),()=>true),{ok:true,revision:1});await assert.rejects(readFile(target),{code:'ENOENT'});assert.deepEqual(await commit(f,first),{ok:false,code:'stale'});f.close();
}));
test('normalized identity SET difference preserves choices while any valid saved URL alias remains',async()=>fixture([a],async(owner,store)=>{
 const alias={...a,server:'https://FIXTURE.example:443/base'},f=windowFor(owner);store.accounts=[credential(a),credential(alias)];const first=await open(f);await commit(f,first);const target=join(owner.disk.directory,accountFilename(a)),bytes=await readFile(target);
 assert.deepEqual(await owner.commitConnections(conn(store,[credential(alias)]),()=>true),{ok:true,revision:1});assert.deepEqual(await readFile(target),bytes);assert.equal(owner.isRemembered(a),true);
 assert.deepEqual(await owner.commitConnections(conn(store,[]),()=>true),{ok:true,revision:2});await assert.rejects(readFile(target),{code:'ENOENT'});f.close();
}));
test('post-cleanup failure preserves committed signout and exposes bounded opaque initial/live notice',async()=>fixture([a],async(owner,store)=>{
 const f=windowFor(owner),first=await open(f);await commit(f,first);const target=join(owner.disk.directory,accountFilename(a));await writeFile(target,'foreign-unattributed',{mode:0o600});
 assert.deepEqual(await owner.commitConnections(conn(store,[]),()=>true),{ok:true,revision:1});assert.equal(store.accounts.length,0);assert.equal(await readFile(target,'utf8'),'foreign-unattributed');
 const notice=f.messages.find(row=>row.channel===BROWSE_NOTICE_CHANNEL).value;assert.deepEqual(Object.keys(notice).sort(),['accountId','code','count','id']);assert.equal(notice.code,'preserved');assert.equal(JSON.stringify(notice).includes(a.server),false);assert.equal(JSON.stringify(notice).includes('synthetic-private-token'),false);assert.deepEqual((await f.invoke({operation:'notices'})).notices,[notice]);
 for(let i=0;i<20;i++)owner.notice(a,'io');assert.equal((await f.invoke({operation:'notices'})).notices.length,16);f.close();
}));
test('legacy credential bridge operations/results stay exact while close revokes browse first and drains it',async()=>fixture([a],async(owner,store)=>{
 const f=windowFor(owner);const legacy=installBridge(f.window,store,f.ipc,{saveConnections:(value,context)=>owner.commitConnections(value,context),closeResources:()=>f.bridge.beginClose()});const first=await open(f);
 const saving=f.handlers.get(CHANNEL)(f.event,{operation:'saveConnections',value:conn(store,[])});assert.deepEqual(await saving,{ok:true,revision:1});
 const closing=legacy.requestClose();assert.equal((await commit(f,first)).code,'closing');const nonce=f.messages.find(row=>row.channel==='reel:close:v1').value;assert.deepEqual(await f.handlers.get(CHANNEL)(f.event,{operation:'acknowledgeClose',nonce}),{ok:true});await closing;f.close();assert.equal(f.handlers.size,0);
}));
test('session retention never silently upgrades and device authority is lost when secure memory is unavailable',async()=>fixture([],async(owner,store,root)=>{
 const f=windowFor(owner),session=await open(f);store.accounts=[credential(a)];assert.equal((await commit(f,session)).ok,true);await assert.rejects(lstat(join(root,'browse-preferences')),{code:'ENOENT'});
 const device=await open(f,a,1);assert.equal(device.retention,'device');assert.equal(device.revision,'absent');store.state='locked';assert.deepEqual(await commit(f,device),{ok:false,code:'stale'});f.close();
}));
test('session account quota is enforced without eviction or disk fallback',async()=>fixture([],async(owner,store,root)=>{
 const f=windowFor(owner);for(let i=0;i<16;i++){const who={...a,userId:'session-'+i},state=await open(f,who,i);assert.equal((await commit(f,state,emptyDocument(who))).ok,true);}
 const overflow={...a,userId:'session-overflow'},state=await open(f,overflow,16);assert.deepEqual(await commit(f,state,emptyDocument(overflow)),{ok:false,code:'limit'});assert.notEqual((await open(f,{...a,userId:'session-0'},17)).revision,'absent');await assert.rejects(lstat(join(root,'browse-preferences')),{code:'ENOENT'});f.close();
}));
test('beginClose immediately revokes a prepared device write and resolves drain only after its cleanup',async()=>fixture([a],async owner=>{
 const f=windowFor(owner),state=await open(f);let release;owner.disk.beforeCommit=()=>new Promise(done=>{release=done;});const saving=commit(f,state);const end=Date.now()+1000;while(!release){assert.ok(Date.now()<end);await settle();}
 let drained=false;const closing=f.bridge.beginClose().then(()=>{drained=true;});await settle();assert.equal(drained,false);release();assert.deepEqual(await saving,{ok:false,code:'stale'});await closing;assert.equal(drained,true);assert.equal((await owner.disk.open(a)).revision,'absent');f.close();
}));
test('actual credential store aliases retain shared preferences until the last authoritative alias removal',async()=>{
 const{DesktopStore}=await import('../src/store.mjs');const{randomBytes,createCipheriv,createDecipheriv}=await import('node:crypto');const root=await realpath(await mkdtemp(join(tmpdir(),'reel-browse-real-credentials-'))),key=randomBytes(32);let availabilityCalls=0;
 const provider={available:async()=>{availabilityCalls++;return true;},encrypt:async text=>{const iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',key,iv),bytes=Buffer.concat([cipher.update(text,'utf8'),cipher.final()]);return Buffer.concat([iv,cipher.getAuthTag(),bytes]);},decrypt:async bytes=>{const cipher=createDecipheriv('aes-256-gcm',key,bytes.subarray(0,12));cipher.setAuthTag(bytes.subarray(12,28));return Buffer.concat([cipher.update(bytes.subarray(28)),cipher.final()]).toString();}};
 try{const secure=new DesktopStore(join(root,'secure-store'),provider);await secure.initialize();const alias={...a,server:'https://FIXTURE.example:443/base'},accounts=[credential(a),credential(alias)];assert.deepEqual(await secure.saveConnections({expectedRevision:0,accounts,activeId:accounts[0].id},()=>true),{ok:true,revision:1});
  const owner=new BrowseOwner(root,secure),f=windowFor(owner),beforeVault=await readFile(join(root,'secure-store/connections.vault')),state=await open(f);assert.equal(state.retention,'device');assert.equal((await commit(f,state)).ok,true);assert.deepEqual(await readFile(join(root,'secure-store/connections.vault')),beforeVault);assert.equal(availabilityCalls,1);
  const target=join(owner.disk.directory,accountFilename(a)),bytes=await readFile(target);assert.deepEqual(await owner.commitConnections({expectedRevision:9,accounts:[],activeId:null},()=>true),{ok:false,code:'conflict'});assert.deepEqual(await readFile(target),bytes);
  assert.deepEqual(await owner.commitConnections({expectedRevision:1,accounts:[accounts[1]],activeId:accounts[1].id},()=>true),{ok:true,revision:2});assert.deepEqual(await readFile(target),bytes);assert.equal(owner.isRemembered(a),true);
  assert.deepEqual(await owner.commitConnections({expectedRevision:2,accounts:[],activeId:null},()=>true),{ok:true,revision:3});await assert.rejects(readFile(target),{code:'ENOENT'});f.close();await owner.drain();assert.equal(availabilityCalls,1);
 }finally{await rm(root,{recursive:true,force:true});}
});

test('quarantined secure-store snapshot grants only session retention without initialization or disk access',async()=>fixture([a],async(owner,store,root)=>{
 store.snapshot=()=>({ok:false,code:'uncertain'});const f=windowFor(owner),state=await open(f);assert.equal(state.retention,'session');assert.equal((await commit(f,state)).ok,true);assert.equal(store.initializations,0);await assert.rejects(lstat(join(root,'browse-preferences')),{code:'ENOENT'});f.close();
}));
test('session CAS rejects a second stale write and keeps the first acknowledged bytes',async()=>fixture([],async owner=>{
 const f=windowFor(owner),state=await open(f),[first,second]=await Promise.all([commit(f,state),commit(f,state)]);assert.equal(first.ok,true);assert.deepEqual(second,{ok:false,code:'conflict'});assert.equal((await open(f,a,1)).revision,first.revision);f.close();
}));
test('unknown credential commit outcome never grants preference removal authority',async()=>fixture([a],async(owner,store)=>{
 const f=windowFor(owner),state=await open(f);await commit(f,state);const target=join(owner.disk.directory,accountFilename(a)),before=await readFile(target);store.saveConnections=async()=>({ok:false,code:'uncertain'});
 assert.deepEqual(await owner.commitConnections(conn(store,[]),()=>true),{ok:false,code:'uncertain'});assert.deepEqual(await readFile(target),before);assert.deepEqual(owner.snapshotNotices(),[]);f.close();
}));
test('a thrown post-commit cleanup error is sanitized and cannot roll back successful signout',async()=>fixture([a],async(owner,store)=>{
 const f=windowFor(owner);owner.disk.removeCommittedAccount=async()=>{throw Error('/private/forbidden synthetic-private-token');};assert.deepEqual(await owner.commitConnections(conn(store,[]),()=>true),{ok:true,revision:1});const notice=owner.snapshotNotices()[0];assert.equal(notice.code,'io');assert.equal(JSON.stringify(notice).includes('private'),false);assert.equal(store.accounts.length,0);f.close();
}));
test('fresh authoritative re-add immediately before unlink preserves the account preference file',async()=>fixture([a],async(owner,store)=>{
 const f=windowFor(owner),state=await open(f);await commit(f,state);const target=join(owner.disk.directory,accountFilename(a)),before=await readFile(target);owner.disk.directorySync=(_directory,phase)=>{if(phase==='before')store.accounts=[credential(a)];return'synced';};
 assert.deepEqual(await owner.commitConnections(conn(store,[]),()=>true),{ok:true,revision:1});assert.deepEqual(await readFile(target),before);assert.equal(owner.isRemembered(a),true);assert.deepEqual(owner.snapshotNotices(),[]);f.close();
}));
