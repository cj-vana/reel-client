"""Technical Roku canvases only: exact original PNG pixels, no logo redraw/rescale."""
from pathlib import Path
import hashlib,json
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
BACKGROUND=(12,12,14)
SPECS=[('channel-icon-hd.png',(290,218),'assets/mark-128.png'),('channel-icon-fhd.png',(540,405),'channel/images/mark.png'),('splash-hd.png',(1280,720),'channel/images/mark.png')]
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
outputs=[]
for name,size,source in SPECS:
    path=ROOT/source;before=digest(path)
    logo=Image.open(path).convert('RGBA')
    canvas=Image.new('RGB',size,BACKGROUND)
    offset=((size[0]-logo.width)//2,(size[1]-logo.height)//2)
    assert min(offset)>=0
    canvas.paste(logo,offset,logo)
    target=ROOT/'channel/images'/name
    canvas.save(target,format='PNG',optimize=True)
    assert digest(path)==before
    with Image.open(target) as decoded:assert decoded.convert('RGB').tobytes()==canvas.tobytes()
    outputs.append({'path':str(target.relative_to(ROOT)),'size':list(size),'sha256':digest(target),'source':source,'sourceSha256':before,'sourceSize':list(logo.size),'offset':list(offset),'rescaled':False,'backgroundRGB':list(BACKGROUND),'sourceUnchanged':True})
(ROOT/'docs/platform-assets.json').write_text(json.dumps({'tool':'Pillow 12.3.0','purpose':'Roku manifest canvases generated from the Reel logo','files':outputs},indent=2)+'\n')
print(f'{len(outputs)} Roku platform canvases; source PNGs unchanged')
