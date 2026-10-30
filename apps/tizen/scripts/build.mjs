import {cp,lstat,mkdir,readFile,readdir,rm,writeFile,realpath} from 'node:fs/promises';
import {resolve,relative,dirname,sep} from 'node:path';
import {root,hash,sourceRevision} from './source-revision.mjs';

export const CORE_FILES=['THIRD_PARTY_NOTICES.txt','brand/mark.svg','icon.png','index.html','largeIcon.png','reel.css','reel.js'];
export async function inventory(folder) {
  const files={};
  async function walk(path){for(const entry of await readdir(path,{withFileTypes:true})){const full=resolve(path,entry.name);if(entry.isDirectory())await walk(full);else if(entry.isFile()&&!(await lstat(full)).isSymbolicLink()){const bytes=await readFile(full);files[relative(folder,full).split('\\').join('/')]={sha256:hash(bytes),bytes:bytes.length};}else throw Error('Unexpected stage entry');}}
  await walk(folder);return files;
}
export async function build(webRoot) {
  if(!webRoot)throw Error('Provide --web-root pointing to apps/web after running npm run webos:stage.');
  const web=await realpath(resolve(webRoot)),before=await sourceRevision();
  const stageManifest=JSON.parse(await readFile(resolve(web,'.cache/webos-stage-manifest.json'),'utf8'));
  const sourceStage=resolve(web,'webos-package');
  if(await realpath(sourceStage)!==sourceStage)throw Error('The web TV stage root is not canonical');
  const stageInventory=await inventory(sourceStage);
  if(JSON.stringify(Object.keys(stageInventory).sort())!==JSON.stringify(Object.keys(stageManifest.files).sort()))throw Error('The web TV stage does not match its manifest');
  for(const [name,digest]of Object.entries(stageManifest.files)){
    const file=resolve(sourceStage,name);if(!file.startsWith(sourceStage+sep)||(await lstat(file)).isSymbolicLink()||hash(await readFile(file))!==digest)throw Error('Web TV stage changed: '+name);
  }
  const cache=resolve(root,'.cache'),stage=resolve(cache,'stage');await mkdir(cache,{recursive:true,mode:0o700});
  if((await lstat(cache)).isSymbolicLink()||await realpath(cache)!==cache)throw Error('Owned cache root must be canonical');
  try{if((await lstat(stage)).isSymbolicLink())throw Error('Owned stage is a link');}catch(error){if(error.code!=='ENOENT')throw error;}
  if(relative(cache,stage)!=='stage')throw Error('Unexpected owned stage path');
  await rm(stage,{recursive:true,force:true});await mkdir(stage,{mode:0o700});
  for(const name of CORE_FILES){await mkdir(dirname(resolve(stage,name)),{recursive:true});await cp(resolve(sourceStage,name),resolve(stage,name));}
  const policy=(await readFile(resolve(root,'src/policy.mjs'),'utf8')).replace(/^export /gm,'');
  const adapter=(await readFile(resolve(root,'src/adapter.mjs'),'utf8')).replace(/^import .*from '\.\/policy\.mjs';\n/m,'').replace(/^export /gm,'');
  await writeFile(resolve(stage,'tizen-adapter.js'),"(function(){'use strict';\n"+policy+'\n'+adapter+'\ninstallTizenAdapter(window,document);\n})();\n');
  for(const [source,target]of[['src/reel-config.js','reel-config.js'],['src/adapter.css','tizen-adapter.css'],['src/launch.html','launch.html'],['src/config.xml','config.xml'],['LICENSE','LICENSE']])await cp(resolve(root,source),resolve(stage,target));
  const files=await inventory(stage);
  for(const name of CORE_FILES)if(files[name].sha256!==stageManifest.files[name])throw Error('Shared core byte drift');
  if(before.revision!==(await sourceRevision()).revision)throw Error('Source changed during assembly');
  for(const [name,digest]of Object.entries(stageManifest.files))if(hash(await readFile(resolve(sourceStage,name)))!==digest)throw Error('Web TV stage changed during assembly');
  const receipt={sourceRevision:before.revision,coreFiles:CORE_FILES,ownedRuntimeConfig:{source:'src/reel-config.js',file:'reel-config.js',sha256:files['reel-config.js'].sha256,platform:'tizen'},files,stage,appId:'ReelClient.Reel',packageId:'ReelClient',minimumTizen:'7.0',nativeSigningPerformed:false,nativeInstallVerified:false};
  await writeFile(resolve(cache,'build-receipt.json'),JSON.stringify(receipt,null,2)+'\n');
  return receipt;
}
if(process.argv[1]===new URL(import.meta.url).pathname){const index=process.argv.indexOf('--web-root');const receipt=await build(index>=0?process.argv[index+1]:undefined);console.log(JSON.stringify({sourceRevision:receipt.sourceRevision,files:Object.keys(receipt.files).length,stage:receipt.stage,nativeSigningPerformed:false}));}
