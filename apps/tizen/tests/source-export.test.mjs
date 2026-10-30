import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,access} from 'node:fs/promises';
import {resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
const root=resolve(import.meta.dirname,'..');
test('source export has no automatic SDK signing or browser QA command',async()=>{
  const pkg=JSON.parse(await readFile(resolve(root,'package.json'),'utf8'));
  assert.equal(pkg.scripts.sign,undefined);assert.equal(pkg.scripts['test:browser'],undefined);
  assert.equal(pkg.devDependencies,undefined);
  await assert.rejects(access(resolve(root,'scripts/tool.mjs')));
  await assert.rejects(access(resolve(root,'scripts/sign.mjs')));
});
test('Tizen owns platform identity instead of inheriting webOS capabilities',async()=>{
  const data=await readFile(resolve(root,'src/reel-config.js'),'utf8');
  assert.match(data,/previewMode: false/);assert.match(data,/platform: 'tizen'/);
  const xml=await readFile(resolve(root,'src/config.xml'),'utf8');assert.match(xml,/ReelClient\.Reel/);
});
test('the build script never signs or runs SDK tools',async()=>{
  const source=await readFile(resolve(root,'scripts/build.mjs'),'utf8');
  assert.ok(!source.includes('signWithSDK'));assert.ok(!source.includes('runOwnedTool'));
});
test('packages are produced unsigned',async()=>{
  const data=await readFile(resolve(root,'scripts/wgt.py'),'utf8');
  assert.ok(data.includes('unsigned-not-installable'));
});
test('pure XML/runtime policy negatives pass without native tools',t=>{
  const result=spawnSync('python3',['-B',resolve(root,'tests/source-policy.py')],{encoding:'utf8',timeout:20000,env:{...process.env,PYTHONDONTWRITEBYTECODE:'1'},stdio:['ignore','pipe','pipe']});
  assert.equal(result.error,undefined);assert.equal(result.signal,null);assert.equal(result.status,0,result.stdout+result.stderr);
  t.diagnostic(result.stdout+result.stderr);
});
