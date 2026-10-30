#!/usr/bin/env python3
"""Author original video, two external AAC renditions and genuine WebVTT."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont
import multiaudio_contract as contract

parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True)
args = parser.parse_args()
root = Path(args.output).resolve()
repository = Path(__file__).resolve().parents[3]
if root == repository or repository in root.parents or not root.name.startswith("reel-tvos-fixture-"):
    raise SystemExit("Use a new disposable reel-tvos-fixture-* directory outside source.")
if root.exists() or not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
    raise SystemExit("Output must be new; ffmpeg and ffprobe are required.")
subprocess.run([sys.executable, str(Path(__file__).with_name("prepare-fixtures.py")), "--output", str(root)], check=True)
folder = root / "multiaudio"
folder.mkdir(mode=0o700)
for name in ["video", "en", "es", "captions"]:
    (folder / name).mkdir(mode=0o700)


def run(arguments):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error"] + arguments, check=True)


def probe(path, entries=None):
    arguments = ["ffprobe", "-v", "error"]
    arguments += ["-show_entries", entries] if entries else ["-show_streams", "-show_format"]
    return json.loads(subprocess.check_output(arguments + ["-of", "json", str(path)]))


label = Image.new("RGBA", (1280, 720))
draw = ImageDraw.Draw(label)
draw.rectangle((35, 120, 1245, 340), fill=(0, 0, 0, 220))
draw.text((640, 155), "MULTI AUDIO FIXTURE", font=ImageFont.load_default(size=62), anchor="mt", fill="white")
draw.text((640, 250), "ORIGINAL GENERATED VIDEO", font=ImageFont.load_default(size=35), anchor="mt", fill="white")
label.save(folder / "video-label.png")
video = folder / "video-source.mp4"
run(["-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24", "-i", str(folder / "video-label.png"),
     "-filter_complex_threads", "1", "-filter_complex", "[0:v][1:v]overlay=0:0[v]", "-map", "[v]", "-an", "-t", "120",
     "-c:v", "libx264", "-threads", "2", "-preset", "ultrafast", "-crf", "25", "-g", "96", "-keyint_min", "96", "-sc_threshold", "0", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(video)])
run(["-i", str(video), "-an", "-c:v", "copy", "-hls_time", "4", "-hls_playlist_type", "vod", "-hls_segment_filename", str(folder / "video/segment%03d.ts"), str(folder / "video/index.m3u8")])
video_probe = probe(video)
video_stream = next(s for s in video_probe["streams"] if s["codec_type"] == "video")
codec = video_stream.get("mime_codec_string")
if not isinstance(codec, str) or not re.fullmatch(r"avc1\.[0-9a-fA-F]{6}", codec):
    raise SystemExit("The encoded video must expose its real AVC codec descriptor.")
assert len(video_probe["streams"]) == 1 and video_stream["codec_name"] == "h264"

audio_audit = []
for language, tag, frequency in [("en", "eng", 440), ("es", "spa", 880)]:
    audio = folder / f"{language}-source.m4a"
    run(["-f", "lavfi", "-i", f"sine=frequency={frequency}:sample_rate=48000", "-t", "120", "-vn", "-c:a", "aac", "-ac", "2", "-b:a", "96k", "-metadata:s:a:0", f"language={tag}", str(audio)])
    run(["-i", str(audio), "-vn", "-c:a", "copy", "-hls_time", "4", "-hls_playlist_type", "vod", "-hls_segment_filename", str(folder / language / "segment%03d.ts"), str(folder / language / "index.m3u8")])
    audio_probe = probe(audio)
    stream = audio_probe["streams"][0]
    assert len(audio_probe["streams"]) == 1 and stream["codec_name"] == "aac" and stream["channels"] == 2 and stream["sample_rate"] == "48000"
    audio_audit.append({"path": str(audio.relative_to(root)), "language": language, "expectedToneHz": frequency, "probe": audio_probe})


def rates(name):
    playlist = folder / name / "index.m3u8"
    lines = playlist.read_text().splitlines()
    durations = [float(line.split(":", 1)[1].rstrip(",")) for line in lines if line.startswith("#EXTINF:")]
    segments = [playlist.parent / line for line in lines if line and not line.startswith("#")]
    assert len(durations) == len(segments) and abs(sum(durations) - 120) < 0.1
    return max(p.stat().st_size * 8 / duration for p, duration in zip(segments, durations)), sum(p.stat().st_size * 8 for p in segments) / sum(durations)


video_peak, video_average = rates("video")
audio_rates = [rates(name) for name in ["en", "es"]]
peak = math.ceil((video_peak + max(r[0] for r in audio_rates)) * 1.05)
average = math.ceil(video_average + max(r[1] for r in audio_rates))
for audio in [1, 3]:
    for subtitle in [-1, 2]:
        lines = ["#EXTM3U", "#EXT-X-VERSION:6", "#EXT-X-INDEPENDENT-SEGMENTS"]
        for index, language, name in [(1, "en", "English synthetic 440 Hz"), (3, "es", "Español sintético 880 Hz")]:
            default = "YES" if index == audio else "NO"
            lines.append(f'#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="{name}",DEFAULT={default},AUTOSELECT=YES,LANGUAGE="{language}",CHANNELS="2",URI="{language}/index.m3u8"')
        lines.append(f'#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="captions",NAME="Synthetic multi-audio captions",DEFAULT={"YES" if subtitle == 2 else "NO"},AUTOSELECT=YES,FORCED=NO,LANGUAGE="en",URI="captions/index.m3u8"')
        lines += [f'#EXT-X-STREAM-INF:BANDWIDTH={peak},AVERAGE-BANDWIDTH={average},RESOLUTION=1280x720,FRAME-RATE=24.000,CODECS="{codec},mp4a.40.2",AUDIO="audio",SUBTITLES="captions",CLOSED-CAPTIONS=NONE', "video/index.m3u8", ""]
        (folder / f"master-a{audio}-s{subtitle}.m3u8").write_text("\n".join(lines))

first_pts = next(s["start_pts"] for s in probe(folder / "video/segment000.ts", "stream=codec_type,start_pts")["streams"] if s["codec_type"] == "video")
(folder / "captions/index.m3u8").write_text("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:120\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:120.000,\ncue.vtt\n#EXT-X-ENDLIST\n")
(folder / "captions/cue.vtt").write_text(f"WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:{first_pts}\n\n00:00:00.000 --> 00:02:00.000\n{contract.CAPTION}\n")
manifest = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob("*")) if p.is_file()}
audit = {"scope": "Original video, two AAC tone renditions and genuine WebVTT; no spoken-language or physical speaker claim", "video": video_probe, "audio": audio_audit, "peakBandwidth": peak, "averageBandwidth": average, "files": manifest}
(root / "multiaudio-media.json").write_text(json.dumps(audit, indent=2) + "\n")
print(root)
