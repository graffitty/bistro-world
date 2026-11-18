"""Blender worker; invoke through ../pipeline.py. Z-up authoring, Y-up glTF.

Lightmaps contain DIFFUSE DIRECT+INDIRECT, without material COLOR. UV0 keeps
original texture detail; UV1 (Godot UV2) holds non-overlapping lighting charts.
"""
import argparse
from collections import defaultdict
import hashlib
import json
import math
from pathlib import Path
import sys
import time
import bpy
import numpy as np
from mathutils import Vector

ROOT = Path(__file__).resolve().parent.parent
CONFIG = json.loads((ROOT / 'pipeline.json').read_text())
parser = argparse.ArgumentParser()
parser.add_argument('stage', choices=['preprocess', 'bake', 'export'])
parser.add_argument('preset', choices=CONFIG['presets'])
parser.add_argument('--limit', type=int)
ARGS = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
SETTINGS = CONFIG['presets'][ARGS.preset]
BUILD = ROOT / '.build' / ARGS.preset
OUT = ROOT / 'generated' / ARGS.preset
SOURCE = ROOT / '.build/source/Bistro_v5_2'
BUILD.mkdir(parents=True, exist_ok=True)
OUT.mkdir(parents=True, exist_ok=True)


def write(path, data):
    path.write_text(json.dumps(data, indent=2) + '\n')


def bounds(obj):
    corners = [obj.matrix_world @ Vector(v) for v in obj.bound_box]
    lo = Vector(tuple(min(v[i] for v in corners) for i in range(3)))
    hi = Vector(tuple(max(v[i] for v in corners) for i in range(3)))
    return lo, hi


def select(objects):
    bpy.ops.object.select_all(action='DESELECT')
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]


def material_setup():
    textures = {p.name.lower(): p for p in (SOURCE / 'Textures').rglob('*') if p.is_file()}
    records = {}
    for mat in list(bpy.data.materials):
        if not mat.use_nodes:
            continue
        nodes, links = mat.node_tree.nodes, mat.node_tree.links
        bsdf = next((n for n in nodes if n.type == 'BSDF_PRINCIPLED'), None)
        if not bsdf:
            continue
        uv = nodes.new('ShaderNodeUVMap')
        uv.uv_map = 'SurfaceUV'
        base = None
        for node in list(nodes):
            if node.type == 'TEX_IMAGE' and node.image:
                links.new(uv.outputs['UV'], node.inputs['Vector'])
                if '_basecolor.' in node.image.filepath.lower():
                    base = node.image
        prefix = Path(base.filepath).stem.rsplit('_', 1)[0] if base else mat.name.split('.')[0]
        emission_path = textures.get((prefix + '_Emissive.dds').lower())
        emission = bpy.data.images.load(str(emission_path), check_existing=True) if emission_path else None
        if emission:
            tex = nodes.new('ShaderNodeTexImage')
            tex.image = emission
            links.new(uv.outputs['UV'], tex.inputs['Vector'])
            links.new(tex.outputs['Color'], bsdf.inputs['Emission Color'])
            bsdf.inputs['Emission Strength'].default_value = CONFIG['emission_strength']
            # Analytic bake helpers sit at bulbs. Their emissive glass must
            # transmit shadow rays; an opaque imported shell traps their light.
            if any(word in mat.name for word in ('Lantern', 'Light', 'Lamp')) and 'Shopsign' not in mat.name:
                output = next(n for n in nodes if n.type == 'OUTPUT_MATERIAL')
                light_path = nodes.new('ShaderNodeLightPath')
                transparent = nodes.new('ShaderNodeBsdfTransparent')
                mix = nodes.new('ShaderNodeMixShader')
                links.new(light_path.outputs['Is Shadow Ray'], mix.inputs[0])
                links.new(bsdf.outputs['BSDF'], mix.inputs[1])
                links.new(transparent.outputs[0], mix.inputs[2])
                links.new(mix.outputs[0], output.inputs['Surface'])
        # Bake a diffuse irradiance approximation even on metallic surfaces.
        for link in list(bsdf.inputs['Metallic'].links):
            links.remove(link)
        bsdf.inputs['Metallic'].default_value = 0
        bsdf.inputs['Roughness'].default_value = .7
        # The NVIDIA normal maps are DirectX; invert green for Blender.
        for normal in [n for n in nodes if n.type == 'NORMAL_MAP']:
            normal.uv_map = 'SurfaceUV'
            if normal.inputs['Color'].links:
                source = normal.inputs['Color'].links[0].from_socket
                separate = nodes.new('ShaderNodeSeparateXYZ')
                combine = nodes.new('ShaderNodeCombineXYZ')
                invert = nodes.new('ShaderNodeMath')
                invert.operation = 'SUBTRACT'
                invert.inputs[0].default_value = 1
                links.new(source, separate.inputs[0])
                links.new(separate.outputs[0], combine.inputs[0])
                links.new(separate.outputs[1], invert.inputs[1])
                links.new(invert.outputs[0], combine.inputs[1])
                links.new(separate.outputs[2], combine.inputs[2])
                links.new(combine.outputs[0], normal.inputs['Color'])
        target = nodes.new('ShaderNodeTexImage')
        target.name = 'BakeTarget'
        records[mat.name] = {'base_image': base.name if base else None,
            'emission_image': emission.name if emission else None,
            'color': list(bsdf.inputs['Base Color'].default_value),
            'emission_strength': CONFIG['emission_strength'] if emission else 0}
    return records


