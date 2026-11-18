#!/usr/bin/env python3
"""Official NVIDIA FBX -> Blender Cycles diffuse lightmaps -> Godot scenery.

    python3 pipeline.py all --graffitty <path> --preset preview
    python3 pipeline.py pack --graffitty <path>   # -> dist/bistro.pck, bistro.json
    python3 pipeline.py test --graffitty <path>   # headless route, settings and pack tests
    python3 pipeline.py run --graffitty <path> -- --editor   # any Godot command in the project

The scenes use res://worlds/bistro paths, so the Godot stages run in a
Graffitty checkout's Godot project. For the length of the run this repository
is linked into it at frontends/godot/project/worlds/bistro; the link is removed
afterwards. --graffitty defaults to $GRAFFITTY_SOURCE.
The original archive is never modified.
"""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile
import zlib

ROOT = Path(__file__).resolve().parent


def main():
    argv = sys.argv[1:]
    extra = argv[argv.index('--') + 1:] if '--' in argv else []
    argv = argv[:argv.index('--')] if '--' in argv else argv
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('stage', choices=['extract', 'preprocess', 'bake', 'denoise', 'export', 'godot', 'all', 'pack', 'test', 'run'])
    p.add_argument('--preset', choices=['preview', 'production'], default='preview')
    p.add_argument('--blender', default=shutil.which('blender') or 'blender')
    p.add_argument('--godot', default=shutil.which('godot') or 'godot')
    p.add_argument('--graffitty', type=Path, default=os.environ.get('GRAFFITTY_SOURCE'),
        help='Graffitty checkout (default: $GRAFFITTY_SOURCE)')
    p.add_argument('--out', type=Path, default=ROOT / 'dist', help='Pack output directory (default: dist/)')
    p.add_argument('--limit', type=int, help='Diagnostic only: bake first N chunks; export refuses incomplete bakes')
    a = p.parse_args(argv)
    if a.limit is not None and a.limit < 1:
        p.error("--limit must be positive")
    if a.graffitty is None:
        p.error('pass --graffitty <Graffitty checkout> or set GRAFFITTY_SOURCE')
    project = (a.graffitty / 'frontends/godot/project').resolve()
    if not (project / 'project.godot').is_file():
        p.error(f'{a.graffitty} is not a Graffitty checkout (no frontends/godot/project/project.godot)')
    config = json.loads((ROOT / 'pipeline.json').read_text())
    build = ROOT / '.build' / a.preset
    build.mkdir(parents=True, exist_ok=True)
    (ROOT / '.build' / '.gdignore').touch()
    stages = ['extract', 'preprocess', 'bake', 'denoise', 'export', 'godot'] if a.stage == 'all' else [a.stage]
    with linked(project):
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
            elif stage == 'pack':
                subprocess.run([a.godot, '--headless', '--path', str(project), '--script',
                    'res://worlds/bistro/tools/build_pack.gd', '--', str(a.out.resolve())], check=True, cwd=project)
                print(a.out.resolve() / 'bistro.pck')
            elif stage == 'godot':
                for tool in ['import_baked.gd', 'link_destinations.gd']:
                    subprocess.run([a.godot, '--headless', '--path', str(project), '--script',
                        f'res://worlds/bistro/tools/{tool}', '--', a.preset], check=True, cwd=project)
            elif stage == 'test':
                pack = a.out.resolve() / 'bistro.pck'
                if not pack.is_file():
                    raise SystemExit(f'{pack} is missing; run pipeline.py pack first')
                for test, args in [('bistro_routes_smoke.gd', []), ('bistro_settings_smoke.gd', []),
                        ('preview.gd', [f'--world-pack={pack}', '--tabs=9', '--shell=/bin/sh', '--no-focus-skip'])]:
                    print(f'--- {test}', flush=True)
                    godot_test([a.godot, '--headless', '--path', str(project), '--script',
                        f'res://worlds/bistro/tests/{test}', '--', *args], project, test)
            elif stage == 'run':
                subprocess.run([a.godot, '--path', str(project), *extra], check=True, cwd=project)
            else:
                args = [a.blender, '--background', '--python-exit-code', '1', '--threads', '8', '--python',
                    str(ROOT / 'tools' / 'blender_pipeline.py'), '--', stage, a.preset]
                if a.limit:
                    args += ['--limit', str(a.limit)]
                subprocess.run(args, check=True, cwd=ROOT)


def godot_test(command, project, name):
    """Run a test script; Godot exits 0 when the script fails to parse, so script errors fail too."""
    proc = subprocess.Popen(command, cwd=project, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, errors='replace')
    errors = 0
    for line in proc.stdout:
        print(line, end='', flush=True)
        errors += line.startswith('SCRIPT ERROR:')
    if proc.wait() != 0 or errors:
        raise SystemExit(f'{name} failed (exit {proc.returncode}, {errors} script errors)')


@contextlib.contextmanager
def linked(project):
    """Link this repository at res://worlds/bistro for the length of the run."""
    worlds = project / 'worlds'
    link = worlds / 'bistro'
    if os.path.lexists(link):
        if link.resolve() != ROOT:
            raise SystemExit(f'{link} exists and is not this repository; remove it first')
        yield  # Someone else's link; leave it as it is.
        return
    worlds.mkdir(exist_ok=True)
    if os.name == 'nt':
        # A junction needs no Developer Mode or administrator rights.
        subprocess.run(['cmd', '/c', 'mklink', '/J', str(link), str(ROOT)], check=True, stdout=subprocess.DEVNULL)
    else:
        link.symlink_to(ROOT, target_is_directory=True)
    try:
        yield
    finally:
        if os.name == 'nt':
            os.rmdir(link)  # Removes the junction, not the repository behind it.
        else:
            link.unlink()

if __name__ == '__main__':
    main()
