import {readFile,mkdir,writeFile,lstat,realpath} from 'node:fs/promises';
import {resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {root,sourceRevision,hash} from './source-revision.mjs';
import {inventory} from './build.mjs';

export async function qualifiedStage() {
  const receipt=JSON.parse(await readFile(resolve(root,'.cache/build-receipt.json'),'utf8'));
  const current=await sourceRevision();
  if(receipt.sourceRevision!==current.revision)throw Error('Build is stale. Run npm run build again.');
  if(JSON.stringify(await inventory(receipt.stage))!==JSON.stringify(receipt.files))throw Error('Staged bytes/inventory changed.');
  const configHash=hash(await readFile(resolve(root,'src/reel-config.js')));
  if(receipt.files['reel-config.js']?.sha256!==configHash||receipt.ownedRuntimeConfig?.platform!=='tizen')throw Error('Owned Tizen runtime config changed.');
  return receipt;
}
export async function packageUnsigned() {
  const receipt=await qualifiedStage();const directory=resolve(root,'.cache/packages');await mkdir(directory,{recursive:true,mode:0o700});
  if((await lstat(directory)).isSymbolicLink()||await realpath(directory)!==directory)throw Error('Package output directory must be canonical');
  const output=resolve(directory,'reel-tv-preview-'+receipt.sourceRevision.slice(7,19)+'.unsigned.wgt');
  try{if((await lstat(output)).isSymbolicLink())throw Error('Package output link forbidden');}catch(error){if(error.code!=='ENOENT')throw error;}
  const child=spawnSync('python3',[resolve(root,'scripts/wgt.py'),'package',resolve(root,'.cache/build-receipt.json'),output],{encoding:'utf8',timeout:30000,killSignal:'SIGKILL',maxBuffer:4*1024*1024});
  if(child.status!==0)throw Error(child.stderr||child.error?.message||'Unsigned packaging failed.');
  const inspection=JSON.parse(child.stdout);
  if((await sourceRevision()).revision!==receipt.sourceRevision)throw Error('Source changed while packaging.');
  await qualifiedStage();
  const result={...inspection,sourceRevision:receipt.sourceRevision,path:output,archiveSha256:hash(await readFile(output))};
  await writeFile(resolve(root,'.cache/package-inspection.json'),JSON.stringify(result,null,2)+'\n');return result;
}
if(process.argv[1]===new URL(import.meta.url).pathname){const result=await packageUnsigned();console.log(JSON.stringify({path:result.path,sha256:result.sha256,packageState:result.packageState,sourceRevision:result.sourceRevision,nativeInstallVerified:false}));}
