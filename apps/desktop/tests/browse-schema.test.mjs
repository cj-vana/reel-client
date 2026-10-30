import {test}from'node:test';
import assert from'node:assert/strict';
import {validAccount,accountFilename,emptyDocument,validDocument,classifyBytes,byteRevision,MAX_DOCUMENT_BYTES,validRevision,validGeneration}from'../src/browse-schema.mjs';
const account={server:'https://fixture.example/base',userId:'synthetic-user'};
const scope={kind:'library',category:'All',libraryId:'',parentId:'',parentType:''};
const choices={sort:'SortName',direction:'Ascending',genreId:'',watchStatus:'Any',favoritesOnly:false,view:'grid'};
const document=()=>({...emptyDocument(account),entries:[{scope:{...scope},choices:{...choices}}]});
test('canonical account identity preserves basepath and never accepts credential/path authority',()=>{
 assert.equal(validAccount(account),true);
 for(const server of ['https://fixture.example/base/','HTTPS://fixture.example/base','https://name:secret@fixture.example','https://fixture.example?x=y','file:///tmp/x','https://fixture.example/#x'])assert.equal(validAccount({...account,server}),false,server);
 for(const value of [{...account,token:'forbidden'},{...account,userId:'x\n'},{...account,userId:'😀'.repeat(129)}])assert.equal(validAccount(value),false);
 assert.match(accountFilename(account),/^[a-f0-9]{64}\.json$/);assert.notEqual(accountFilename(account),accountFilename({...account,server:'https://fixture.example/other'}));
});
test('exact document keys and enums reject arbitrary payloads and embedded account mismatch',()=>{
 assert.equal(validDocument(document(),account),true);
 for(const value of [{...document(),token:'no'},{...document(),account:{...account,userId:'different'}},{...document(),schema:2},{...document(),entries:[{scope,choices:{...choices,view:'other'}}]},{...document(),entries:[{scope:{...scope,path:'/tmp'},choices}]}])assert.equal(validDocument(value,account),false);
 for(const [field,value]of[['sort','fake'],['direction','sideways'],['watchStatus','unknown'],['favoritesOnly','true'],['genreId','x\0']]){const doc=document();doc.entries[0].choices[field]=value;assert.equal(validDocument(doc,account),false);}
});
test('scope uniqueness,parent semantics,128 entry and UTF8 limits are enforced',()=>{
 const doc=document();doc.entries=Array.from({length:128},(_,i)=>({scope:{...scope,libraryId:String(i)},choices:{...choices}}));assert.equal(validDocument(doc,account),true);doc.entries.push({scope:{...scope,libraryId:'129'},choices});assert.equal(validDocument(doc,account),false);
 doc.entries=[{scope,choices},{scope:{...scope},choices:{...choices}}];assert.equal(validDocument(doc,account),false);
 for(const parent of [{kind:'container',parentId:'',parentType:''},{kind:'library',parentId:'x',parentType:'Folder'}])assert.equal(validDocument({...document(),entries:[{scope:{...scope,...parent},choices}]},account),false);
 doc.entries=[{scope:{...scope,kind:'container',parentId:'x',parentType:'Folder'},choices}];assert.equal(validDocument(doc,account),true);
 doc.entries[0].choices.genreId='😀'.repeat(128);assert.equal(validDocument(doc,account),true);doc.entries[0].choices.genreId+='x';assert.equal(validDocument(doc,account),false);
});
test('foreign,oversized,malformed and unattributed bytes are preserved; own schema/body corruption is reset-capable only',()=>{
 for(const bytes of [Buffer.from('{broken'),Buffer.from(JSON.stringify({...document(),account:{...account,userId:'other'}})),Buffer.from('{}'),Buffer.alloc(MAX_DOCUMENT_BYTES+1,32)])assert.deepEqual(classifyBytes(bytes,account),{ok:false,code:'preserved',canReset:false});
 for(const [schema,code]of[[2,'unsupported'],[1,'corrupt']]){const bytes=Buffer.from(JSON.stringify({...document(),schema,entries:'bad'}));assert.deepEqual(classifyBytes(bytes,account),{ok:false,code,canReset:true,revision:byteRevision(bytes)});}
 assert.deepEqual(classifyBytes(null,account),{ok:true,revision:'absent',document:emptyDocument(account)});
});
test('revision and generation are bounded opaque CAS values rather than paths or floating authority',()=>{
 assert.equal(validRevision('absent'),true);assert.equal(validRevision(byteRevision(Buffer.from('x'))),true);
 for(const value of ['/tmp/file',{},'sha256:bad',0])assert.equal(validRevision(value),false);
 for(const value of [0,1,Number.MAX_SAFE_INTEGER])assert.equal(validGeneration(value),true);
 for(const value of [-1,NaN,Infinity,1.5,Number.MAX_SAFE_INTEGER+1,'1'])assert.equal(validGeneration(value),false);
});
test('credential URL aliases normalize to one browse tuple without collapsing distinct basepaths',async()=>{
 const {normalizedAccount}=await import('../src/browse-schema.mjs');assert.deepEqual(normalizedAccount({...account,server:'https://FIXTURE.example:443/base/'}),account);assert.deepEqual(normalizedAccount({...account,server:'https://fixture.example/base/../base'}),account);assert.notDeepEqual(normalizedAccount({...account,server:'https://fixture.example/other'}),account);assert.equal(normalizedAccount({...account,server:'https://u:p@fixture.example'}),null);
});

test('aggregate serialized UTF8 cap rejects escaped strings even when every individual identity is in bounds',()=>{
 const value={...emptyDocument(account),entries:Array.from({length:128},(_,i)=>({scope:{kind:'container',category:'All',libraryId:String(i)+'"'.repeat(508),parentId:'"'.repeat(512),parentType:'\\'.repeat(512)},choices:{...choices,genreId:'"'.repeat(512)}}))};
 assert.ok(Buffer.byteLength(JSON.stringify(value),'utf8')>MAX_DOCUMENT_BYTES);assert.equal(validDocument(value,account),false);
});
test('an unrelated own-account-shaped envelope and malformed UTF8 never grant reset authority',()=>{
 for(const bytes of[Buffer.from(JSON.stringify({account,token:'unrelated-data'})),Buffer.from([0xff,0x7b,0x7d]),Buffer.from(JSON.stringify({schema:2,account,entries:[],futureField:'preserve'}))])assert.deepEqual(classifyBytes(bytes,account),{ok:false,code:'preserved',canReset:false});
});
