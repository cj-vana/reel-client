const {contextBridge,ipcRenderer}=require('electron');
const invoke=message=>ipcRenderer.invoke('reel:desktop:v1',message);
contextBridge.exposeInMainWorld('ReelDesktop',Object.freeze({
  initialize:()=>invoke({operation:'initialize'}),
  saveConnections:value=>invoke({operation:'saveConnections',value}),
  savePreferences:value=>invoke({operation:'savePreferences',value}),
  acknowledgeClose:nonce=>invoke({operation:'acknowledgeClose',nonce}),
  onCloseRequested:callback=>{
    if(typeof callback!=='function')return()=>{};
    const listener=(_event,nonce)=>{if(typeof nonce==='string'&&/^[a-f0-9-]{36}$/.test(nonce))callback(nonce);};
    ipcRenderer.on('reel:close:v1',listener);return()=>ipcRenderer.removeListener('reel:close:v1',listener);
  }
}));

// Noncredential browse data has its own fixed protocol and no generic storage API.
const browseChannel='reel:browse-preferences:v1',noticeChannel='reel:browse-preferences:notice:v1';
const browseInvoke=message=>ipcRenderer.invoke(browseChannel,message);
const browseExact=(value,keys)=>value!==null&&typeof value==='object'&&!Array.isArray(value)&&Object.keys(value).length===keys.length&&keys.every(key=>Object.prototype.hasOwnProperty.call(value,key));
const browseText=(value,max,empty=false)=>typeof value==='string'&&(empty||value.length>0)&&new TextEncoder().encode(value).byteLength<=max&&!/[\x00-\x1f\x7f]/.test(value);
const browseAccount=value=>{if(!browseExact(value,['server','userId'])||!browseText(value.server,2048)||!browseText(value.userId,512))return false;try{const url=new URL(value.server);return['http:','https:'].includes(url.protocol)&&!url.username&&!url.password&&!url.search&&!url.hash&&url.toString().replace(/\/+$/,'')===value.server;}catch{return false;}};
const browseGeneration=value=>Number.isSafeInteger(value)&&value>=0;
const browseRevision=value=>typeof value==='string'&&(value==='absent'||/^sha256:[a-f0-9]{64}$/.test(value));
const browseLease=value=>typeof value==='string'&&/^[a-f0-9-]{36}$/.test(value);
const browseDocument=value=>{
 if(!browseExact(value,['schema','account','entries'])||value.schema!==1||!browseAccount(value.account)||!Array.isArray(value.entries)||value.entries.length>128)return false;
 const seen=new Set();for(const entry of value.entries){
  if(!browseExact(entry,['scope','choices']))return false;const scope=entry.scope,choice=entry.choices;
  if(!browseExact(scope,['kind','category','libraryId','parentId','parentType'])||!['library','search','favorites','music','photos','books','container'].includes(scope.kind)||!['All','Movies','Series','Episodes','Collections','Playlists'].includes(scope.category)||!['libraryId','parentId','parentType'].every(key=>browseText(scope[key],512,true))||(scope.kind==='container'?!(scope.parentId&&scope.parentType):!!(scope.parentId||scope.parentType)))return false;
  if(!browseExact(choice,['sort','direction','genreId','watchStatus','favoritesOnly','view'])||!['SortName','DateCreated','ProductionYear','DateLastContentAdded'].includes(choice.sort)||!['Ascending','Descending'].includes(choice.direction)||!browseText(choice.genreId,512,true)||!['Any','Watched','Unwatched'].includes(choice.watchStatus)||typeof choice.favoritesOnly!=='boolean'||!['grid','list'].includes(choice.view))return false;
  const key=JSON.stringify([scope.kind,scope.libraryId,scope.category,scope.parentId,scope.parentType]);if(seen.has(key))return false;seen.add(key);
 }
 return new TextEncoder().encode(JSON.stringify(value)).byteLength<=524288;
};
const browseInvalid=()=>Promise.resolve({ok:false,code:'invalid'});
let disposeNotice;
const validNotice=value=>value&&typeof value==='object'&&!Array.isArray(value)&&Object.keys(value).length===4&&typeof value.id==='string'&&/^[a-f0-9-]{36}$/.test(value.id)&&typeof value.accountId==='string'&&/^[a-f0-9]{64}$/.test(value.accountId)&&value.count===1&&['preserved','io','uncertain'].includes(value.code);
contextBridge.exposeInMainWorld('ReelBrowsePreferences',Object.freeze({
 open:value=>browseExact(value,['account','generation'])&&browseAccount(value.account)&&browseGeneration(value.generation)?browseInvoke({operation:'open',account:value.account,generation:value.generation}):Promise.resolve({ok:false,code:'invalid',canReset:false,notices:[]}),
 commit:value=>browseExact(value,['lease','expectedRevision','document'])&&browseLease(value.lease)&&browseRevision(value.expectedRevision)&&browseDocument(value.document)?browseInvoke({operation:'commit',lease:value.lease,expectedRevision:value.expectedRevision,document:value.document}):browseInvalid(),
 reset:value=>browseExact(value,['lease','expectedRevision'])&&browseLease(value.lease)&&browseRevision(value.expectedRevision)?browseInvoke({operation:'reset',lease:value.lease,expectedRevision:value.expectedRevision}):browseInvalid(),
 revoke:value=>browseExact(value,['generation'])&&browseGeneration(value.generation)?browseInvoke({operation:'revoke',generation:value.generation}):browseInvalid(),
 onCleanupNotice:callback=>{
  disposeNotice?.();if(typeof callback!=='function')return()=>{};
  let active=true;const seen=new Set();
  const deliver=value=>{if(!active||!validNotice(value)||seen.has(value.id))return;seen.add(value.id);if(seen.size>64)seen.delete(seen.values().next().value);try{callback(Object.freeze({...value}));}catch{/* A view callback cannot retain or break a native subscription. */}};
  const listener=(_event,value)=>deliver(value);ipcRenderer.on(noticeChannel,listener);
  const dispose=()=>{if(!active)return;active=false;ipcRenderer.removeListener(noticeChannel,listener);seen.clear();if(disposeNotice===dispose)disposeNotice=undefined;};disposeNotice=dispose;
  // Attach first, then request initial state; deduplication closes snapshot/live overlap.
  void browseInvoke({operation:'notices'}).then(result=>{if(active&&result?.ok&&Array.isArray(result.notices)&&result.notices.length<=16)for(const value of result.notices)deliver(value);}).catch(()=>{});
  return dispose;
 }
}));

