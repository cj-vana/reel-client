#!/usr/bin/env python3
"""Inventory and decode the generated synthetic track fixtures read-only."""
import argparse
from array import array
import hashlib
import json
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--media", required=True)
args = parser.parse_args()
root = Path(args.media).resolve(strict=True)
repository = Path(__file__).resolve().parents[3]
if root == repository or repository in root.parents or not root.name.startswith("reel-tvos-fixture-"):
    raise SystemExit("Expected generated TV fixture media outside the repository.")
results = []
sample = root / "sample.mp4"
if sample.is_symlink() or not sample.resolve(strict=True).is_relative_to(root): raise SystemExit("Unsafe generic sample")
sample_probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(sample)]))
sample_audio = [stream for stream in sample_probe["streams"] if stream.get("codec_type") == "audio"]
assert len(sample_audio) == 1 and sample_audio[0]["codec_name"] == "aac" and sample_audio[0].get("tags", {}).get("language") == "eng"
results.append({"path": "sample.mp4", "languageTag": "eng", "probe": sample_probe, "sha256": hashlib.sha256(sample.read_bytes()).hexdigest()})
for variant, frequency in [("original440", 440), ("original880", 880), ("alternate880", 880)]:
    folder = root / "tracks" / variant
    for name in ["source.mp4", "segment000.ts"]:
        path = folder / name
        if path.is_symlink() or not path.resolve(strict=True).is_relative_to(root): raise SystemExit("Unsafe fixture path")
        probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "stream=index,codec_name,codec_type,width,height,channels,sample_rate:stream_tags=language:format=duration", "-of", "json", str(path)]))
        streams = probe["streams"]
        assert any(s.get("codec_name") == "h264" and s.get("width") == 1280 and s.get("height") == 720 for s in streams)
        assert any(s.get("codec_name") == "aac" and s.get("channels") == 2 and s.get("sample_rate") == "48000" for s in streams)
        assert not any(s.get("codec_type") == "subtitle" for s in streams)
        assert next(s for s in streams if s.get("codec_type") == "audio").get("tags", {}).get("language") == "eng"
        pcm = array("f", subprocess.check_output(["ffmpeg", "-v", "error", "-i", str(path), "-vn", "-t", "2", "-ac", "1", "-ar", "48000", "-f", "f32le", "pipe:1"]))
        samples = pcm[24000:72000]
        assert len(samples) == 48000
        observed = sum(a <= 0 < b for a, b in zip(samples, samples[1:]))
        assert abs(observed - frequency) <= 3, (variant, name, observed)
        results.append({"path": str(path.relative_to(root)), "expectedToneHz": frequency, "decodedZeroCrossingHz": observed, "probe": probe, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    on, off = [(folder / f"master-{m}.m3u8").read_text() for m in ["on", "off"]]
    media_lines = (folder / "video.m3u8").read_text().splitlines()
    durations = [float(line.split(":", 1)[1].rstrip(",")) for line in media_lines if line.startswith("#EXTINF:")]
    segments = [folder / line for line in media_lines if line and not line.startswith("#")]
    peak = max(p.stat().st_size * 8 / seconds for p, seconds in zip(segments, durations))
    average = sum(p.stat().st_size * 8 for p in segments) / sum(durations)
    for manifest in [on, off]:
        declared_peak = int(re.search(r"(?<!-)BANDWIDTH=(\d+)", manifest)[1])
        declared_average = int(re.search(r"AVERAGE-BANDWIDTH=(\d+)", manifest)[1])
        assert declared_peak >= peak and abs(declared_average - average) < 2
    assert 'TYPE=SUBTITLES' in on and 'DEFAULT=YES' in on and 'FORCED=NO' in on and 'SUBTITLES="captions"' in on
    assert 'TYPE=SUBTITLES' not in off and 'SUBTITLES=' not in off
    vtt = (folder / "captions.vtt").read_text()
    assert re.match(r"WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:\d+\n", vtt)
    assert "REEL TV CAPTION CHECK" in vtt and "00:01:00.000" in vtt
files = {}
for path in sorted(root.rglob("*")):
    if path.is_file():
        if path.is_symlink() or not path.resolve().is_relative_to(root): raise SystemExit("Unsafe fixture inventory")
        files[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
print(json.dumps({"result": "passed", "scope": "Original synthetic files and decoded AAC frequencies; no physical speaker/spoken-language claim", "media": results, "files": files}, indent=2))
