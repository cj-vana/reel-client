#!/usr/bin/env python3
"""Generate only original synthetic media in a new disposable directory."""
import argparse
import importlib.util
import hashlib
import json
from pathlib import Path
import sys
import subprocess

sys.dont_write_bytecode = True
parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True)
parser.add_argument("--silent", action="store_true", help="Generate digital silence for episode/player UI checks")
args = parser.parse_args()
repository = Path(__file__).resolve().parents[3]
output = Path(args.output).resolve()
if repository == output or repository in output.parents or not output.name.startswith("reel-tvos-fixture-"):
    raise SystemExit("Use a new reel-tvos-fixture-* directory outside the repository.")
output.mkdir(mode=0o700)
source = repository / "apps/apple/qa/prepare_synthetic_fixtures.py"
spec = importlib.util.spec_from_file_location("tv_fixture_generator", source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.ROOT = output
module.ART = output / "artwork"
module.HLS = output / "hls"
module.artwork()
sample = output / "sample.mp4"
subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24",
    "-f", "lavfi", "-i", "anullsrc=sample_rate=48000:channel_layout=mono" if args.silent else "sine=frequency=220:sample_rate=48000", "-t", "24", "-c:v", "libx264", "-threads", "2", "-preset", "veryfast",
    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k", "-metadata:s:a:0", "language=eng", "-movflags", "+faststart", str(sample)], check=True)
module.HLS.mkdir()
subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(sample), "-c:v", "libx264", "-threads", "2", "-g", "96", "-c:a", "copy",
    "-hls_time", "4", "-hls_playlist_type", "vod", "-hls_segment_filename", str(module.HLS / "segment%03d.ts"), str(module.HLS / "index.m3u8")], check=True)
if args.silent:
    (output / "silent-fixture.json").write_text(json.dumps({"kind": "reel-tvos-silent-fixture", "sampleSHA256": hashlib.sha256(sample.read_bytes()).hexdigest()}))
print(output)
