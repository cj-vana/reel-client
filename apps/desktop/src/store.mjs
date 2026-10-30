import { mkdir,lstat,readFile,open,rm,realpath } from 'node:fs/promises';
import { lstatSync,readFileSync,realpathSync,renameSync,openSync,fsyncSync,closeSync,constants } from 'node:fs';
import { join,resolve } from 'node:path';
import { randomUUID,createHash } from 'node:crypto';
const QUALITY=[120000000,20000000,8000000,2000000];
const fail=code=>({ok:false,code});
const plain=value=>value!==null&&typeof value==='object'&&!Array.isArray(value)&&Object.getPrototypeOf(value)===Object.prototype;
const fields=(value,names)=>plain(value)&&Object.keys(value).length===names.length&&names.every(key=>Object.hasOwn(value,key));
const preferenceFields=(value,names)=>fields(value,names)||fields(value,[...names,'autoplay'])&&typeof value.autoplay==='boolean';
const revision=value=>Number.isSafeInteger(value)&&value>=0&&value<=Number.MAX_SAFE_INTEGER;
const text=(value,max,nonempty=true)=>typeof value==='string'&&value.length<=max&&(!nonempty||value.length>0)&&!/[\x00-\x1f\x7f]/.test(value);
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
export function validConnections(value) {
  if(!fields(value,['accounts','activeId'])||!Array.isArray(value.accounts)||value.accounts.length>16)return false;
  const ids=new Set();
  for(const account of value.accounts){
    if(!fields(account,['id','server','token','userId','name','serverName','remember'])||account.remember!==true||!text(account.id,2600)||!text(account.server,2048)||!text(account.token,16384)||!text(account.userId,512)||!text(account.name,512,false)||!text(account.serverName,512,false))return false;
    let url;try{url=new URL(account.server);}catch{return false;}
    if(!['http:','https:'].includes(url.protocol)||url.username||url.password||url.search||url.hash||account.server.endsWith('/')||account.id!==account.server+'|'+account.userId||ids.has(account.id))return false;
    ids.add(account.id);
  }
  return value.activeId===null||typeof value.activeId==='string'&&ids.has(value.activeId);
}
export function validConnectionWrite(value){return fields(value,['expectedRevision','accounts','activeId'])&&revision(value.expectedRevision)&&value.expectedRevision<Number.MAX_SAFE_INTEGER&&validConnections({accounts:value.accounts,activeId:value.activeId});}
export function validPreferenceWrite(value){return preferenceFields(value,['expectedRevision','quality','history'])&&revision(value.expectedRevision)&&value.expectedRevision<Number.MAX_SAFE_INTEGER&&QUALITY.includes(value.quality)&&typeof value.history==='boolean';}
export function syncDirectory(directory){
  // Node does not expose a qualified Windows directory-metadata flush contract.
  if(process.platform==='win32')return'platform-unverified';
  const handle=openSync(directory,constants.O_RDONLY);try{fsyncSync(handle);}finally{closeSync(handle);}return'synced';
}
export class DesktopStore {
  constructor(directory,cryptoProvider,{directorySync=syncDirectory,availabilityTimeoutMs=5000}={}){this.directory=resolve(directory);this.crypto=cryptoProvider;this.directorySync=directorySync;this.availabilityTimeoutMs=availabilityTimeoutMs;}
  queue=Promise.resolve();state='unavailable';connectionRevision=0;preferenceRevision=0;
  quarantined=false;
  connections={accounts:[],activeId:null};preferences={quality:120000000,history:false,autoplay:true};deviceId=randomUUID();
  initialize(){this.initialization??=this.load();return this.initialization.then(()=>this.snapshot());}
  async load(){
    try{
      await mkdir(this.directory,{recursive:true,mode:0o700});const info=await lstat(this.directory);
      if(!info.isDirectory()||info.isSymbolicLink()||process.getuid&&info.uid!==process.getuid()||process.platform!=='win32'&&(info.mode&0o077)!==0)throw new Error('Invalid store directory');
      this.canonical=await realpath(this.directory);this.directory=this.canonical;
      const prefs=await this.readOwned('preferences.json',16384);
      if(prefs){const value=JSON.parse(prefs.toString());if(!preferenceFields(value,['schema','revision','deviceId','quality','history'])||value.schema!==1||!revision(value.revision)||!text(value.deviceId,80)||!QUALITY.includes(value.quality)||typeof value.history!=='boolean')throw new Error('Invalid preferences');this.preferenceRevision=value.revision;this.deviceId=value.deviceId;this.preferences={quality:value.quality,history:value.history,autoplay:value.autoplay??true};this.preferenceHash=hash(prefs);}
      if(!prefs){const bytes=Buffer.from(JSON.stringify({schema:1,revision:0,deviceId:this.deviceId,...this.preferences}));const saved=await this.atomic('preferences.json',bytes,null,()=>true);if(!saved.ok)throw new Error('Preferences initialization failed');this.preferenceHash=hash(bytes);}
      const ciphertext=await this.readOwned('connections.vault',524288);this.cipherHash=ciphertext?hash(ciphertext):null;
      let availabilityTimer;
      try {
        // OS secure-storage services can stall. A timeout admits session-only use;
        // it never unlocks, replaces or rewrites an existing vault.
        const available=await Promise.race([
          Promise.resolve().then(()=>this.crypto.available()).catch(()=>false),
          new Promise(resolve=>{availabilityTimer=setTimeout(()=>resolve(false),this.availabilityTimeoutMs);})
        ]);
        if(!available){this.state='unavailable';return this.snapshot();}
      } finally {clearTimeout(availabilityTimer);}
      if(!ciphertext){this.state='ready';return this.snapshot();}
      let decrypted;try{decrypted=await this.crypto.decrypt(ciphertext);}catch{this.state='locked';return this.snapshot();}
      let value;try{value=JSON.parse(decrypted);}catch{this.state='corrupt';return this.snapshot();}
      if(!fields(value,['schema','revision','accounts','activeId'])||value.schema!==1||!revision(value.revision)||!validConnections({accounts:value.accounts,activeId:value.activeId})){this.state='corrupt';return this.snapshot();}
      this.connectionRevision=value.revision;this.connections={accounts:value.accounts,activeId:value.activeId};this.state='ready';
    }catch{this.state='corrupt';}
    return this.snapshot();
  }
  snapshot(){if(this.quarantined)return fail('uncertain');return{ok:true,storeState:this.state,...(this.state==='ready'?{revision:this.connectionRevision,savedConnections:structuredClone(this.connections)}:{}),deviceId:this.deviceId,preferences:{...this.preferences},preferenceRevision:this.preferenceRevision};}
  async readOwned(name,max){const file=join(this.directory,name);let info;try{info=await lstat(file);}catch(error){if(error.code==='ENOENT')return null;throw error;}if(!info.isFile()||info.isSymbolicLink()||info.size>max||process.platform!=='win32'&&(info.mode&0o077)!==0)throw new Error('Invalid store file');return readFile(file);}
  enqueue(operation){const next=this.queue.then(operation,operation);this.queue=next.then(()=>undefined,()=>undefined);return next;}
  saveConnections(value,context){
    if(!validConnectionWrite(value))return Promise.resolve(fail('invalid'));
    const input=structuredClone(value);
    return this.enqueue(async()=>{
      await this.initialize();if(this.quarantined)return fail('uncertain');if(this.state!=='ready')return fail(this.state);if(!context())return fail('closing');if(input.expectedRevision!==this.connectionRevision)return fail('conflict');
      const next={schema:1,revision:this.connectionRevision+1,accounts:input.accounts,activeId:input.activeId};
      try{const encrypted=await this.crypto.encrypt(JSON.stringify(next));if(!Buffer.isBuffer(encrypted)||encrypted.length>524288)throw new Error('Invalid encrypted document');
        const result=await this.atomic('connections.vault',encrypted,this.cipherHash,context);if(!result.ok)return result;
        this.cipherHash=hash(encrypted);this.connectionRevision=next.revision;this.connections={accounts:next.accounts,activeId:next.activeId};return{ok:true,revision:next.revision};
      }catch{return fail('io');}
    });
  }
  savePreferences(value,context){
    if(!validPreferenceWrite(value))return Promise.resolve(fail('invalid'));const input={...value};
    return this.enqueue(async()=>{await this.initialize();if(this.quarantined)return fail('uncertain');if(!this.canonical)return fail('unavailable');if(!context())return fail('closing');if(input.expectedRevision!==this.preferenceRevision)return fail('conflict');
      const next={schema:1,revision:this.preferenceRevision+1,deviceId:this.deviceId,quality:input.quality,history:input.history,autoplay:input.autoplay??true},bytes=Buffer.from(JSON.stringify(next));
      try{const result=await this.atomic('preferences.json',bytes,this.preferenceHash??null,context);if(!result.ok)return result;this.preferenceHash=hash(bytes);this.preferenceRevision=next.revision;this.preferences={quality:next.quality,history:next.history,autoplay:next.autoplay};return{ok:true,revision:next.revision};}catch{return fail('io');}
    });
  }
  async atomic(name,bytes,previousHash,context){
    const target=join(this.directory,name),temp=join(this.directory,'.pending-'+randomUUID());let handle,committed=false;
    try{
      handle=await open(temp,'wx',0o600);await handle.writeFile(bytes);await handle.sync();await handle.close();handle=undefined;
      // Revalidate immediately before one synchronous metadata commit. No JS navigation event can
      // interleave the document fence and rename after asynchronous encryption/file preparation.
      const info=lstatSync(this.directory);if(!info.isDirectory()||info.isSymbolicLink()||realpathSync(this.directory)!==this.canonical)throw new Error('Store directory changed');
      let current=null;try{const info=lstatSync(target);if(!info.isFile()||info.isSymbolicLink()||info.size>524288)throw new Error('Store file changed');current=hash(readFileSync(target));}catch(error){if(error.code!=='ENOENT')throw error;}
      if(current!==previousHash)return fail('conflict');this.directorySync(this.directory,'before');if(!context())return fail('closing');renameSync(temp,target);committed=true;
      try{this.directorySync(this.directory,'after');}catch{this.quarantined=true;return fail('uncertain');}
      return{ok:true};
    }finally{await handle?.close().catch(()=>{});if(!committed)await rm(temp,{force:true}).catch(()=>{});}
  }
  async drain(){await this.initialization;await this.queue;}
}
