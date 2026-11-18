#!/usr/bin/env python3
"""Official NVIDIA FBX -> Blender Cycles diffuse lightmaps -> Godot scenery.

Run through the Graffitty checkout's link to this repository:
    python3 <graffitty>/worlds/bistro/pipeline.py all --preset preview
The original archive is never modified.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile
import zlib

ROOT = Path(__file__).resolve().parent
# The scenes use res://worlds/bistro paths, so the Godot stage runs in the
# Graffitty project that links this repository at worlds/bistro.
DEFAULT_PROJECT = Path(os.path.abspath(__file__)).parents[2] / 'frontends/godot/project'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('stage', choices=['extract', 'preprocess', 'bake', 'denoise', 'export', 'godot', 'all'])
    p.add_argument('--preset', choices=['preview', 'production'], default='preview')
    p.add_argument('--blender', default=shutil.which('blender') or 'blender')
    p.add_argument('--godot', default=shutil.which('godot') or 'godot')
    p.add_argument('--project', type=Path, default=DEFAULT_PROJECT,
        help='Graffitty Godot project whose worlds/bistro is this repository')
    p.add_argument('--limit', type=int, help='Diagnostic only: bake first N chunks; export refuses incomplete bakes')
    a = p.parse_args()
    if a.limit is not None and a.limit < 1:
        p.error("--limit must be positive")
    project = a.project.resolve()
    if not (project / 'project.godot').is_file():
        p.error(f'{project} is not a Godot project; pass --project <graffitty>/frontends/godot/project')
    if (project / 'worlds/bistro').resolve() != ROOT:
        p.error(f'{project}/worlds/bistro does not point to {ROOT}')
    config = json.loads((ROOT / 'pipeline.json').read_text())
    build = ROOT / '.build' / a.preset
    build.mkdir(parents=True, exist_ok=True)
    (ROOT / '.build' / '.gdignore').touch()
    stages = ['extract', 'preprocess', 'bake', 'denoise', 'export', 'godot'] if a.stage == 'all' else [a.stage]
    for stage in stages:
        print(f'\n=== {stage} ({a.preset}) ===', flush=True)
        if stage == 'extract':
            archive = ROOT / config['archive']
            with archive.open('rb') as source:
                digest = hashlib.file_digest(source, 'sha256').hexdigest()
            destination = ROOT / '.build' / 'source'
            destination.mkdir(exist_ok=True)
            with zipfile.ZipFile(archive) as z:
                for member in z.infolist():
                    target = (destination / member.filename).resolve()
                    if not target.is_relative_to(destination.resolve()):
                        raise ValueError(f'Unsafe archive path: {member.filename}')
                    if member.is_dir():
                        target.mkdir(parents=True, exist_ok=True)
                    else:
                        crc = 0
                        if target.exists() and target.stat().st_size == member.file_size:
                            with target.open('rb') as existing:
                                for block in iter(lambda: existing.read(1024*1024), b''):
                                    crc = zlib.crc32(block, crc)
                            if crc == member.CRC:
                                continue
                        target.parent.mkdir(parents=True, exist_ok=True)
                        with z.open(member) as source, target.open('wb') as out:
                            shutil.copyfileobj(source, out)
            (build / 'source.json').write_text(json.dumps({'archive': config['archive'], 'sha256': digest,
                'sources': config['sources']}, indent=2) + '\n')
        elif stage == 'denoise':
            subprocess.run([a.blender, '--background', '--python-exit-code', '1', '--threads', '8',
                '--python', str(ROOT/'tools/denoise_lightmaps.py'), '--', a.preset], check=True, cwd=ROOT)
        elif stage == 'godot':
            for tool in ['import_baked.gd', 'link_destinations.gd']:
                subprocess.run([a.godot, '--headless', '--path', str(project), '--script',
                    f'res://worlds/bistro/tools/{tool}', '--', a.preset], check=True, cwd=project)
        else:
            args = [a.blender, '--background', '--python-exit-code', '1', '--threads', '8', '--python',
                str(ROOT / 'tools' / 'blender_pipeline.py'), '--', stage, a.preset]
            if a.limit:
                args += ['--limit', str(a.limit)]
            subprocess.run(args, check=True, cwd=ROOT)


if __name__ == '__main__':
    main()
