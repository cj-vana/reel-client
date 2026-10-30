#!/usr/bin/env python3
"""Copy the sealed original fixture and author a local two-audio/caption MP4.

No server, simulator or application actions. The input is never changed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--input', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
source = Path(args.input).resolve(strict=True)
target = Path(args.output).resolve()
repository = Path(__file__).resolve().parents[3]
if (not source.name.startswith('reel-tvos-fixture-') or not target.name.startswith('reel-tvos-fixture-')
        or source == repository or repository in source.parents or target == repository or repository in target.parents
        or target.exists() or source == target or source in target.parents):
    raise SystemExit('Use a sealed external original fixture and a new external reel-tvos-fixture-* output.')
manifest_path = source / 'multiaudio-media.json'
if manifest_path.is_symlink():
    raise SystemExit('Symlinked manifest rejected.')
manifest = json.loads(manifest_path.read_text())
expected = manifest['files']
actual = {p.relative_to(source).as_posix() for p in source.rglob('*') if p.is_file()}
if any(p.is_symlink() for p in source.rglob('*')) or actual != set(expected) | {'multiaudio-media.json'}:
    raise SystemExit('Original fixture inventory changed.')
for name, digest in expected.items():
    path = source / name
    if not path.resolve(strict=True).is_relative_to(source) or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise SystemExit('Original fixture digest changed.')
if not shutil.which('ffmpeg') or not shutil.which('ffprobe'):
    raise SystemExit('ffmpeg and ffprobe required.')
shutil.copytree(source, target, symlinks=False)
for name, digest in expected.items():
    if hashlib.sha256((target / name).read_bytes()).hexdigest() != digest:
        raise SystemExit('Copied original changed; retain failed output.')
if (target / 'multiaudio-media.json').read_bytes() != manifest_path.read_bytes():
    raise SystemExit('Manifest changed during copy; retain failed output.')
local = target / 'multiaudio-local.mp4'
command = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', str(target / 'multiaudio/video-source.mp4'),
           '-i', str(target / 'multiaudio/en-source.m4a'), '-i', str(target / 'multiaudio/es-source.m4a'),
           '-i', str(target / 'multiaudio/captions/cue.vtt'), '-map', '0:v:0', '-map', '1:a:0', '-map', '2:a:0', '-map', '3:s:0',
           '-c:v', 'copy', '-c:a', 'copy', '-c:s', 'mov_text', '-metadata:s:a:0', 'language=eng', '-metadata:s:a:0', 'title=English synthetic 440 Hz',
           '-metadata:s:a:1', 'language=spa', '-metadata:s:a:1', 'title=Español sintético 880 Hz',
           '-metadata:s:s:0', 'language=eng', '-metadata:s:s:0', 'title=Synthetic multi-audio captions',
           # Each input marks its one stream default. With both audio tracks default, AVFoundation
           # offers only the first as an audio option, so only English stays default.
           '-disposition:a:0', 'default', '-disposition:a:1', '0', '-movflags', '+faststart', str(local)]
subprocess.run(command, check=True)
probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(local)]))
streams = probe['streams']
if ([s['codec_type'] for s in streams] != ['video', 'audio', 'audio', 'subtitle']
        or [s.get('tags', {}).get('language') for s in streams[1:3]] != ['eng', 'spa']
        or [s.get('disposition', {}).get('default') for s in streams[1:3]] != [1, 0]
        or streams[3]['codec_name'] != 'mov_text' or float(probe['format']['duration']) < 119):
    raise SystemExit('Local fixture stream contract failed; retain output as failed evidence.')
files = {p.relative_to(target).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(target.rglob('*')) if p.is_file()}
(target / 'multiaudio-local.json').write_text(json.dumps({'scope': 'Original synthetic media only; no physical speaker or spoken-language claim',
    'originalManifestSHA256': hashlib.sha256(manifest_path.read_bytes()).hexdigest(), 'localProbe': probe, 'files': files}, indent=2) + '\n')
print(target)
