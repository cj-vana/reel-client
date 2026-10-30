"""Build the recommended Reel Ribbon logo in Blender from original contours.

Usage: Blender --background --factory-startup --python-exit-code 1 --python build_blender.py
Optional after -- : output-directory. This permits a fresh reproducibility check.
Requires only Blender's bundled Python modules and sibling scene_helpers.py.
"""
from pathlib import Path
import sys,json
sys.dont_write_bytecode=True
import bpy
sys.path.insert(0,str(Path(__file__).resolve().parent))
import scene_helpers as design

OUT=Path(sys.argv[sys.argv.index('--')+1]).resolve() if '--' in sys.argv else Path(__file__).resolve().parent
if not OUT.is_relative_to(Path(__file__).resolve().parent):
    raise ValueError('Output must remain inside this source directory.')
OUT.mkdir(exist_ok=True)
design.ROOT=OUT

# V2 moves the return inward to equalize the leg and stem weights and widens
# the negative throat. The full shape remains one open, continuous ribbon.
RIBBON=design.path([
 ('M',(-.84,-.86)),('L',(-.84,.18)),
 ('C',(-.84,.66),(-.48,.96),(-.01,.96)),
 ('C',(.47,.96),(.79,.66),(.79,.27)),
 ('C',(.79,-.02),(.60,-.23),(.32,-.29)),
 ('L',(.82,-.83)),('C',(.87,-.88),(.84,-.92),(.78,-.92)),
 ('L',(.39,-.92)),('C',(.34,-.92),(.30,-.90),(.27,-.86)),
 ('L',(-.12,-.30)),('C',(-.21,-.20),(-.15,-.06),(-.02,-.06)),
 ('L',(.01,-.06)),('C',(.22,-.06),(.36,.06),(.36,.27)),
 ('C',(.36,.45),(.21,.57),(-.01,.57)),
 ('C',(-.24,.57),(-.40,.43),(-.40,.18)),('L',(-.40,-.86)),
 ('C',(-.40,-.90),(-.43,-.93),(-.47,-.93)),('L',(-.77,-.93)),
 ('C',(-.81,-.93),(-.84,-.90),(-.84,-.86))])
FINAL={'name':'Ribbon','subtitle':'A continuous filmstrip becomes a soft, distinctive R.','loops':[RIBBON],'color':'96E8CF'}

def field(scene,color='101C27'):
    # Full bleed planar background: no icon outline, fake OS mask, or frame.
    bpy.ops.mesh.primitive_plane_add(size=200,location=(0,0,-.15))
    ob=bpy.context.object; ob.name='BACKGROUND | full-bleed midnight'
    m=design.material('Full-bleed field | '+color,color);p=m.node_tree.nodes.get('Principled BSDF')
    p.inputs['Roughness'].default_value=1; p.inputs['Metallic'].default_value=0; p.inputs['Coat Weight'].default_value=0
    p.inputs['Specular IOR Level'].default_value=0
    ob.data.materials.append(m);return ob

def render_png(scene,name,transparent=True):
    scene.render.film_transparent=transparent
    scene.render.image_settings.color_mode='RGBA' if transparent else 'RGB'
    scene.render.filepath=str(OUT/name)
    bpy.ops.render.render(write_still=True)

def main():
    startup=list(bpy.data.scenes)
    s,ob,src=design.setup_scene('ribbon',FINAL,res=1024)
    s.name='Reel | Ribbon | final'
    for other in startup:bpy.data.scenes.remove(other)
    s.cycles.samples=64;s.cycles.seed=17
    ob.modifiers['Edge radius | 0.018 units'].width=.022
    ob.modifiers['Edge radius | 0.018 units'].name='Satin edge | 0.022 units'
    s['design_revision']='ribbon-v2'
    s['source']='build_blender.py + scene_helpers.py. All logo curves original.'
    ob['description']='One continuous open ribbon forms the stem, circular shoulder and swept leg of R.'
    # A gentle material value change follows the filmstrip, rather than adding
    # a glow, decorative stripe, or imitated operating-system glass.
    m=ob.data.materials[0];n=m.node_tree.nodes;l=m.node_tree.links;p=n.get('Principled BSDF')
    p.inputs['Metallic'].default_value=.30;p.inputs['Roughness'].default_value=.30
    tex=n.new('ShaderNodeTexCoord');sep=n.new('ShaderNodeSeparateXYZ');r=n.new('ShaderNodeValToRGB')
    r.name='Jade to seafoam | quiet enamel value'
    r.color_ramp.elements[0].color=(*design.linear('55B99F'),1)
    r.color_ramp.elements[1].color=(*design.linear('BBF6D8'),1)
    l.new(tex.outputs['Generated'],sep.inputs[0]);l.new(sep.outputs['Y'],r.inputs[0]);l.new(r.outputs[0],p.inputs['Base Color'])
    render_png(s,'reelclient-mark-transparent-1024.png')
    bg=field(s);render_png(s,'reelclient-app-icon-1024.png',False);bg.hide_render=True
    # The flat pass uses the original editable zero-depth contours, not a
    # silhouette traced from a shaded render. This preserves exact geometry.
    ob.hide_render=True;src.hide_set(False);src.hide_render=False;depth=src.data.extrude;src.data.extrude=0
    src.data.materials.clear();src.data.materials.append(design.material('Flat white','FFFFFF',True));s.cycles.samples=64
    render_png(s,'reelclient-mark-flat-1024.png')
    src.data.materials.clear();src.data.materials.append(design.material('Flat ink | 132D31','132D31',True))
    render_png(s,'reelclient-mark-ink-1024.png')
    src.data.extrude=depth;src.hide_render=True;src.hide_set(True);ob.hide_render=False;s.cycles.samples=64
    # Leave a useful final icon scene, with relative output and no external files.
    bg.hide_render=False;s.render.film_transparent=False;s.render.image_settings.color_mode='RGB'
    s.render.filepath='//reelclient-app-icon-1024.png'
    for item in bpy.context.selected_objects:item.select_set(False)
    ob.select_set(True);bpy.context.view_layer.objects.active=ob
    design.svg('reelclient-mark',FINAL)
    vector=(OUT/'reelclient-mark.svg').read_text()
    for name,fill in [('reelclient-mark.svg','#96E8CF'),('reelclient-mark-white.svg','#FFFFFF'),('reelclient-mark-template.svg','#FFFFFF'),('reelclient-mark-ink.svg','#132D31')]:
        (OUT/name).write_text(vector.replace('currentColor',fill))
    for image in list(bpy.data.images):
        if image.source=='VIEWER':bpy.data.images.remove(image)
    # Scene-only export excludes workstation/window and file-browser records.
    bpy.data.libraries.write(str(OUT/'reelclient-logo.blend'),{s},fake_user=True,compress=False)
    (OUT/'geometry.json').write_text(json.dumps(FINAL,indent=2))

if __name__=='__main__':main()
