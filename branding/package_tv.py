"""Populate the existing tvOS catalog structure without changing its JSON contract."""
from pathlib import Path
from PIL import Image
import json,sys
sys.dont_write_bytecode=True
from package_assets import strip_metadata
ROOT=Path(__file__).resolve().parent.parent/'tvos'
CAT=ROOT/'Assets.xcassets';BRAND=CAT/'BrandAssets.brandassets';INFO={'author':'xcode','version':1}
def write(p,value):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(value,indent=2)+'\n')
def imageset(folder,source,sizes):
    images=[];folder.mkdir(parents=True,exist_ok=True)
    for scale,size in sizes:
        name=f'image-{size[0]}x{size[1]}.png';source.resize(size,Image.Resampling.LANCZOS).save(folder/name);images.append({'idiom':'tv','scale':scale,'filename':name})
    write(folder/'Contents.json',{'images':images,'info':INFO})
def stack(name,sizes,front,back):
    folder=BRAND/name;layers=[]
    for title,source in [('Foreground',front),('Background',back)]:
        layer=folder/(title+'.imagestacklayer');write(layer/'Contents.json',{'info':INFO});imageset(layer/'Content.imageset',source,sizes);layers.append({'filename':title+'.imagestacklayer'})
    write(folder/'Contents.json',{'layers':layers,'info':INFO})
def main():
    front=Image.open(ROOT/'masters/icon-foreground-2560x1536.png');back=Image.open(ROOT/'masters/icon-background-2560x1536.png');top=Image.open(ROOT/'masters/top-shelf-wide-4640x1440.png')
    write(CAT/'Contents.json',{'info':INFO})
    stack('AppIconHome.imagestack',[('1x',(400,240)),('2x',(800,480))],front,back)
    # This name is an existing asset-catalog slot, not an app-store work request.
    stack('AppIconStore.imagestack',[('1x',(1280,768))],front,back)
    imageset(BRAND/'TopShelfWide.imageset',top,[('1x',(2320,720)),('2x',(4640,1440))])
    imageset(BRAND/'TopShelfStandard.imageset',top.crop((400,0,4240,1440)),[('1x',(1920,720)),('2x',(3840,1440))])
    write(BRAND/'Contents.json',{'assets':[{'idiom':'tv','filename':'AppIconHome.imagestack','role':'primary-app-icon','size':'400x240'},{'idiom':'tv','filename':'AppIconStore.imagestack','role':'primary-app-icon','size':'1280x768'},{'idiom':'tv','filename':'TopShelfWide.imageset','role':'top-shelf-image-wide','size':'2320x720'},{'idiom':'tv','filename':'TopShelfStandard.imageset','role':'top-shelf-image','size':'1920x720'}],'info':INFO})
    for size in [(400,240),(800,480),(1280,768)]:Image.alpha_composite(back.resize(size,Image.Resampling.LANCZOS).convert('RGBA'),front.resize(size,Image.Resampling.LANCZOS)).convert('RGB').save(ROOT/'masters'/f'icon-composite-{size[0]}x{size[1]}.png')
    for p in ROOT.rglob('*.png'):strip_metadata(p)
if __name__=='__main__':main()
