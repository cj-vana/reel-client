"""Deterministic direct-sideload ZIP. No upload, device discovery or network access."""
from pathlib import Path
import hashlib,json,zipfile
ROOT=Path(__file__).resolve().parents[1]
CHANNEL=ROOT/'channel'
def channel_files():
    files=[]
    for p in sorted(CHANNEL.rglob('*')):
        if p.is_symlink(): raise ValueError(f'Symlink in channel: {p.name}')
        if not p.is_file():continue
        name=p.relative_to(CHANNEL).as_posix()
        if name not in {'manifest','LICENSE'} and not ((name.startswith('source/') and p.suffix=='.brs') or (name.startswith('components/') and p.suffix in {'.xml','.brs'}) or (name.startswith('images/') and p.suffix=='.png')):raise ValueError(f'Unapproved package member: {name}')
        files.append((name,p))
    assert len(files)<80 and any(n=='manifest' for n,_ in files)
    return files

def package():
    out=ROOT/'out';out.mkdir(exist_ok=True);(ROOT/'evidence').mkdir(exist_ok=True)
    target=out/'reel-client-roku-sideload.zip'
    with zipfile.ZipFile(target,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
        for name,p in channel_files():
            info=zipfile.ZipInfo(name,date_time=(2026,1,1,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED;info.external_attr=0o100644<<16
            archive.writestr(info,p.read_bytes())
    members={n:{'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for n,p in channel_files()}
    proof={'kind':'private-direct-sideload-candidate','nativeRokuVerified':False,'uploaded':False,'zip':target.name,'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'bytes':target.stat().st_size,'members':members}
    (ROOT/'evidence/package.json').write_text(json.dumps(proof,indent=2)+'\n')
    print(f'{target.name}: {len(members)} files; sha256 {proof["sha256"]}; not installed or hardware qualified')
if __name__=='__main__':package()
