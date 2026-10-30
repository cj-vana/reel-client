import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { assertPortFree,ownsListener } from '../scripts/runtime-ownership.mjs';
test('busy loopback port is rejected without sending a request to the existing listener', async()=>{
  let requests=0;const server=createServer((_request,response)=>{requests++;response.end('unrelated');});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  try {const port=server.address().port;await assert.rejects(assertPortFree(port),{code:'EADDRINUSE'});assert.equal(requests,0);
    if(process.platform==='darwin')assert.throws(()=>ownsListener({pid:process.pid+100000,exitCode:null,signalCode:null},port),/another process/);
  } finally {await new Promise(resolve=>server.close(resolve));}
});
test('exited child cannot qualify any readiness endpoint',()=>assert.throws(()=>ownsListener({pid:1,exitCode:1,signalCode:null},19670),/exited before readiness/));
test('shutdown escalates an owned TERM-resistant child and waits for confirmed exit',async()=>{
  const {spawn}=await import('node:child_process');const{stopOwnedChild}=await import('../scripts/runtime-ownership.mjs');
  const child=spawn(process.execPath,['-e',"process.on('SIGTERM',()=>{});process.stdout.write('ready');setInterval(()=>{},1000)"],{stdio:['ignore','pipe','ignore']});
  await new Promise(resolve=>child.stdout.once('data',resolve));
  assert.equal(await stopOwnedChild(child,20),true);assert.equal(child.signalCode,'SIGKILL');
});