// Updates: read the state, check now, restart into a downloaded update, or open the release page. Nothing the
// page passes reaches the main process except the operation's name.
const updatesChannel='reel:updates:v1',updatesStateChannel='reel:updates:state:v1';
const updatesInvoke=operation=>ipcRenderer.invoke(updatesChannel,{operation});
const validUpdateState=value=>value!==null&&typeof value==='object'&&!Array.isArray(value)&&Object.keys(value).length===4
 &&['idle','off','checking','current','available','downloading','ready','error'].includes(value.status)
 &&(value.version===null||typeof value.version==='string'&&/^\d+\.\d+\.\d+$/.test(value.version))
 &&['install','download'].includes(value.mode)&&(value.checkedAt===null||Number.isSafeInteger(value.checkedAt));
let disposeUpdates;
contextBridge.exposeInMainWorld('ReelUpdates',Object.freeze({
 state:()=>updatesInvoke('state'),
 check:()=>updatesInvoke('check'),
 install:()=>updatesInvoke('install'),
 download:()=>updatesInvoke('download'),
 onChange:callback=>{
  disposeUpdates?.();if(typeof callback!=='function')return()=>{};
  const listener=(_event,value)=>{if(validUpdateState(value)){try{callback(Object.freeze({...value}));}catch{/* A view callback cannot break the subscription. */}}};
  ipcRenderer.on(updatesStateChannel,listener);
  const dispose=()=>{ipcRenderer.removeListener(updatesStateChannel,listener);if(disposeUpdates===dispose)disposeUpdates=undefined;};disposeUpdates=dispose;
  return dispose;
 }
}));
