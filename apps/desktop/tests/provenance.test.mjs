import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp,mkdir,writeFile,rm,symlink } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { assertPayload,payloadManifest } from '../scripts/source-revision.mjs';
test('verified build rejects changed,extra,missing and link stage payloads', async()=>{
  const dir=await mkdtemp(join(tmpdir(),'reel-stage-'));
  try { await mkdir(join(dir,'src'));await writeFile(join(dir,'src/main.mjs'),'owned');const expected=await payloadManifest(dir);await assertPayload(dir,expected);
    await writeFile(join(dir,'src/main.mjs'),'modified');await assert.rejects(assertPayload(dir,expected),/verified build/);
    await writeFile(join(dir,'src/main.mjs'),'owned');await writeFile(join(dir,'extra'),'x');await assert.rejects(assertPayload(dir,expected),/verified build/);
    await rm(join(dir,'extra'));await rm(join(dir,'src/main.mjs'));await assert.rejects(assertPayload(dir,expected),/verified build/);
    await writeFile(join(dir,'target'),'owned');await symlink(join(dir,'target'),join(dir,'src/main.mjs'));await assert.rejects(assertPayload(dir,expected),/Links/);
  } finally { await rm(dir,{recursive:true,force:true}); }
});
test('whole native package digest binds changed bytes,modes and owned link targets',async()=>{
  const{packageManifest}=await import('../scripts/package-manifest.mjs');const{chmod}=await import('node:fs/promises');const dir=await mkdtemp(join(tmpdir(),'reel-bundle-'));
  try{await mkdir(join(dir,'nested'));await writeFile(join(dir,'nested/binary'),'native');await symlink('nested/binary',join(dir,'binary'));
    const initial=await packageManifest(dir);await writeFile(join(dir,'nested/binary'),'changed');assert.notEqual((await packageManifest(dir)).sha256,initial.sha256);
    await writeFile(join(dir,'nested/binary'),'native');await chmod(join(dir,'nested/binary'),0o755);assert.notEqual((await packageManifest(dir)).sha256,initial.sha256);
    await rm(join(dir,'binary'));await symlink('/etc/passwd',join(dir,'binary'));await assert.rejects(packageManifest(dir),/escapes/);
  }finally{await rm(dir,{recursive:true,force:true});}
});
test('whole package rejects chained symlink dot-segment escape and dangling or cyclic links',async()=>{
  const{packageManifest}=await import('../scripts/package-manifest.mjs');const parent=await mkdtemp(join(tmpdir(),'reel-chain-')),root=join(parent,'root');
  try{await mkdir(join(root,'foo'),{recursive:true});await mkdir(join(root,'q'));await writeFile(join(parent,'outside-file'),'unowned');await symlink('../q',join(root,'foo/bar'));await symlink('foo/bar/../../outside-file',join(root,'launch'));await assert.rejects(packageManifest(root),/escapes/);
    await rm(join(root,'launch'));await symlink('missing',join(root,'launch'));await assert.rejects(packageManifest(root),{code:'ENOENT'});
    await rm(join(root,'launch'));await symlink('launch',join(root,'launch'));await assert.rejects(packageManifest(root),{code:'ELOOP'});
  }finally{await rm(parent,{recursive:true,force:true});}
});
