"""Blender scene helpers for the original Reel Ribbon logo. No external assets."""
import bpy,bmesh,math,json,sys
from pathlib import Path
from mathutils import Vector
ROOT=Path(__file__).resolve().parent

def path(commands):
    pts=[]; pos=None
    for cmd,*p in commands:
        if cmd in ('M','L'):
            pos=p[0]; pts.append(pos)
        elif cmd=='C':
            a=pos; b,c,d=p
            for i in range(1,41):
                t=i/40; u=1-t
                pts.append(tuple(u*u*u*a[j]+3*u*u*t*b[j]+3*u*t*t*c[j]+t*t*t*d[j] for j in (0,1)))
            pos=d
    return pts

def linear(hex):
    a=[int(hex[i:i+2],16)/255 for i in (0,2,4)]
    return tuple(v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4 for v in a)

def material(name,color,flat=False):
    m=bpy.data.materials.new(name); m.use_nodes=True
    n=m.node_tree.nodes; l=m.node_tree.links
    if flat:
        n.clear(); e=n.new('ShaderNodeEmission'); e.inputs[0].default_value=(*linear(color),1)
        out=n.new('ShaderNodeOutputMaterial'); l.new(e.outputs[0],out.inputs[0]); return m
    bs=n.get('Principled BSDF'); bs.inputs['Base Color'].default_value=(*linear(color),1)
    bs.inputs['Metallic'].default_value=.22; bs.inputs['Roughness'].default_value=.29
    bs.inputs['Coat Weight'].default_value=.24; bs.inputs['Coat Roughness'].default_value=.26
    return m

def light(scene,name,loc,power,size):
    d=bpy.data.lights.new(name,'AREA'); o=bpy.data.objects.new(name,d); scene.collection.objects.link(o)
    o.location=loc; o.rotation_euler=(Vector((0,0,0))-o.location).to_track_quat('-Z','Y').to_euler()
    d.energy=power; d.shape='DISK'; d.size=size

def setup_scene(key,desc,res=768):
    s=bpy.data.scenes.new('Reel | '+desc['name']); bpy.context.window.scene=s
    s.render.engine='CYCLES'; s.cycles.device='CPU'; s.cycles.samples=32; s.cycles.use_denoising=True
    s.render.resolution_x=s.render.resolution_y=res; s.render.resolution_percentage=100
    s.render.image_settings.file_format='PNG'; s.render.image_settings.color_mode='RGBA'; s.render.image_settings.color_depth='8'
    s.render.film_transparent=True; s.view_settings.view_transform='Standard'; s.view_settings.look='None'
    w=bpy.data.worlds.new('Soft studio'); w.use_nodes=True; w.node_tree.nodes['Background'].inputs[0].default_value=(.15,.17,.18,1)
    w.node_tree.nodes['Background'].inputs[1].default_value=.32; s.world=w
    d=bpy.data.curves.new(desc['name']+' | original 2D contours','CURVE'); d.dimensions='2D'; d.resolution_u=16; d.fill_mode='BOTH'; d.extrude=.075
    for poly in desc['loops']:
        sp=d.splines.new('POLY'); sp.points.add(len(poly)-1)
        for p,(x,y) in zip(sp.points,poly): p.co=(x,y,0,1)
        sp.use_cyclic_u=True
    src=bpy.data.objects.new('SOURCE | original editable contours',d); s.collection.objects.link(src); src.hide_render=True; src.hide_set(True)
    ob=bpy.data.objects.new('MARK | '+desc['name'],d.copy()); s.collection.objects.link(ob); ob.select_set(True); bpy.context.view_layer.objects.active=ob
    bpy.ops.object.convert(target='MESH'); ob=bpy.context.object
    bm=bmesh.new(); bm.from_mesh(ob.data); bmesh.ops.remove_doubles(bm,verts=list(bm.verts),dist=1e-6); bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces)); bm.to_mesh(ob.data); bm.free()
    ob.data.materials.append(material('Satin enamel | '+desc['color'],desc['color']))
    for p in ob.data.polygons: p.use_smooth=True
    b=ob.modifiers.new('Edge radius | 0.018 units','BEVEL'); b.width=.018; b.segments=5; b.limit_method='ANGLE'; b.harden_normals=True
    n=ob.modifiers.new('Face weighted normals','WEIGHTED_NORMAL'); n.keep_sharp=True
    ob['origin']='Original custom geometry in build_blender.py. No font, traced icon, downloaded model or texture.'
    light(s,'Key | upper left',(-3,4,6),520,4.5); light(s,'Fill | lower right',(3,-2,5),150,5)
    camd=bpy.data.cameras.new('Orthographic front'); cam=bpy.data.objects.new('CAMERA | orthographic front',camd); s.collection.objects.link(cam)
    cam.location=(0,0,8); cam.rotation_euler=(0,0,0); camd.type='ORTHO'; camd.ortho_scale=2.75; s.camera=cam
    s['purpose']='Reel logo artwork, unmasked.'
    return s,ob,src

def svg(key,desc):
    d=[]
    for poly in desc['loops']:
        d.append('M'+'L'.join(f'{512+x*1024/2.75:.3f},{512-y*1024/2.75:.3f}' for x,y in poly)+'Z')
    (ROOT/(key+'.svg')).write_text('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><title>Reel '+desc['name']+' original logo</title><path fill="currentColor" fill-rule="evenodd" d="'+''.join(d)+'"/></svg>\n')
