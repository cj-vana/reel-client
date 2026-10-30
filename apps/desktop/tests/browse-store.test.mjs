import {test}from'node:test';
import assert from'node:assert/strict';
import {mkdtemp,mkdir,readFile,writeFile,rm,readdir,chmod,symlink,link,rename,lstat,realpath}from'node:fs/promises';
import {tmpdir}from'node:os';
import {join}from'node:path';
import {setImmediate as settle}from'node:timers/promises';
import {BrowseStore,syncBrowseDirectory}from'../src/browse-store.mjs';
import {accountFilename,emptyDocument,byteRevision,MAX_DOCUMENT_BYTES}from'../src/browse-schema.mjs';
const account={server:'https://fixture.example/base',userId:'synthetic-a'};
const other={...account,userId:'synthetic-b'};
const doc=(who=account,view='grid')=>({...emptyDocument(who),entries:[{scope:{kind:'library',category:'All',libraryId:'',parentId:'',parentType:''},choices:{sort:'SortName',direction:'Ascending',genreId:'',watchStatus:'Any',favoritesOnly:false,view}}]});
async function fixture(run){const root=await realpath(await mkdtemp(join(tmpdir(),'reel-browse-store-')));try{await run(new BrowseStore(root),root);}finally{await rm(root,{recursive:true,force:true});}}
async function gateReady(ready,pending){let done=false;void pending.finally(()=>{done=true;}).catch(()=>{});const end=Date.now()+1000;while(!ready()){if(done)throw Error('Store completed before expected test gate');if(Date.now()>end)throw Error('Test gate deadline');await settle();}}
const path=(store,who=account)=>join(store.directory,accountFilename(who));
const save=async(store,who=account,value=doc(who))=>{const state=await store.open(who);assert.equal(state.ok,true);const result=await store.commit(who,state.revision,value);assert.equal(result.ok,true);return result;};
test('real file interface persists exact account document and byte revision across a fresh owner',async()=>fixture(async(store,root)=>{
 assert.deepEqual(await store.open(account),{ok:true,revision:'absent',document:emptyDocument(account)});
 const result=await save(store);assert.deepEqual(await new BrowseStore(root).open(account),{ok:true,revision:result.revision,document:doc()});
 assert.equal((await lstat(path(store))).mode&0o777,0o600);assert.equal((await lstat(store.directory)).mode&0o777,0o700);assert.deepEqual(await readdir(store.directory),[accountFilename(account)]);
}));
test('basepaths and users have separate host-derived files and reset preserves every sibling',async()=>fixture(async store=>{
 const baseOther={...account,server:'https://fixture.example/other'};const a=await save(store),b=await save(store,other),c=await save(store,baseOther);const bytes=await readFile(path(store,other));
 assert.deepEqual(await store.reset(account,a.revision),{ok:true,revision:'absent'});assert.deepEqual(await readFile(path(store,other)),bytes);assert.equal((await store.open(other)).revision,b.revision);assert.equal((await store.open(baseOther)).revision,c.revision);
}));
test('concurrent CAS serializes and stale expected bytes cannot overwrite the winning document',async()=>fixture(async store=>{
 const [a,b]=await Promise.all([store.commit(account,'absent',doc()),store.commit(account,'absent',doc(account,'list'))]);assert.equal(a.ok,true);assert.deepEqual(b,{ok:false,code:'conflict'});assert.deepEqual((await store.open(account)).document,doc());
}));
test('old account context after delayed preparation cannot rename and its exact temporary is removed',async()=>fixture(async store=>{
 let release,current=true;store.beforeCommit=()=>new Promise(done=>{release=done;});const saving=store.commit(account,'absent',doc(),()=>current);await gateReady(()=>release,saving);current=false;release();assert.deepEqual(await saving,{ok:false,code:'stale'});assert.deepEqual(await readdir(store.directory),[]);
}));
test('external byte revision change during staged preparation returns conflict and preserves changed file',async()=>fixture(async store=>{
 const old=await save(store);let release;store.beforeCommit=()=>new Promise(done=>{release=done;});const saving=store.commit(account,old.revision,doc(account,'list'));await gateReady(()=>release,saving);const changed=Buffer.from(JSON.stringify(emptyDocument(account)));await writeFile(path(store),changed);release();assert.deepEqual(await saving,{ok:false,code:'conflict'});assert.deepEqual(await readFile(path(store)),changed);
}));
test('same-size staged-byte corruption is rejected before rename and original data survives',async()=>fixture(async store=>{
 const first=await save(store);store.beforeCommit=async()=>{const name=(await readdir(store.directory)).find(name=>name.startsWith('.pending-'));const target=join(store.directory,name),bytes=await readFile(target);bytes[bytes.length-2]^=1;await writeFile(target,bytes);};
 assert.deepEqual(await store.commit(account,first.revision,doc(account,'list')),{ok:false,code:'preserved'});assert.deepEqual((await store.open(account)).document,doc());assert.equal((await readdir(store.directory)).some(name=>name.startsWith('.pending-')),false);
}));
test('pre-rename directory sync failure leaves old bytes and CAS writable for an explicit retry',async()=>fixture(async store=>{
 const first=await save(store),before=await readFile(path(store));store.directorySync=()=>{throw Error('synthetic private path must not escape');};assert.deepEqual(await store.commit(account,first.revision,doc(account,'list')),{ok:false,code:'io'});assert.deepEqual(await readFile(path(store)),before);store.directorySync=syncBrowseDirectory;assert.equal((await store.commit(account,first.revision,doc(account,'list'))).ok,true);
}));
test('post-rename failure remains uncertain in the same owner and reconciles only with a fresh owner',async()=>fixture(async(store,root)=>{
 const first=await save(store);store.directorySync=(directory,phase)=>{syncBrowseDirectory(directory);if(phase==='after')throw Error('synthetic metadata failure');return'synced';};assert.deepEqual(await store.commit(account,first.revision,doc(account,'list')),{ok:false,code:'uncertain'});
 assert.deepEqual(await store.open(account),{ok:false,code:'uncertain',canReset:false});assert.deepEqual(await store.reset(account,first.revision),{ok:false,code:'uncertain'});assert.deepEqual((await new BrowseStore(root).open(account)).document,doc(account,'list'));
}));
test('small attributed own corrupt/future documents require explicit reset while commit refuses overwrite',async()=>fixture(async store=>{
 await store.open(account);
 for(const schema of[1,2]){const bytes=Buffer.from(JSON.stringify({schema,account,entries:'bad'}));await writeFile(path(store),bytes,{mode:0o600});const state=await store.open(account);assert.equal(state.canReset,true);assert.equal(state.code,schema===1?'corrupt':'unsupported');assert.deepEqual(await store.commit(account,state.revision,doc()),{ok:false,code:'corrupt'});assert.deepEqual(await readFile(path(store)),bytes);assert.deepEqual(await store.reset(account,state.revision),{ok:true,revision:'absent'});}
}));
test('foreign malformed oversized and unattributed bytes cannot be overwritten or reset',async()=>fixture(async store=>{
 await store.open(account);
 for(const bytes of[Buffer.from(JSON.stringify(doc(other))),Buffer.from('{bad'),Buffer.from('{}'),Buffer.alloc(MAX_DOCUMENT_BYTES+1,32)]){await writeFile(path(store),bytes,{mode:0o600});assert.deepEqual(await store.open(account),{ok:false,code:'preserved',canReset:false});assert.deepEqual(await store.reset(account,byteRevision(bytes)),{ok:false,code:'preserved'});assert.deepEqual(await readFile(path(store)),bytes);}
}));
test('symbolic and hard linked account leaves and foreign directory entries are preserved',async()=>fixture(async(store,root)=>{
 await store.open(account);const external=join(root,'outside');await writeFile(external,JSON.stringify(doc()),{mode:0o600});await symlink(external,path(store));assert.deepEqual(await store.open(account),{ok:false,code:'preserved',canReset:false});assert.deepEqual(await readFile(external),Buffer.from(JSON.stringify(doc())));await rm(path(store));await link(external,path(store));assert.deepEqual(await store.open(account),{ok:false,code:'preserved',canReset:false});await rm(path(store));await writeFile(join(store.directory,'foreign.txt'),'keep',{mode:0o600});assert.deepEqual(await store.commit(account,'absent',doc()),{ok:false,code:'preserved'});assert.equal(await readFile(join(store.directory,'foreign.txt'),'utf8'),'keep');
}));
test('unsafe permissions and replaced directory are refused; restoring permissions permits read retry',async()=>fixture(async store=>{
 await save(store);await chmod(path(store),0o400);assert.deepEqual(await store.open(account),{ok:false,code:'preserved',canReset:false});await chmod(path(store),0o600);assert.equal((await store.open(account)).ok,true);await chmod(store.directory,0o500);assert.deepEqual(await store.open(account),{ok:false,code:'preserved',canReset:false});await chmod(store.directory,0o700);assert.equal((await store.open(account)).ok,true);await rename(store.directory,store.directory+'-retained');await mkdir(store.directory,{mode:0o700});assert.deepEqual(await store.open(account),{ok:false,code:'preserved',canReset:false});assert.equal((await readFile(join(store.directory+'-retained',accountFilename(account)),'utf8')).includes('synthetic-a'),true);
}));
test('account count cap refuses a new account and keeps all bounded sibling files',async()=>fixture(async store=>{
 await store.open(account);for(let i=0;i<32;i++){const who={...account,userId:'limit-'+i};await writeFile(path(store,who),JSON.stringify(emptyDocument(who)),{mode:0o600});}assert.deepEqual(await store.commit(account,'absent',doc()),{ok:false,code:'limit'});assert.equal((await readdir(store.directory)).length,32);
}));
test('host removal authority checks current absence and never touches disk for a stale context',async()=>fixture(async(store,root)=>{
 assert.deepEqual(await store.removeCommittedAccount(account,()=>false),{ok:false,code:'stale'});await assert.rejects(lstat(store.directory),{code:'ENOENT'});const first=await save(store);assert.deepEqual(await store.removeCommittedAccount(account,()=>false),{ok:false,code:'stale'});assert.equal((await store.open(account)).revision,first.revision);assert.deepEqual(await store.removeCommittedAccount(account,()=>true),{ok:true,revision:'absent'});
}));
test('a trusted system tmpdir alias canonicalizes an owned parent while an actual parent symlink is refused',async()=>{
 const raw=await mkdtemp(join(tmpdir(),'reel-browse-alias-'));try{
  const canonical=await realpath(raw),store=new BrowseStore(raw);assert.equal((await store.open(account)).ok,true);assert.equal(store.parent,canonical);
  const linked=join(raw,'linked-parent'),target=join(raw,'separate');await mkdir(target,{mode:0o700});await symlink(target,linked);assert.deepEqual(await new BrowseStore(linked).open(account),{ok:false,code:'preserved',canReset:false});assert.deepEqual(await readdir(target),[]);
 }finally{await rm(raw,{recursive:true,force:true});}
});