def fixture_lights(objects):
    """Analytical bake helpers sampled from official fixture mesh geometry.

    These are authored Cycles watt values, not NVIDIA analytical-light metadata.
    Small mesh islands/UV seams are grouped spatially; avoid object-origin lights.
    """
    sources = {'LanternEmissive', 'Emissive_StreetLight', 'Spotlight_Glass_Emissive',
               'Paris_Ceiling_Lamp', 'Paris_Wall_Light_Interior',
               'MASTER_Interior_01_Paris_Lantern1'}
    colors = {'Orange': (1,.36,.06), 'Red': (1,.07,.025), 'White': (1,.9,.7),
              'Pink': (1,.12,.65), 'Blue': (.08,.38,1), 'Green': (.12,1,.4)}
    records = []
    positions = []
    for obj in objects:
        for slot, mat in enumerate(obj.data.materials):
            if not mat:
                continue
            name = mat.name.split('.')[0]
            string = 'StringLights' in name
            if name not in sources and not string:
                continue
            vertices = set(v for p in obj.data.polygons if p.material_index == slot for v in p.vertices)
            clusters = []
            for index in sorted(vertices):
                p = obj.matrix_world @ obj.data.vertices[index].co
                for lo, hi in clusters:
                    if all(lo[i]-.28 <= p[i] <= hi[i]+.28 for i in range(3)):
                        for i in range(3):
                            lo[i] = min(lo[i],p[i])
                            hi[i] = max(hi[i],p[i])
                        break
                else:
                    clusters.append([p.copy(),p.copy()])
            for lo, hi in clusters:
                if (hi-lo).length > 2.5:
                    continue
                point = (lo+hi)*.5
                if any((point-other).length < .65 for other in positions):
                    continue
                positions.append(point.copy())
                # Pole lanterns reuse the white STRING bulb material in NVIDIA's
                # FBX. Classify by fixture object too: 12 W left these 7 m
                # high lanterns with barely any pavement illumination.
                street_lantern = 'Paris_StreetLight' in obj.name
                kind = 'street_lantern' if street_lantern else ('string' if string else 'other')
                color = next((v for k,v in colors.items() if k in name), (1,.72,.4)) if string and not street_lantern else (1,.72,.4)
                power = CONFIG['fixture_watts'][kind]
                # Use the actual lower fixture bound, not a fixed offset from
                # its centre (that left several helpers inside the shade).
                source_center = point.copy()
                if street_lantern or name in {'Spotlight_Glass_Emissive','Paris_Ceiling_Lamp','Paris_Wall_Light_Interior','MASTER_Interior_01_Paris_Lantern1'}:
                    point.z = lo.z - (.18 if street_lantern else .08)
                lamp = bpy.data.lights.new('BakeFixture', 'POINT')
                lamp.energy = power
                lamp.color = color
                lamp.shadow_soft_size = .08
                instance = bpy.data.objects.new('BakeFixture',lamp)
                bpy.context.scene.collection.objects.link(instance)
                instance.location = point
                records.append({'source_object':obj.name,'source_material':name,
                    'position_blender':list(point),'fixture_center_blender':list(source_center),'watts':power,'color':color,'kind':kind})
    return records


