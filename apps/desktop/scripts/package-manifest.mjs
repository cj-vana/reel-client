import { createReadStream } from 'node:fs';
import { lstat,readdir,readlink,realpath } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve,relative,dirname,sep } from 'node:path';
export async function packageManifest(root) {
  const base=resolve(root),files={};
  async function walk(folder) {
    for(const entry of (await readdir(folder,{withFileTypes:true})).sort((a,b)=>a.name.localeCompare(b.name))) {
      const full=resolve(folder,entry.name),name=relative(base,full).split('\\').join('/'),info=await lstat(full);
      if(info.isSymbolicLink()) {
        const target=await readlink(full),resolved=resolve(dirname(full),target);
        const canonical = await realpath(full);
        if(target.startsWith('/')||!resolved.startsWith(base+sep)||!canonical.startsWith((await realpath(base))+sep))throw new Error('Package link escapes owned root');
        files[name]={type:'link',target};
      } else if(info.isDirectory())await walk(full);
      else if(info.isFile()) {
        const hash=createHash('sha256');for await(const chunk of createReadStream(full))hash.update(chunk);
        files[name]={type:'file',bytes:info.size,mode:info.mode&0o777,sha256:hash.digest('hex')};
      } else throw new Error('Package contains a special file');
    }
  }
  await walk(base);
  const entries=Object.fromEntries(Object.entries(files).sort(([a],[b])=>a.localeCompare(b)));
  return{sha256:createHash('sha256').update(JSON.stringify(entries)).digest('hex'),files:entries};
}
