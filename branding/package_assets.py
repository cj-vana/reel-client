"""Resize approved Blender masters; remove descriptive PNG metadata only."""
from pathlib import Path
import struct
from PIL import Image
ROOT=Path(__file__).resolve().parent
SIZES=(16,24,32,48,64,80,96,117,128,130,256,512)
def clean_png_bytes(raw):
    out=bytearray(raw[:8]);offset=8
    while offset<len(raw):
        size=struct.unpack('>I',raw[offset:offset+4])[0];kind=raw[offset+4:offset+8];chunk=raw[offset:offset+size+12]
        if kind not in (b'tEXt',b'zTXt',b'iTXt',b'eXIf'):out.extend(chunk)
        offset+=size+12
    assert offset==len(raw);return bytes(out)
def strip_metadata(path):path.write_bytes(clean_png_bytes(path.read_bytes()))
def main():
    for stem in ('reelclient-app-icon','reelclient-mark-transparent','reelclient-mark-ink'):
        source=Image.open(ROOT/(stem+'-1024.png'))
        for size in SIZES:source.resize((size,size),Image.Resampling.LANCZOS).save(ROOT/(stem+f'-{size}.png'))
    source=Image.open(ROOT/'reelclient-mark-flat-1024.png')
    for size in (*SIZES,1024):source.resize((size,size),Image.Resampling.LANCZOS).save(ROOT/f'reelclient-mark-template-{size}.png')
    for p in ROOT.glob('*.png'):strip_metadata(p)
if __name__=='__main__':main()