def preprocess():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    groups = []
    matrices = []
    for filename in CONFIG['sources']:
        before = set(bpy.data.objects)
        bpy.ops.import_scene.fbx(filepath=str(SOURCE / filename), use_anim=False)
        added = set(bpy.data.objects) - before
        root = next(o for o in added if o.parent is None and o.type == 'EMPTY')
        matrices.append([list(row) for row in root.matrix_world])
        if groups:
            root.matrix_world = exterior_matrix.copy()
        else:
            exterior_matrix = root.matrix_world.copy()
        bpy.context.view_layer.update()
        groups.append(sorted((o for o in added if o.type == 'MESH'), key=lambda o: o.name))
    exterior_boxes = [bounds(o) for o in groups[0]]
    removed = []
    buckets = defaultdict(list)
    for group_index, objects in enumerate(groups):
        for obj in objects:
            lo, hi = bounds(obj)
            reason = None
            if group_index and obj.name.startswith('Bistro_Research_Exterior_'):
                if any((lo-a).length < .03 and (hi-b).length < .03 for a,b in exterior_boxes):
                    reason = 'duplicate cafe exterior'
            if obj.name == 'dOORS_2' or obj.name.endswith('_3a60013'):
                reason = 'open shared entrance'
            if obj.name.startswith('Bistro_Research_Exterior_Paris_Building_01_') and any(
                    m and m.name.split('.')[0] == 'MASTER_Glass_Exterior' for m in obj.data.materials):
                reason = 'remove opaque exterior window cover'
            if reason:
                removed.append({'name': obj.name, 'reason': reason})
                bpy.data.objects.remove(obj, do_unlink=True)
                continue
            world = obj.matrix_world.copy()
            obj.parent = None
            obj.matrix_world = world
            # Normalize original UV name; retain precisely its coordinates.
            while len(obj.data.uv_layers) > 1:
                obj.data.uv_layers.remove(obj.data.uv_layers[-1])
            if not obj.data.uv_layers:
                obj.data.uv_layers.new(name='SurfaceUV')
            obj.data.uv_layers[0].name = 'SurfaceUV'
            center = (lo+hi)*.5
            tile = CONFIG['tile_metres']
            name = 'Cafe' if group_index else f'Street_{math.floor(center.x/tile)+10}_{math.floor(center.y/tile)+10}'
            buckets[name].append(obj)
    for obj in list(bpy.data.objects):
        if obj.type != 'MESH':
            bpy.data.objects.remove(obj, do_unlink=True)
    fixtures = fixture_lights([o for objects in buckets.values() for o in objects])
    records = material_setup()
    chunks = []
    for name, objects in sorted(buckets.items()):
        print('UNWRAP', name, len(objects), flush=True)
        select(objects)
        bpy.ops.object.join()
        obj = bpy.context.object
        obj.name = name
        bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
        obj.data.uv_layers.new(name='LightmapUV')
        obj.data.uv_layers.active_index = 1
        resolution = SETTINGS['cafe_resolution'] if name == 'Cafe' else SETTINGS['resolution']
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
        # FBX splits vertices at UV/normal seams. Weld coincident geometry before
        # charting, otherwise millions of tiny islands waste the entire atlas.
        bpy.ops.mesh.remove_doubles(threshold=0.00001)
        bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.00005,
                                 margin_method='FRACTION', rotate_method='AXIS_ALIGNED')
        bpy.ops.object.mode_set(mode='OBJECT')
        mesh = obj.data
        mesh.calc_loop_triangles()
        uv = np.array([v.uv[:] for v in mesh.uv_layers[1].data])
        triangles = np.array([t.loops[:] for t in mesh.loop_triangles])
        points = uv[triangles]
        a, b = points[:,1]-points[:,0], points[:,2]-points[:,0]
        occupancy = float(np.abs(a[:,0]*b[:,1]-a[:,1]*b[:,0]).sum()/2)
        if occupancy < .1 or occupancy > 1.01:
            raise RuntimeError(f'Invalid lightmap atlas coverage: {name} {occupancy}')
        chunks.append({'name': name, 'uv_coverage': occupancy, 'resolution': resolution, 'lightmap': f'{name}.exr',
                       'polygons': len(obj.data.polygons)})
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'CPU'
    scene.cycles.samples = SETTINGS['samples']
    scene.cycles.max_bounces = SETTINGS['bounces']
    scene.cycles.seed = 0
    scene.cycles.use_adaptive_sampling = False
    scene.world = bpy.data.worlds.new('Night')
    scene.world.use_nodes = True
    background = scene.world.node_tree.nodes.get('Background')
    background.inputs['Color'].default_value = (.25,.35,.6,1)
    background.inputs['Strength'].default_value = CONFIG['world_strength']
    scene.render.bake.use_pass_direct = True
    scene.render.bake.use_pass_indirect = True
    scene.render.bake.use_pass_color = False
    scene.render.bake.margin = 2
    manifest = {'source': json.loads((BUILD/'source.json').read_text()), 'blender': bpy.app.version_string,
                'worker_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'config': CONFIG, 'preset': ARGS.preset, 'settings': SETTINGS,
                'fixtures': fixtures, 'original_root_matrices': matrices, 'removed': removed, 'materials': records, 'chunks': chunks}
    write(BUILD/'manifest.json', manifest)
    bpy.ops.wm.save_as_mainfile(filepath=str(BUILD/'preprocessed.blend'))


