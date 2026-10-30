#!/usr/bin/env python3
"""Generate opt-in, original track-output media outside the repository."""
import argparse
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True)
args = parser.parse_args()
root = Path(args.output).resolve()
repository = Path(__file__).resolve().parents[3]
if root == repository or repository in root.parents or not root.name.startswith("reel-tvos-fixture-"):
    raise SystemExit("Use a new disposable reel-tvos-fixture-* directory outside the repository.")
if root.exists() or not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
    raise SystemExit("Output must be new; ffmpeg and ffprobe are required.")
subprocess.run([sys.executable, str(Path(__file__).with_name("prepare-fixtures.py")), "--output", str(root)], check=True)
tracks = root / "tracks"
tracks.mkdir(mode=0o700)
for variant, label, frequency in [("original440", "ORIGINAL VERSION", 440), ("original880", "ORIGINAL VERSION", 880), ("alternate880", "ALTERNATE VERSION", 880)]:
    folder = tracks / variant
    folder.mkdir(mode=0o700)
    video = folder / "source.mp4"
    # Version labels belong to the synthetic source image. The caption cue is
    # intentionally absent here: only native WebVTT may render that cue later.
    label_image = Image.new("RGBA", (1280, 720))
    draw = ImageDraw.Draw(label_image)
    draw.rectangle((30, 110, 1250, 340), fill=(0, 0, 0, 220))
    draw.text((640, 150), label, font=ImageFont.load_default(size=64), anchor="mt", fill="white")
    draw.text((640, 255), f"SYNTHETIC {frequency} HZ", font=ImageFont.load_default(size=40), anchor="mt", fill="white")
    label_image.save(folder / "version-label.png")
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24", "-f", "lavfi", "-i", f"sine=frequency={frequency}:sample_rate=48000", "-i", str(folder / "version-label.png"), "-filter_complex_threads", "1", "-filter_complex", "[0:v][2:v]overlay=0:0[v]", "-map", "[v]", "-map", "1:a:0", "-t", "60", "-c:v", "libx264", "-threads", "2", "-preset", "ultrafast", "-crf", "25", "-g", "96", "-keyint_min", "96", "-sc_threshold", "0", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ac", "2", "-b:a", "96k", "-metadata:s:a:0", "language=eng", "-movflags", "+faststart", str(video)], check=True)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(video), "-c", "copy", "-hls_time", "4", "-hls_playlist_type", "vod", "-hls_segment_filename", str(folder / "segment%03d.ts"), str(folder / "video.m3u8")], check=True)
    probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(video)]))
    codec = next(s["mime_codec_string"] for s in probe["streams"] if s["codec_type"] == "video")
    media_lines = (folder / "video.m3u8").read_text().splitlines()
    durations = [float(line.split(":", 1)[1].rstrip(",")) for line in media_lines if line.startswith("#EXTINF:")]
    segments = [folder / line for line in media_lines if line and not line.startswith("#")]
    assert len(durations) == len(segments) and abs(sum(durations) - 60) < 0.1
    bandwidth = math.ceil(max(p.stat().st_size * 8 / duration for p, duration in zip(segments, durations)) * 1.05)
    average = math.ceil(sum(p.stat().st_size * 8 for p in segments) / sum(durations))
    for mode in ["on", "off"]:
        lines = ["#EXTM3U", "#EXT-X-VERSION:6", f'#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Synthetic {frequency} Hz",DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="en"']
        if mode == "on":
            lines += ['#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="captions",NAME="Synthetic captions",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,LANGUAGE="en",URI="subtitles.m3u8"']
        stream = f'#EXT-X-STREAM-INF:BANDWIDTH={bandwidth},AVERAGE-BANDWIDTH={average},RESOLUTION=1280x720,FRAME-RATE=24.000,CODECS="{codec},mp4a.40.2",AUDIO="audio",CLOSED-CAPTIONS=NONE'
        if mode == "on": stream += ',SUBTITLES="captions"'
        (folder / f"master-{mode}.m3u8").write_text("\n".join(lines + [stream, "video.m3u8", ""]))
    (folder / "subtitles.m3u8").write_text("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:60\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:60.000,\ncaptions.vtt\n#EXT-X-ENDLIST\n")
    segment_probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type,start_pts", "-of", "json", str(folder / "segment000.ts")]))
    first_video_pts = next(s["start_pts"] for s in segment_probe["streams"] if s["codec_type"] == "video")
    (folder / "captions.vtt").write_text(f"WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:{first_video_pts}\n\n00:00:00.000 --> 00:01:00.000\nREEL TV CAPTION CHECK\n")
print(root)
