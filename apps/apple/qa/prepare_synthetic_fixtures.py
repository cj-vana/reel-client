#!/usr/bin/env python3
"""Generate original local test art/audio/video without downloading any media."""
from pathlib import Path
import shutil
import subprocess

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parent
ART = ROOT / "artwork"
HLS = ROOT / "hls"
COLORS = [(66, 126, 172), (121, 99, 154), (78, 145, 133),
          (178, 121, 77), (151, 99, 119), (95, 119, 160)]
TITLES = ["NORTH OF\nNOWHERE", "THE QUIET\nEARTH", "AFTER THE\nLAST LIGHT",
          "BLUE\nHOURS", "THE LONG\nWAY HOME", "A FOREST,\nREMEMBERED"]


def font(size):
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def artwork():
    ART.mkdir(exist_ok=True)
    for index, color in enumerate(COLORS):
        backdrop = Image.new("RGB", (1440, 810), (12, 20, 31))
        draw = ImageDraw.Draw(backdrop)
        for row in range(9):
            for column in range(16):
                tint = tuple(min(255, max(0, value + (row * 5 + column * 7) % 65 - 25)) for value in color)
                x, y = column * 90, row * 90
                draw.rectangle((x + 4, y + 4, x + 85, y + 85), fill=tint)
        draw.ellipse((250 + index * 30, 100, 850 + index * 30, 700), outline=(222, 234, 245), width=10)
        draw.text((58, 52), f"REEL TEST PATTERN {index + 1}", font=font(40), fill=(240, 244, 248))
        backdrop.save(ART / f"backdrop-{index}.jpg", quality=88)

        poster = Image.new("RGB", (600, 900), (10, 18, 28))
        draw = ImageDraw.Draw(poster)
        draw.rounded_rectangle((45, 90, 555, 570), radius=38, fill=color)
        draw.ellipse((110, 150, 490, 530), outline=(230, 238, 244), width=8)
        draw.text((45, 45), "SYNTHETIC TEST CONTENT", font=font(24), fill=(190, 210, 224))
        draw.multiline_text((45, 630), TITLES[index], font=font(45), fill=(242, 243, 238), spacing=8)
        draw.text((45, 840), f"FIXTURE {index + 1} / ORIGINAL GEOMETRIC ART", font=font(18), fill=(180, 199, 214))
        poster.save(ART / f"poster-{index}.jpg", quality=90)


def video():
    if shutil.which("ffmpeg") is None:
        raise SystemExit("ffmpeg is required; install it and rerun this generator.")
    sample = ROOT / "sample.mp4"
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                    "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24",
                    "-f", "lavfi", "-i", "sine=frequency=220:sample_rate=48000",
                    "-t", "24", "-c:v", "libx264", "-preset", "veryfast",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k",
                    "-movflags", "+faststart", str(sample)], check=True)
    HLS.mkdir(exist_ok=True)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                    "-i", str(sample), "-c:v", "libx264", "-g", "96", "-c:a", "copy",
                    "-hls_time", "4", "-hls_playlist_type", "vod",
                    "-hls_segment_filename", str(HLS / "segment%03d.ts"),
                    str(HLS / "index.m3u8")], check=True)


if __name__ == "__main__":
    artwork()
    video()
    print("Original synthetic posters, backdrops, MP4 and HLS test media generated locally.")