def bake():
    bpy.ops.wm.open_mainfile(filepath=str(BUILD/'preprocessed.blend'))
    manifest = json.loads((BUILD/'manifest.json').read_text())
    if manifest['config'] != CONFIG:
        raise RuntimeError('Configuration changed: run preprocess and bake again')
    fingerprint = hashlib.sha256((BUILD/'manifest.json').read_bytes()).hexdigest()
    state_path = BUILD/'bake-state.json'
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    if state.get('fingerprint') != fingerprint:
        state = {'fingerprint': fingerprint, 'completed': {}}
    chunks = manifest['chunks'][:ARGS.limit] if ARGS.limit else manifest['chunks']
    for chunk in chunks:
        name = chunk['name']
        target = OUT/chunk['lightmap']
        if name in state['completed'] and target.exists():
            print('RESUME', name, flush=True)
            continue
        obj = bpy.data.objects[name]
        select([obj])
        img = bpy.data.images.new('Lightmap_'+name, width=chunk['resolution'], height=chunk['resolution'], float_buffer=True)
        img.colorspace_settings.name = 'Non-Color'
        for mat in obj.data.materials:
            if mat:
                node = mat.node_tree.nodes['BakeTarget']
                node.image = img
                mat.node_tree.nodes.active = node
        print('BAKE', name, flush=True)
        start = time.monotonic()
        bpy.ops.object.bake(type='DIFFUSE', pass_filter={'DIRECT','INDIRECT'}, use_clear=True, uv_layer='LightmapUV')
        pixels = np.empty(len(img.pixels), dtype=np.float32)
        img.pixels.foreach_get(pixels)
        rgb = pixels.reshape(-1, 4)[:, :3]
        if not np.isfinite(rgb).all() or float(rgb.max()) <= 0:
            raise RuntimeError(f'Empty or invalid lightmap: {name}')
        stats = {'max': float(rgb.max()), 'mean': float(rgb.mean()),
                 'nonzero_fraction': float(np.count_nonzero(rgb.max(axis=1)) / len(rgb))}
        img.filepath_raw = str(target)
        img.file_format = 'OPEN_EXR'
        img.save()
        state['completed'][name] = {'seconds': time.monotonic()-start, 'bytes': target.stat().st_size, 'pixels': stats}
        write(state_path, state)
        bpy.data.images.remove(img)
    print('BAKE_COMPLETED', len(state['completed']), '/', len(manifest['chunks']), flush=True)


def export():
    manifest = json.loads((BUILD/'manifest.json').read_text())
    if manifest['config'] != CONFIG:
        raise RuntimeError('Configuration changed: run preprocess and bake again')
    state = json.loads((BUILD/'bake-state.json').read_text())
    fingerprint = hashlib.sha256((BUILD/'manifest.json').read_bytes()).hexdigest()
    if state['fingerprint'] != fingerprint or any(c['name'] not in state['completed'] or not (OUT/c['lightmap']).exists() for c in manifest['chunks']):
        raise RuntimeError('Incomplete/stale bake: run bake before export')
    bpy.ops.wm.open_mainfile(filepath=str(BUILD/'preprocessed.blend'))
    texture_dir = OUT/'textures'
    texture_dir.mkdir(exist_ok=True)
    exported = {}
    exported_names = {}
    def image_file(name):
        if not name:
            return ''
        if name in exported_names:
            return exported_names[name]
        img = bpy.data.images[name]
        source_path = Path(bpy.path.abspath(img.filepath)).resolve()
        key = str(source_path)
        if key not in exported:
            # Load DDS pixels before changing the output path (images are lazy).
            if not img.size[0] or not len(img.pixels):
                raise RuntimeError(f'Missing source texture: {source_path}')
            filename = hashlib.sha256(source_path.name.encode()).hexdigest()[:12] + '.png'
            img.filepath_raw = str(texture_dir/filename)
            img.file_format = 'PNG'
            img.save()
            exported[key] = 'textures/'+filename
        exported_names[name] = exported[key]
        img.buffers_free()
        return exported[key]
    for name, record in manifest['materials'].items():
        record['base_texture'] = image_file(record['base_image'])
        record['emission_texture'] = image_file(record['emission_image'])
        mat = bpy.data.materials[name]
        mat.node_tree.nodes.clear()
        out = mat.node_tree.nodes.new('ShaderNodeOutputMaterial')
        bsdf = mat.node_tree.nodes.new('ShaderNodeBsdfPrincipled')
        mat.node_tree.links.new(bsdf.outputs['BSDF'],out.inputs['Surface'])
    select([o for o in bpy.data.objects if o.type == 'MESH'])
    bpy.ops.export_scene.gltf(filepath=str(OUT/'geometry.glb'), export_format='GLB',
        use_selection=True, export_texcoords=True, export_normals=True, export_tangents=False,
        export_materials='EXPORT', export_animations=False, export_cameras=False, export_lights=False,
        export_yup=True)
    manifest['export_worker_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    manifest['bake'] = state
    write(OUT/'manifest.json', manifest)


{'preprocess': preprocess, 'bake': bake, 'export': export}[ARGS.stage]()
