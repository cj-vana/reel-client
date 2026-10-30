"""Derive existing Reel TV catalog layouts from the unchanged approved mark."""
from pathlib import Path
import hashlib,json
import bpy
ROOT=Path(__file__).resolve().parent
OUT=ROOT.parent/'tvos';OUT.mkdir(exist_ok=True)
MASTERS=OUT/'masters';MASTERS.mkdir(exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'reelclient-logo.blend'))
s=bpy.context.scene;mark=s.objects['MARK | Ribbon'];curve=s.objects['SOURCE | original editable contours'];bg=s.objects['BACKGROUND | full-bleed midnight'];cam=s.camera
def geometry_hash():
    return hashlib.sha256(json.dumps({'vertices':[list(v.co)for v in mark.data.vertices],'faces':[list(p.vertices)for p in mark.data.polygons],'curves':[[list(p.co)for p in x.points]for x in curve.data.splines]},separators=(',',':')).encode()).hexdigest()
original=geometry_hash()
# Same existing TV optical lift and camera framing; only the logo source changed.
mark.location.y+=.04;curve.location.y+=.04
s.name='ReelTV | Ribbon branding';s['source_geometry_sha256']=original
s.render.resolution_x=2560;s.render.resolution_y=1536;s.render.resolution_percentage=100;cam.data.ortho_scale=4.8;s.cycles.samples=64;s.cycles.seed=17
s.render.image_settings.color_mode='RGB';s.render.film_transparent=False;s.render.filepath='//masters/icon-composite-2560x1536.png'
for im in list(bpy.data.images):
    if im.source=='VIEWER':bpy.data.images.remove(im)
bpy.data.libraries.write(str(OUT/'ReelTV-branding.blend'),{s},fake_user=True,compress=False)
bg.hide_render=True;s.render.film_transparent=True;s.render.image_settings.color_mode='RGBA';s.render.filepath=str(MASTERS/'icon-foreground-2560x1536.png');bpy.ops.render.render(write_still=True)
bg.hide_render=False;mark.hide_render=True;s.render.film_transparent=False;s.render.image_settings.color_mode='RGB';s.render.filepath=str(MASTERS/'icon-background-2560x1536.png');bpy.ops.render.render(write_still=True)
mark.hide_render=False;s.render.resolution_x=4640;s.render.resolution_y=1440;cam.data.ortho_scale=10.08;s.render.filepath=str(MASTERS/'top-shelf-wide-4640x1440.png');bpy.ops.render.render(write_still=True)
assert geometry_hash()==original
(OUT/'geometry-verification.json').write_text(json.dumps({'status':'passed','geometry_sha256':original,'mark_geometry_changed':False,'optical_offset_y':.04,'icon_camera_ortho_scale':4.8,'top_shelf_camera_ortho_scale':10.08},indent=2)+'\n')
