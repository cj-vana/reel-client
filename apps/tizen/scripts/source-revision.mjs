import {createHash} from 'node:crypto';
import {readdir,readFile,lstat} from 'node:fs/promises';
import {resolve,relative} from 'node:path';
export const root=resolve(import.meta.dirname,'..');
export const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
export async function sourceRevision() {
  const files={};
  async function walk(folder){
    for(const entry of await readdir(folder,{withFileTypes:true})){
      const path=resolve(folder,entry.name);
      if(entry.name==='__pycache__'||entry.name==='.DS_Store')continue;
      if((await lstat(path)).isSymbolicLink())throw Error('Source links are forbidden');
      if(entry.isDirectory())await walk(path);
      else if(entry.isFile())files[relative(root,path).split('\\').join('/')]=hash(await readFile(path));
      else throw Error('Unexpected source type');
    }
  }
  for(const folder of ['src','scripts','tests'])await walk(resolve(root,folder));
  for(const name of ['package.json','package-lock.json','LICENSE'])files[name]=hash(await readFile(resolve(root,name)));
  const digest=createHash('sha256');for(const name of Object.keys(files).sort())digest.update(name+'\0'+files[name]+'\n');
  return{revision:'sha256:'+digest.digest('hex'),files};
}
if(process.argv[1]===new URL(import.meta.url).pathname)console.log(JSON.stringify(await sourceRevision(),null,2));
