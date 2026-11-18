# Bistro: development notes

To install the world, see [README.md](README.md). To rebuild the baked scenery
from the NVIDIA archive, see [PIPELINE.md](PIPELINE.md).

A night-time bistro: the wine-cafe interior sits inside the street's bistro
building, with an open entrance and views through the windows. All lighting is
baked in Blender; there are no runtime lights or global illumination.

## Files

| Path | Purpose |
| --- | --- |
| `plugin.json` | World manifest; its entry is `world.tscn` |
| `world.tscn` | Entry scene: nine terminal destinations and their view poses |
| `BistroBaked.gd` | World script: night grading, environment, route overrides |
| `lighting.json` | Terminal shade (`terminal_shade`) read at load |
| `navgraph.json` | Source navigation graph; the pipeline copies it into the bake |
| `pipeline.json`, `pipeline.py`, `tools/` | Archive → Blender bake → Godot pipeline |
| `tools/baked_light.gdshader` | Runtime material: `albedo(UV) × lighting(UV2) + emission(UV)` |
| `shared/placements.json` | Renderer-neutral destinations, exported from `world.tscn` by `tools/export_native_placements.gd` |
| `tests/preview.gd` | Materials, routes, visibility, and screenshot check |
| `generated/preview/` | Baked scenery, routes, and graph (asset, not in Git) |

To move a destination, edit `world.tscn` in Godot, then refresh
`shared/placements.json` from the Graffitty checkout:

```sh
cd frontends/godot/project
godot --headless --path . --script res://worlds/bistro/tools/export_native_placements.gd \
  -- "$PWD/worlds/bistro/shared/placements.json"
```

The export records the scene's SHA-256 and applies the same destination
reorientation as `BistroBaked.gd`. Rerun the pipeline's `godot` stage so camera
routes reach the new pose.

## Validate

From this repository:

```sh
python3 pipeline.py run --graffitty <checkout> -- --headless \
  --script res://worlds/bistro/tests/preview.gd -- --tabs=9 --shell=/bin/sh --no-focus-skip
```

It checks baked materials on every surface, no runtime lights or SDFGI, unit sky
intensity, the cafe doorway and every destination link and curved route against
the scenery's triangles, nine unobstructed terminal views, and connected routes.
It uses a temporary configuration directory. Omit `--headless` to also save
screenshots of every destination and four review views to
`frontends/godot/project/.cache/bistro/preview/`.

Graffitty's own tests cover flights (`tests/bistro_flight_smoothness_smoke.gd`)
and the rendered `night-lighting-tab-flight` replay
(`uv run tools/test_dashboard.py record night-lighting-tab-flight`).

## Night grading

`tools/baked_light.gdshader` adds a small, cool display-only shadow fill:
`fill × (0.45, 0.65, 1.0) × exp(-L / 0.25)`. `BistroBaked.gd` sets:

| Setting | Exterior | Interior |
| --- | --- | --- |
| Shadow fill | 0.012 | 0.018 |
| Baked-light gain | 0.65 | 0.5 |

Visible emission scale is 0.1 and glow intensity 0.12. Local lamps reveal
surfaces while unlit streets and foliage stay in shadow. The sky uses background
intensity 1 to match the baked, unshaded exposure; the physical-sky default
overflows tone mapping and blooms gaps between buildings.

These controls live in the shader and `BistroBaked.gd`, survive regeneration, and
need no rebake. Changing the lighting itself requires a new bake.

## Terminals and camera

`world.tscn` sets `terminal_backdrop_alpha = 0.85`: panes draw that alpha while
the terminal texture stays transparent. Effects start from Graffitty's
`presets/flat.conf`, like Castle.

Flights between the outdoor `cafe-awning` and `terrace-tables` views go directly
between the displayed endpoints when a seven-ray clearance check passes;
otherwise they use the navigation graph. The `cafe-terrace` ↔ `square-reverse`
crossing uses a raised, clearance-checked arc.

## Source provenance

`original/Bistro_v5_2.zip` is the official archive; `original/lighting-notes/`
holds its README, changelog, scene scripts, and the embedded FBX lights. The
directory has a `.gdignore`, so Godot does not import it.

Attribution: Amazon Lumberyard, Amazon Lumberyard Bistro, NVIDIA ORCA, July 2017,
CC BY 4.0 (`LICENSE.txt`).
