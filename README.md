# Bistro world for Graffitty

[bistro-tour-github.webm](https://github.com/user-attachments/assets/1ce4f500-2013-4af8-a3d6-31b282a518e4)

A night-time bistro, indoors and out, as the space around your Graffitty panes.

- **Needs:** Graffitty on macOS, Windows, or Linux. Android and iOS do not load
  downloaded worlds.
- **Size:** about 400 MB to download.
- **Trust:** a world runs scripts inside Graffitty. Install it only from this
  repository's Releases page.

## Install

```sh
gft world install bistro
```

This downloads the latest `bistro-world.zip`, checks it against the release's
`SHA256SUMS`, and replaces `bistro/` in Graffitty's worlds folder
(`~/.local/share/graffitty/worlds`, or `$XDG_DATA_HOME/graffitty/worlds` when
that is set). Add `--version v0.0.1` for a specific release. Then restart
Graffitty and choose **View → World → Bistro**.

### Install by hand

1. Download `bistro-world.zip` from the
   [latest release](https://github.com/graffitty/bistro-world/releases/latest).
2. Extract it into Graffitty's worlds folder.

   macOS and Linux:

   ```sh
   mkdir -p ~/.local/share/graffitty/worlds
   unzip ~/Downloads/bistro-world.zip -d ~/.local/share/graffitty/worlds
   ```

   Windows (PowerShell):

   ```powershell
   $worlds = "$HOME\.local\share\graffitty\worlds"
   New-Item -ItemType Directory -Force $worlds | Out-Null
   Expand-Archive "$HOME\Downloads\bistro-world.zip" $worlds
   ```

   You now have:

   ```text
   ~/.local/share/graffitty/worlds/
   └── bistro/
       ├── bistro.pck
       ├── bistro.json
       └── LICENSE.txt
   ```

3. Restart Graffitty.
4. Choose **View → World → Bistro**.

Nothing goes in `client.toml` for this: Graffitty lists every world it finds in
that folder.

## Make it the default

Add this to `client.toml` (`~/.config/graffitty/client.toml`), then restart
Graffitty:

```toml
[world]
path = "bistro"
```

`bistro` is the world's id; Graffitty finds it in the worlds folder.

To go back, set `path = "flat-3d"` or remove the line.

## Adjust it

Bistro reads its own table in `client.toml`:

```toml
[worlds.bistro.terminal_window]
blur_radius = 8 # Blur the scenery behind translucent panes; 0–32.
```

See *World settings* in the Graffitty documentation for every option.

## Update

Run `gft world install bistro` again, then restart Graffitty.
It replaces the whole `bistro/` folder.

By hand: delete `~/.local/share/graffitty/worlds/bistro`, extract the new zip as
in [Install by hand](#install-by-hand), then restart Graffitty.

Always replace `bistro.pck` and `bistro.json` together. Graffitty updates do not
update this world.

## Uninstall

1. Remove the `[world] path` line from `client.toml` if you added it.
2. Delete `~/.local/share/graffitty/worlds/bistro`.

## If it does not work

| What you see | Cause | Fix |
| --- | --- | --- |
| No **Bistro** under **View → World** | The files are not where Graffitty looks | Check that `bistro.pck` and `bistro.json` sit together in `worlds/bistro/`, then restart |
| Still not listed | `XDG_DATA_HOME` is set | Use `$XDG_DATA_HOME/graffitty/worlds` instead |
| Graffitty opens in a flat world | The pack does not match your Graffitty version | Install the release whose notes name your Graffitty version |
| Listed twice, or loads nothing | An older copy elsewhere, or a stray `plugin.json` in the folder | Keep only the three files above |

A world that fails to load never blocks Graffitty: it falls back to the built-in
world.

## Check the download (optional)

```sh
cd ~/Downloads
shasum -a 256 -c SHA256SUMS
```

`SHA256SUMS` is on the same release page.

## Credits and license

The scenery is built from *Amazon Lumberyard Bistro*, Open Research Content
Archive (ORCA), Amazon Lumberyard, 2017:
<https://developer.nvidia.com/orca/amazon-lumberyard-bistro>.
The exterior environment map comes from HDRI Haven.

The scenery terms (CC BY 4.0) ship as `LICENSE.txt` inside the zip. The code in
this repository is under the Apache License 2.0 (`LICENSE`).

---

# For maintainers: publish a release

This repository holds code, data, and documentation only. Assets are kept
outside Git and are not tracked by DVC; `.gitignore` excludes them. The pack and
its manifest are release assets, never committed files: the pack is about
400 MB and GitHub allows up to 2 GiB per release asset.

## Set up a working copy

The scenes use `res://worlds/bistro/...` paths and Graffitty's shared world
kit, so the Godot stages run in a Graffitty checkout's Godot project. Point the
pipeline at your checkout with `--graffitty <checkout>` or `GRAFFITTY_SOURCE`.
For the length of each run, `pipeline.py` links this repository at
`frontends/godot/project/worlds/bistro` (ignored by Graffitty's Git) and removes
the link afterwards. To open the Godot editor with the world linked:

```sh
python3 pipeline.py run --graffitty <checkout> -- --editor
```

Put the assets back in place:

| Path | Contents | Needed for |
| --- | --- | --- |
| `generated/preview/` | Baked scenery, routes, and graph, plus the pipeline's GLB, PNG, and EXR outputs | Running and packing the world |
| `original/Bistro_v5_2.zip`, `original/lighting-notes/` | Official NVIDIA archive and its notes | Rebuilding with [PIPELINE.md](PIPELINE.md) |

## Build the pack

From the Graffitty checkout, with the same Godot version Graffitty ships (4.7):

```sh
godot --headless --path frontends/godot/project --script tools/build_packs.gd -- --worlds-only
```

This writes `bistro.pck` and `bistro.json` to
`frontends/godot/project/dist/`. The same command builds Castle first and stops
if Castle's assets are missing.

## Make the zip

From this repository:

```sh
VERSION=v1.0.0
DIST=<graffitty>/frontends/godot/project/dist
rm -rf release && mkdir -p release/bistro
cp "$DIST/bistro.pck" "$DIST/bistro.json" release/bistro/
cp LICENSE.txt release/bistro/
(cd release && zip -r bistro-world.zip bistro && shasum -a 256 bistro-world.zip > SHA256SUMS)
```

Rules the installer depends on:

- The zip is always named `bistro-world.zip`; the release tag carries the version.
- The zip holds one top-level folder named `bistro`.
- `bistro.pck` and `bistro.json` share the folder and the base name.
- No `plugin.json` in the folder. Graffitty would read the folder as a loose
  world and skip the pack.
- `bistro.json` keeps `"id": "bistro"`, and its `api` and `engine` match the
  Graffitty release you built against.
- Tag a commit that contains `install.sh` and `install.ps1`.
  `gft world install bistro --version <tag>` runs the installer committed at
  that tag, so the steps always match the zip they install.

## Test before uploading

1. Extract the zip into `~/.local/share/graffitty/worlds` on a machine with the
   packaged Graffitty app, not a development checkout. A checkout has the loose
   world files and hides anything missing from the pack.
2. Choose **View → World → Bistro**, then switch tabs and sessions.
3. Set it as the default in `client.toml`, restart, and confirm it opens.

## Upload

```sh
gh release create "$VERSION" \
  release/bistro-world.zip release/SHA256SUMS \
  --repo graffitty/bistro-world \
  --title "Bistro $VERSION" \
  --notes "Built for Graffitty <version>. Godot 4.7, world API 1."
```

Name the Graffitty version in the notes: users pick the release that matches
their app.

## Change the world itself

- [DEVELOPMENT.md](DEVELOPMENT.md): lighting, validation, and authoring tools.
- [PIPELINE.md](PIPELINE.md): the NVIDIA archive → Blender bake → Godot pipeline.
