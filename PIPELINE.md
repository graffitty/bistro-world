# NVIDIA original → Blender bake → Godot

`pipeline.py` is the entry point. Geometry and textures come from the official
`original/Bistro_v5_2.zip`.

Requirements: Python 3.11+, Blender 5.2 (Cycles, built-in NumPy and glTF exporter),
and Godot 4.7. Blender and Godot must be on PATH, or supplied with
`--blender /path/to/blender --godot /path/to/godot`.

Run it through the Graffitty checkout's `worlds/bistro` link (see the README's
maintainer section). The Godot stage uses `<graffitty>/frontends/godot/project`;
pass `--project` to use another location.

```sh
python3 <graffitty>/worlds/bistro/pipeline.py all --preset preview
```

`world.tscn` is the world's entry and loads the preview bake from
`generated/preview/`. Rebuilding the preview replaces that bake; restart
Graffitty to load it.

## Stages

The same process can be run one stage at a time:

```sh
python3 <graffitty>/worlds/bistro/pipeline.py extract --preset preview
python3 <graffitty>/worlds/bistro/pipeline.py preprocess --preset preview
python3 <graffitty>/worlds/bistro/pipeline.py bake --preset preview
python3 <graffitty>/worlds/bistro/pipeline.py denoise --preset preview
python3 <graffitty>/worlds/bistro/pipeline.py export --preset preview
python3 <graffitty>/worlds/bistro/pipeline.py godot --preset preview
```

1. **Extract** validates archive paths and checks existing files against their ZIP
   CRC before reuse. The official ZIP stays untouched. Its SHA-256 and chosen FBX
   filenames are recorded in `.build/preview/source.json`. Extraction goes into
   `.build/source/Bistro_v5_2/`, excluded from Godot import.
2. **Preprocess** imports `BistroExterior.fbx` and `BistroInterior_Wine.fbx` into
   Blender. Both contain the same building coordinate system but different root
   scale/translation. The cafe root is normalized to the exterior root. Matching
   exterior meshes in the cafe are removed within a 3 cm bounds tolerance;
   entrance door leaves and opaque exterior cafe window covers are removed.
   Every removal and both original root matrices are recorded in the manifest.
   Original cameras and analytical lights are discarded for night.
3. **Bake** uses Cycles **CPU**, with fixed seed, original emissive texture masks,
   dim blue environment fill, and configured diffuse bounce count. Bake-only point
   lights are clustered from the official bulb/lantern meshes for more reliable
   sampling; their source meshes, coordinates, colors, and watt values are recorded
   in the manifest. These are authored Cycles helpers, not original NVIDIA lights. The materials
   restore emissive textures missing from FBX import (including lanterns), invert
   DirectX normal-map green, and keep original texture UVs explicitly bound to
   `SurfaceUV` (including the normal-map tangent basis). Emissive fixture glass
   transmits shadow rays so helper lights can escape it. Ceiling/sign helpers sit
   below the fixture's measured lower bound. Pole lanterns reuse a white string
   bulb material in the FBX: their object name classifies them separately, with
   600 W helpers below the lower housing instead of 12 W string lights. True
   string bulbs remain 12 W; other helpers use 180 W. These artistic Cycles values
   are editable in `fixture_watts`, not measured electrical power. Meshes are grouped into spatial chunks, with a separate cafe
   atlas; `LightmapUV` is unwrapped independently. The bake contains diffuse
   direct + indirect lighting **without albedo**. Maps are linear floating-point
   EXR. Completed chunks are checkpointed, and matching bakes resume. Empty or
   non-finite lightmaps are rejected. `--limit 1` is a diagnostic partial bake;
   export refuses incomplete or stale results.
4. **Denoise** runs Blender’s CPU OpenImageDenoise compositor on the HDR
   atlases. Raw inputs remain in `.build/preview/raw-lightmaps/`; checksums and
   the denoising script hash are checkpointed. It smooths sampling noise, but
   narrow chart boundaries can still bleed at low resolution. No GPU bake or
   GPU denoiser is required.
5. **Export** writes geometry with both UV sets to GLB and converts original
   albedo/emission DDS textures to PNG. `generated/preview/manifest.json` records
   material mappings, chunks, source hash, Blender version, settings, preprocessing
   script hash, bake times and pixel statistics. Godot adds the denoising records and its version
   to the final manifest. Color textures retain their
   original resolution independently of the lighting atlas.
6. **Godot** uses `GLTFDocument` directly in headless mode, avoiding application
   editor plugins. It verifies UV2 on every surface and builds materials using
   `tools/baked_light.gdshader`: `albedo(UV) × lighting(UV2) + emission(UV)`.
   Color textures receive GPU S3TC compression; linear HDR lightmaps stay
   floating point. Textures are embedded in compressed `scenery.scn`; the GLB/PNG/EXR are authoring
   intermediates, not runtime imports. It copies the source `navgraph.json` next
   to the scenery.
7. **Camera routes** (`tools/link_destinations.gd`, run after it by the `godot` stage) fit the graph to the baked
   triangles. It drops graph edges that now pass through geometry, then links
   each destination to every node it can see through a 0.2 m clearance tube, as
   Castle's destinations are linked. Pairs whose route still turns corners get a curve in
   `camera_routes.json`: a raised B-spline of the route, a crane arc over the
   roofs, the route's legs with clear fillets, or one or two wide rounded
   turns in the open that are not much longer than the shortest route,
   whichever has the least length × peak curvature (the peak turn rate of a
   fixed-duration flight). Session switches fly these curves too.
   `tests/preview.gd` checks every link and curve against the triangles;
   Graffitty's `tests/bistro_flight_smoothness_smoke.gd` measures the flights.

`pipeline.json` contains the artistic settings and preview/production presets.
Preview is the shipped bake. `all --preset production` writes a higher-resolution
bake to `generated/production/` with separate checkpoints; point `world.tscn`
at it to use it. Changing configuration
requires preprocessing and rebaking; the export stage rejects mismatched manifests.

## What is reproduced, and what is approximated

The geometry includes the **wine interior**. The terminal placements in
`world.tscn` and the source `navgraph.json` are authored inputs, not NVIDIA metadata.
The original root-transform correction is explicitly recorded rather than inferred
from the converted GLBs.

NVIDIA supplies emissive textures and a Falcor wine scene script that multiplies
emission by 1000. Its exposure/units do not transfer directly to Cycles. Our
emission strength and night fill are explicit artistic choices in `pipeline.json`,
not a claim to reproduce the reference screenshot exactly. There are no runtime
fixture lights or bounced-light calculations at runtime.

This is **diffuse-only baked lighting**. Metals are treated as diffuse while
baking; view-dependent glossy reflections, wine absorption/refraction, and moving
object shadows are not reproduced. Alpha cutout is retained for foliage; glass is
an approximation. The source archive and all wine geometry remain available for
more advanced materials later. UV packing at preview resolution sacrifices small
props and may show seams; production maps and further atlas subdivision can
improve that. Lighting changes require a new bake.

## Validation

See [DEVELOPMENT.md](DEVELOPMENT.md#validate).

Source attribution: Amazon Lumberyard Bistro / NVIDIA ORCA, CC BY 4.0. The
original archive includes LICENSE.txt; retain attribution when distributing assets.

