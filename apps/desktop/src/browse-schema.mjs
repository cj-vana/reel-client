import { createHash } from 'node:crypto';
export const MAX_DOCUMENT_BYTES=524288,MAX_SCOPES=128;
const kinds=['library','search','favorites','music','photos','books','container'];
const categories=['All','Movies','Series','Episodes','Collections','Playlists'];
const sorts=['SortName','DateCreated','ProductionYear','DateLastContentAdded'];
export const plain=value=>value!==null&&typeof value==='object'&&!Array.isArray(value)&&Object.getPrototypeOf(value)===Object.prototype;
export const fields=(value,names)=>plain(value)&&Object.keys(value).length===names.length&&names.every(key=>Object.prototype.hasOwnProperty.call(value,key));
export const text=(value,max,{empty=false}={})=>typeof value==='string'&&(empty||value.length>0)&&Buffer.byteLength(value,'utf8')<=max&&!/[\x00-\x1f\x7f]/.test(value);
export function validAccount(value){
  if(!fields(value,['server','userId'])||!text(value.server,2048)||!text(value.userId,512))return false;
  try{const url=new URL(value.server);return ['http:','https:'].includes(url.protocol)&&!url.username&&!url.password&&!url.search&&!url.hash&&url.toString().replace(/\/+$/,'')===value.server;}catch{return false;}
}
/** Existing credential IDs may retain URL aliases; browse identity is canonical. */
export function normalizedAccount(value){
 if(!value||!text(value.server,2048)||!text(value.userId,512))return null;
 try{const url=new URL(value.server);if(!['http:','https:'].includes(url.protocol)||url.username||url.password||url.search||url.hash)return null;const account={server:url.toString().replace(/\/+$/,''),userId:value.userId};return validAccount(account)?account:null;}catch{return null;}
}
export const sameAccount=(a,b)=>a.server===b.server&&a.userId===b.userId;
export const accountKey=account=>{if(!validAccount(account))throw new TypeError('Invalid browse account');return JSON.stringify([account.server,account.userId]);};
export const accountFilename=account=>createHash('sha256').update(accountKey(account)).digest('hex')+'.json';
export const byteRevision=bytes=>bytes===null?'absent':'sha256:'+createHash('sha256').update(bytes).digest('hex');
export const validRevision=value=>typeof value==='string'&&(value==='absent'||/^sha256:[a-f0-9]{64}$/.test(value));
export const validGeneration=value=>Number.isSafeInteger(value)&&value>=0;
export function validScope(value){return fields(value,['kind','category','libraryId','parentId','parentType'])&&kinds.includes(value.kind)&&categories.includes(value.category)&&['libraryId','parentId','parentType'].every(key=>text(value[key],512,{empty:true}))&&(value.kind==='container'?!!value.parentId&&!!value.parentType:!value.parentId&&!value.parentType);}
export const scopeKey=scope=>JSON.stringify([scope.kind,scope.libraryId,scope.category,scope.parentId,scope.parentType]);
export function validChoices(value){return fields(value,['sort','direction','genreId','watchStatus','favoritesOnly','view'])&&sorts.includes(value.sort)&&['Ascending','Descending'].includes(value.direction)&&text(value.genreId,512,{empty:true})&&['Any','Watched','Unwatched'].includes(value.watchStatus)&&typeof value.favoritesOnly==='boolean'&&['grid','list'].includes(value.view);}
export const emptyDocument=account=>({schema:1,account:{...account},entries:[]});
export function validDocument(value,account){
  if(!validAccount(account)||!fields(value,['schema','account','entries'])||value.schema!==1||!validAccount(value.account)||!sameAccount(value.account,account)||!Array.isArray(value.entries)||value.entries.length>MAX_SCOPES)return false;
  const seen=new Set();
  for(const entry of value.entries){if(!fields(entry,['scope','choices'])||!validScope(entry.scope)||!validChoices(entry.choices))return false;const key=scopeKey(entry.scope);if(seen.has(key))return false;seen.add(key);}
  try{return Buffer.byteLength(JSON.stringify(value),'utf8')<=MAX_DOCUMENT_BYTES;}catch{return false;}
}
export function classifyBytes(bytes,account){
  if(bytes===null)return{ok:true,revision:'absent',document:emptyDocument(account)};
  const revision=byteRevision(bytes);
  if(bytes.length>MAX_DOCUMENT_BYTES)return{ok:false,code:'preserved',canReset:false};
  let value;try{const decoded=bytes.toString('utf8');if(!Buffer.from(decoded,'utf8').equals(bytes))return{ok:false,code:'preserved',canReset:false};value=JSON.parse(decoded);}catch{return{ok:false,code:'preserved',canReset:false};}
  // A hashed filename alone never authorizes overwriting unattributed/foreign bytes.
  if(!fields(value,['schema','account','entries'])||!validAccount(value.account)||!sameAccount(value.account,account))return{ok:false,code:'preserved',canReset:false};
  if(!validDocument(value,account))return{ok:false,code:value.schema!==1?'unsupported':'corrupt',canReset:true,revision};
  return{ok:true,revision,document:value};
}
