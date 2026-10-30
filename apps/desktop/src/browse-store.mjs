import {mkdir,open}from'node:fs/promises';
import {lstatSync,realpathSync,readdirSync,openSync,readSync,fstatSync,closeSync,fsyncSync,renameSync,unlinkSync,constants}from'node:fs';
import {resolve,join}from'node:path';
import {randomUUID}from'node:crypto';
import {validAccount,validDocument,validRevision,accountFilename,classifyBytes,byteRevision,MAX_DOCUMENT_BYTES}from'./browse-schema.mjs';
const MAX_ACCOUNTS=32,MAX_TOTAL_BYTES=16777216;
const fail=code=>({ok:false,code});
class BrowseFault extends Error{constructor(code){super(code);this.code=code;}}
const fault=code=>{throw new BrowseFault(code);};
const signature=info=>[info.dev,info.ino,info.uid,info.mode,info.nlink,info.size,info.mtimeMs,info.ctimeMs].join(':');
const sameNode=(a,b)=>a.dev===b.dev&&a.ino===b.ino&&a.uid===b.uid;
function owned(info,directory=false){
 if(!info||info.isSymbolicLink()||!(directory?info.isDirectory():info.isFile())||process.getuid&&info.uid!==process.getuid()||!directory&&info.nlink!==1||process.platform!=='win32'&&(info.mode&0o777)!==(directory?0o700:0o600))fault('preserved');
 return info;
}
export function syncBrowseDirectory(directory){
 // No unsupported Windows metadata-durability success is invented.
 if(process.platform==='win32')return'platform-unverified';
 const fd=openSync(directory,constants.O_RDONLY);try{fsyncSync(fd);}finally{closeSync(fd);}return'synced';
}
/** Noncredential storage only. Construction performs no I/O or secure-store call. */
export class BrowseStore{
 constructor(userData,{directorySync=syncBrowseDirectory,beforeCommit=async()=>{}}={}){
  this.inputParent=resolve(userData);this.parent=this.inputParent;this.directory=join(this.parent,'browse-preferences');this.directorySync=directorySync;this.beforeCommit=beforeCommit;
 }
 queue=Promise.resolve();parentNode=undefined;directoryNode=undefined;quarantined=new Set();
 enqueue(operation){const next=this.queue.then(operation,operation);this.queue=next.then(()=>undefined,()=>undefined);return next;}
 async drain(){await this.queue;}
 async prepare(context){
  if(!context())fault('stale');
  const parent=owned(lstatSync(this.inputParent),true),canonical=realpathSync(this.inputParent);
  if(this.parentNode&&(!sameNode(parent,this.parentNode)||canonical!==this.parent))fault('preserved');
  if(!this.parentNode){this.parent=canonical;this.directory=join(canonical,'browse-preferences');this.parentNode=parent;}
  try{await mkdir(this.directory,{mode:0o700});}catch(error){if(error.code!=='EEXIST')throw error;}
  this.checkDirectory();if(!context())fault('stale');this.inventory();
 }
 checkDirectory(){
  const supplied=owned(lstatSync(this.inputParent),true),parent=owned(lstatSync(this.parent),true);
  if(!sameNode(supplied,this.parentNode)||!sameNode(parent,this.parentNode)||realpathSync(this.inputParent)!==this.parent)fault('preserved');
  const info=owned(lstatSync(this.directory),true);if(realpathSync(this.directory)!==this.directory||this.directoryNode&&!sameNode(info,this.directoryNode))fault('preserved');this.directoryNode??=info;
 }
 inventory(temporary){
  this.checkDirectory();const leaves=new Map();let bytes=0;
  for(const name of readdirSync(this.directory)){
   const path=join(this.directory,name),info=owned(lstatSync(path));
   if(temporary&&name===temporary.name){if(!sameNode(info,temporary.node))fault('preserved');continue;}
   if(!/^[a-f0-9]{64}\.json$/.test(name)||info.size>MAX_DOCUMENT_BYTES)fault('preserved');leaves.set(name,info);bytes+=info.size;
  }
  if(leaves.size>MAX_ACCOUNTS||bytes>MAX_TOTAL_BYTES)fault('limit');return{leaves,bytes};
 }
 read(account){
  return this.readPath(join(this.directory,accountFilename(account)));
 }
 readPath(path){
  this.checkDirectory();let info;
  try{info=owned(lstatSync(path));}catch(error){if(error.code==='ENOENT')return{bytes:null,node:null,revision:'absent'};throw error;}
  if(info.size>MAX_DOCUMENT_BYTES)fault('preserved');
  let fd;try{
   fd=openSync(path,constants.O_RDONLY|(constants.O_NOFOLLOW??0));const before=owned(fstatSync(fd));if(signature(before)!==signature(info))fault('preserved');
   const buffer=Buffer.alloc(MAX_DOCUMENT_BYTES+1);let size=0;
   while(size<buffer.length){const length=readSync(fd,buffer,size,buffer.length-size,null);if(length===0)break;size+=length;}
   if(size>MAX_DOCUMENT_BYTES||signature(fstatSync(fd))!==signature(before)||signature(owned(lstatSync(path)))!==signature(before))fault('preserved');
   const bytes=buffer.subarray(0,size);return{bytes,node:before,revision:byteRevision(bytes)};
  }finally{if(fd!==undefined)closeSync(fd);}
 }
 async attempt(account,context,operation){
  try{await this.prepare(context);if(this.quarantined.has(accountFilename(account)))return fail('uncertain');return await operation();}
  catch(error){return fail(error instanceof BrowseFault?error.code:'io');}
 }
 open(account,context=()=>true){
  if(!validAccount(account))return Promise.resolve({...fail('invalid'),canReset:false});const identity={...account};
  return this.enqueue(()=>this.attempt(identity,context,()=>{const saved=this.read(identity);if(!context())fault('stale');return classifyBytes(saved.bytes,identity);})).then(result=>result.ok?result:{...result,canReset:result.canReset===true});
 }
 commit(account,expectedRevision,document,context=()=>true){
  if(!validAccount(account)||!validRevision(expectedRevision)||!validDocument(document,account))return Promise.resolve(fail('invalid'));
  const identity={...account},bytes=Buffer.from(JSON.stringify(document));
  return this.enqueue(()=>this.attempt(identity,context,async()=>{
   const initial=this.read(identity);if(initial.revision!==expectedRevision)return fail('conflict');
   const classified=classifyBytes(initial.bytes,identity);if(!classified.ok)return fail(classified.code==='preserved'?'preserved':'corrupt');
   const name='.pending-'+randomUUID(),path=join(this.directory,name);let handle,node,renamed=false;
   try{
    handle=await open(path,constants.O_WRONLY|constants.O_CREAT|constants.O_EXCL|(constants.O_NOFOLLOW??0),0o600);node=await handle.stat();owned(node);
    await handle.writeFile(bytes);await handle.sync();await handle.close();handle=undefined;
    await this.beforeCommit();
    const inventory=this.inventory({name,node});const target=accountFilename(identity);const previous=inventory.leaves.get(target);
    if(inventory.leaves.size+(previous?0:1)>MAX_ACCOUNTS||inventory.bytes-(previous?.size??0)+bytes.length>MAX_TOTAL_BYTES)return fail('limit');
    const current=this.read(identity);if(current.revision!==expectedRevision)return fail('conflict');
    const staged=this.readPath(path);if(!sameNode(staged.node,node)||staged.revision!==byteRevision(bytes))fault('preserved');
    if(this.directorySync(this.directory,'before')!=='synced')return fail('unavailable');
    if(!context())return fail('stale');
    // No JavaScript turn interleaves the final context/byte-CAS checks and rename.
    renameSync(path,join(this.directory,target));renamed=true;
    try{if(this.directorySync(this.directory,'after')!=='synced')throw Error('Unconfirmed directory metadata');}
    catch{this.quarantined.add(target);return fail('uncertain');}
    return{ok:true,revision:byteRevision(bytes)};
   }finally{
    await handle?.close().catch(()=>{});
    if(!renamed&&node){
     try{const current=lstatSync(path);if(current.isFile()&&!current.isSymbolicLink()&&current.nlink===1&&sameNode(current,node))unlinkSync(path);}catch(error){if(error.code!=='ENOENT'&&!(error instanceof BrowseFault))throw error;}
    }
   }
  }));
 }
 reset(account,expectedRevision,context=()=>true){
  if(!validAccount(account)||!validRevision(expectedRevision))return Promise.resolve(fail('invalid'));const identity={...account};
  return this.enqueue(()=>this.attempt(identity,context,()=>this.remove(identity,expectedRevision,context)));
 }
 remove(account,expectedRevision,context){
  const saved=this.read(account);if(saved.revision!==expectedRevision)return fail('conflict');const state=classifyBytes(saved.bytes,account);
  if(!state.ok&&!state.canReset)return fail('preserved');if(!context())return fail('stale');if(saved.bytes===null)return{ok:true,revision:'absent'};
  if(this.directorySync(this.directory,'before')!=='synced')return fail('unavailable');
  const current=this.read(account);if(current.revision!==expectedRevision)return fail('conflict');if(!context())return fail('stale');
  unlinkSync(join(this.directory,accountFilename(account)));
  try{if(this.directorySync(this.directory,'after')!=='synced')throw Error('Unconfirmed directory metadata');}
  catch{this.quarantined.add(accountFilename(account));return fail('uncertain');}
  return{ok:true,revision:'absent'};
 }
 /** Host-only authority: called after Connections commit; current absence is rechecked at unlink. */
 removeCommittedAccount(account,stillRemoved){
  if(!validAccount(account))return Promise.resolve(fail('invalid'));const identity={...account};
  return this.enqueue(()=>this.attempt(identity,stillRemoved,()=>{const current=this.read(identity);return this.remove(identity,current.revision,stillRemoved);}));
 }
}
