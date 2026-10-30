import {randomUUID}from'node:crypto';
import {BrowseStore}from'./browse-store.mjs';
import {validConnectionWrite}from'./store.mjs';
import {validAccount,normalizedAccount,sameAccount,accountKey,accountFilename,byteRevision,emptyDocument,validDocument}from'./browse-schema.mjs';
const fail=code=>({ok:false,code});
const clone=value=>structuredClone(value);
/** Process-owned noncredential policy; remembered identities are read from memory only. */
export class BrowseOwner{
 constructor(userData,credentialStore,options={}){this.credentials=credentialStore;this.disk=new BrowseStore(userData,options);}
 queue=Promise.resolve();windows=new Set();notices=[];listeners=new Set();
 enqueue(operation){const next=this.queue.then(operation,operation);this.queue=next.then(()=>undefined,()=>undefined);return next;}
 remembered(){
  const state=this.credentials.snapshot();
  if(!state.ok||state.storeState!=='ready'||!state.savedConnections)return{ready:false,accounts:[]};
  const identities=new Map();
  for(const value of state.savedConnections.accounts){if(value.remember!==true)continue;const account=normalizedAccount(value);if(account)identities.set(accountKey(account),account);}
  return{ready:true,accounts:[...identities.values()]};
 }
 isRemembered(account){const state=this.remembered();return state.ready&&state.accounts.some(value=>sameAccount(value,account));}
 createSession(){const session=new BrowseSession(this);this.windows.add(session);return session;}
 notice(account,code){
  const safeCode=['preserved','uncertain'].includes(code)?code:'io';const accountId=accountFilename(account).slice(0,-5);
  const notice={id:randomUUID(),accountId,count:1,code:safeCode};this.notices.push(notice);if(this.notices.length>16)this.notices.shift();
  for(const listener of this.listeners){try{listener(clone(notice));}catch{/* One disposed view cannot suppress another owner. */}}
 }
 snapshotNotices(){return clone(this.notices);}
 /** Only successful existing Connections commits grant removal authority. */
 commitConnections(value,context){
  if(!validConnectionWrite(value))return Promise.resolve(fail('invalid'));
  const input=clone(value);
  return this.enqueue(async()=>{
   await this.credentials.initialize();await this.credentials.drain();const before=this.remembered();
   const result=await this.credentials.saveConnections(input,context);if(!result.ok)return result;
   const after=this.remembered();
   if(before.ready&&after.ready){
    const removed=before.accounts.filter(account=>!after.accounts.some(value=>sameAccount(value,account)));
    for(const account of removed){
     for(const session of this.windows)session.forget(account);
     const stillRemoved=()=>{const state=this.remembered();return state.ready&&!state.accounts.some(value=>sameAccount(value,account));};
     try{const cleanup=await this.disk.removeCommittedAccount(account,stillRemoved);if(!cleanup.ok&&cleanup.code!=='stale')this.notice(account,cleanup.code);}
     catch{this.notice(account,'io');}
    }
   }
   // A later browse cleanup failure never changes a committed credential result.
   return result;
  });
 }
 async drain(){await this.queue;await this.disk.drain();}
}
export class BrowseSession{
 constructor(owner){this.owner=owner;}
 generation=-1;lease=null;closed=false;memory=new Map();
 advance(generation){if(this.closed)return fail('closing');if(generation<=this.generation)return fail('stale');this.generation=generation;this.lease=null;return{ok:true};}
 current(record,context){return!this.closed&&this.lease===record&&context()&&(record.retention!=='device'||this.owner.isRemembered(record.account));}
 forget(account){this.memory.delete(accountKey(account));if(this.lease&&sameAccount(this.lease.account,account))this.lease=null;}
 open(account,generation,context){
  const admitted=this.advance(generation);if(!admitted.ok)return Promise.resolve(admitted);
  const record={id:randomUUID(),account:{...account},retention:this.owner.isRemembered(account)?'device':'session'};this.lease=record;
  const current=()=>this.current(record,context);
  return this.owner.enqueue(async()=>{
   if(!current())return fail('stale');
   const state=record.retention==='device'?await this.owner.disk.open(record.account,current):{ok:true,revision:byteRevision(this.memory.get(accountKey(account))??null),document:this.memory.has(accountKey(account))?JSON.parse(this.memory.get(accountKey(account)).toString()):emptyDocument(account)};
   if(!current())return fail('stale');
   if(state.ok)return{...state,lease:record.id,retention:record.retention,notices:this.owner.snapshotNotices()};
   return state.canReset?{...state,lease:record.id,retention:'device',notices:this.owner.snapshotNotices()}:{...state,canReset:false,notices:this.owner.snapshotNotices()};
  });
 }
 revoke(generation){return this.advance(generation);}
 commit(lease,expectedRevision,document,context){
  const record=this.lease;if(!record||record.id!==lease||!this.current(record,context))return Promise.resolve(fail(this.closed?'closing':'stale'));
  if(!validDocument(document,record.account))return Promise.resolve(fail('invalid'));const input=clone(document);
  return this.owner.enqueue(async()=>{
   const current=()=>this.current(record,context);if(!current())return fail('stale');
   if(record.retention==='device')return this.owner.disk.commit(record.account,expectedRevision,input,current);
   const key=accountKey(record.account),previous=this.memory.get(key)??null;
   if(byteRevision(previous)!==expectedRevision)return fail('conflict');
   const bytes=Buffer.from(JSON.stringify(input));let size=0;for(const value of this.memory.values())size+=value.length;
   if(this.memory.size+(previous?0:1)>16||size-(previous?.length??0)+bytes.length>8388608)return fail('limit');
   if(!current())return fail('stale');this.memory.set(key,bytes);return{ok:true,revision:byteRevision(bytes)};
  });
 }
 reset(lease,expectedRevision,context){
  const record=this.lease;if(!record||record.id!==lease||!this.current(record,context))return Promise.resolve(fail(this.closed?'closing':'stale'));
  return this.owner.enqueue(async()=>{
   const current=()=>this.current(record,context);if(!current())return fail('stale');
   let result;
   if(record.retention==='device')result=await this.owner.disk.reset(record.account,expectedRevision,current);
   else{const key=accountKey(record.account);if(byteRevision(this.memory.get(key)??null)!==expectedRevision)return fail('conflict');this.memory.delete(key);result={ok:true,revision:'absent'};}
   // Consume successful reset authority, including absent→absent, so old queued
   // patches cannot undo a user reset via the same byte-CAS (ABA) lease.
   if(result.ok&&this.lease===record)this.lease=null;return result;
  });
 }
 close(){this.closed=true;this.lease=null;}
 dispose(){this.close();this.memory.clear();this.owner.windows.delete(this);}
}
