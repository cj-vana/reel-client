import {test} from 'node:test';
import assert from 'node:assert/strict';
import {desktopCryptoProvider} from '../src/crypto-provider.mjs';

for(const [name,qa,platform] of [['QA',true,'darwin'],['Linux',false,'linux']])test(`${name} provider never accesses operating-system secret storage`,async()=>{
 const safeStorage=new Proxy({},{get(){throw new Error('OS secure storage must not be touched');}});
 const provider=desktopCryptoProvider({qa,platform,safeStorage});
 assert.equal(await provider.available(),false);
 await assert.rejects(provider.encrypt('synthetic'),/unavailable/);
 await assert.rejects(provider.decrypt(Buffer.from('synthetic')),/unavailable/);
});
test('production provider delegates only to the async operating-system storage methods',async()=>{
 const calls=[],ciphertext=Buffer.from('ciphertext');
 const provider=desktopCryptoProvider({qa:false,platform:'darwin',safeStorage:{
  isAsyncEncryptionAvailable:async()=>{calls.push('available');return true;},
  encryptStringAsync:async text=>{calls.push(['encrypt',text]);return ciphertext;},
  decryptStringAsync:async bytes=>{calls.push(['decrypt',bytes]);return{result:'synthetic'};}
 }});
 assert.equal(await provider.available(),true);assert.equal(await provider.encrypt('synthetic'),ciphertext);assert.equal(await provider.decrypt(ciphertext),'synthetic');
 assert.deepEqual(calls,['available',['encrypt','synthetic'],['decrypt',ciphertext]]);
});
