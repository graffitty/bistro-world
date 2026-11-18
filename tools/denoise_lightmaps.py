"""CPU OpenImageDenoise through Blender's compositor; retains raw EXR inputs.

Run through pipeline.py. Atlas denoising smooths sampling noise; low-resolution
chart boundaries can still bleed, so production resolution remains preferable.
"""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import bpy
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
preset = sys.argv[sys.argv.index('--')+1]
build = ROOT/'.build'/preset
out_dir = ROOT/'generated'/preset
manifest = json.loads((build/'manifest.json').read_text())
bake = json.loads((build/'bake-state.json').read_text())
fingerprint = hashlib.sha256((build/'manifest.json').read_bytes()).hexdigest()
if bake['fingerprint'] != fingerprint or len(bake['completed']) != len(manifest['chunks']):
    raise RuntimeError('Complete the current bake before denoising')
raw_dir = build/'raw-lightmaps'
filtered_dir = build/'denoised-lightmaps'
raw_dir.mkdir(exist_ok=True)
filtered_dir.mkdir(exist_ok=True)
state_path = build/'denoise-state.json'
state = json.loads(state_path.read_text()) if state_path.exists() else {}
worker_hash = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()

def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.device = 'CPU'
scene.cycles.samples = 1
scene.render.resolution_x = 1
scene.render.resolution_y = 1
scene.render.resolution_percentage = 100
scene.render.compositor_device = 'CPU'
camera = bpy.data.objects.new('Camera',bpy.data.cameras.new('Camera'))
scene.collection.objects.link(camera)
scene.camera = camera
nodes = bpy.data.node_groups.new('Lightmap Denoising','CompositorNodeTree')
scene.compositing_node_group = nodes
source = nodes.nodes.new('CompositorNodeImage')
denoise = nodes.nodes.new('CompositorNodeDenoise')
denoise.inputs['HDR'].default_value = True
output = nodes.nodes.new('CompositorNodeOutputFile')
output.directory = str(filtered_dir)
output.file_output_items.new('RGBA','Image')
output.format.media_type = 'IMAGE'
output.format.file_format = 'OPEN_EXR'
output.format.color_depth = '32'
output.save_as_render = False
nodes.links.new(source.outputs['Image'],denoise.inputs['Image'])
nodes.links.new(denoise.outputs['Image'],output.inputs['Image'])
for chunk in manifest['chunks']:
    path = out_dir/chunk['lightmap']
    raw = raw_dir/path.name
    previous = state.get(chunk['name'],{})
    current = digest(path)
    if current == previous.get('output_sha256') and raw.exists():
        if previous.get('worker_sha256') == worker_hash:
            print('DENOISE_RESUME',chunk['name'],flush=True)
            continue
    else:
        shutil.copyfile(path,raw)
    source.image = bpy.data.images.load(str(raw),check_existing=False)
    output.file_name = chunk['name']
    bpy.ops.render.render()
    filtered_path = next(filtered_dir.glob(chunk['name'] + '*Image*.exr'), filtered_dir/path.name)
    filtered = bpy.data.images.load(str(filtered_path),check_existing=False)
    width,height = filtered.size
    pixels = np.empty(width*height*4,dtype=np.float32)
    filtered.pixels.foreach_get(pixels)
    if not np.isfinite(pixels).all() or pixels.reshape(-1,4)[:,:3].max() <= 0:
        raise RuntimeError('Invalid denoised lightmap: '+chunk['name'])
    # Flatten the compositor's multilayer EXR to ordinary RGB for Godot.
    flat = bpy.data.images.new('Filtered',width=width,height=height,alpha=False,float_buffer=True)
    flat.colorspace_settings.name = 'Non-Color'
    flat.pixels.foreach_set(pixels)
    flat.file_format = 'OPEN_EXR'
    flat.filepath_raw = str(path)
    flat.save()
    state[chunk['name']] = {'raw_sha256':digest(raw),'output_sha256':digest(path),
                            'worker_sha256':worker_hash,'method':'Blender CPU OpenImageDenoise HDR'}
    state_path.write_text(json.dumps(state,indent=2)+'\n')
    bpy.data.images.remove(source.image)
    bpy.data.images.remove(filtered)
    bpy.data.images.remove(flat)
    print('DENOISED',chunk['name'],flush=True)
