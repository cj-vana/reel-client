"""Opt-in synthetic track routes; no generic file, network or provider access."""
from pathlib import Path
import re
from urllib.parse import urlencode

USER = "tv-track-output"
TOKEN = "fixture-" + USER
VARIANTS = {"original440", "original880", "alternate880"}
CAPTION = "REEL TV CAPTION CHECK"


def sources(*, renamed_subtitle=False, ambiguous_subtitle=False):
    values = [
        {"Id": "movie-1-source", "Name": "Original", "Container": "mp4", "MediaStreams": [
            {"Index": 0, "Type": "Video", "Codec": "h264"},
            {"Index": 1, "Type": "Audio", "Codec": "aac", "Language": "eng", "DisplayTitle": "Synthetic 440 Hz"},
            {"Index": 3, "Type": "Audio", "Codec": "aac", "Language": "eng", "DisplayTitle": "Synthetic 880 Hz"},
            {"Index": 2, "Type": "Subtitle", "Codec": "vtt", "DisplayTitle": "Synthetic captions renamed" if renamed_subtitle else "Synthetic captions"}]},
        {"Id": "movie-1-alternate", "Name": "Alternate version", "Container": "mp4", "MediaStreams": [
            {"Index": 0, "Type": "Video", "Codec": "h264"},
            {"Index": 4, "Type": "Audio", "Codec": "aac", "Language": "eng", "DisplayTitle": "Alternate 880 Hz"}]}]
    if ambiguous_subtitle:
        values[0]["MediaStreams"].append({"Index": 5, "Type": "Subtitle", "Codec": "vtt", "DisplayTitle": values[0]["MediaStreams"][-1]["DisplayTitle"]})
    return values


def negotiation(body, *, retain_subtitles=False):
    source_id = body.get("MediaSourceId") or "movie-1-source"
    if source_id not in {s["Id"] for s in sources()}: raise ValueError("Unknown synthetic source")
    alternate = source_id == "movie-1-alternate"
    audio = body.get("AudioStreamIndex", 4 if alternate else 1)
    subtitle = body.get("SubtitleStreamIndex", -1)
    if type(audio) is not int or audio not in ([4] if alternate else [1, 3]): raise ValueError("Unknown synthetic audio")
    if type(subtitle) is not int or subtitle not in ([-1] if alternate else [-1, 2]): raise ValueError("Unknown synthetic subtitle")
    variant = "alternate880" if alternate else "original880" if audio == 3 else "original440"
    mode = "on" if subtitle == 2 or retain_subtitles else "off"
    source = next(s for s in sources() if s["Id"] == source_id)
    source.update(SupportsDirectPlay=False, DefaultAudioStreamIndex=audio, DefaultSubtitleStreamIndex=subtitle,
                  RunTimeTicks=600_000_000, TranscodingUrl=f"/Videos/reel-tracks/{variant}/{mode}/master.m3u8")
    return {"MediaSources": [source], "PlaySessionId": "synthetic-track-session"}


def media_route(path):
    match = re.fullmatch(r"/Videos/reel-tracks/(original440|original880|alternate880)/(on|off)/(master\.m3u8|video\.m3u8|subtitles\.m3u8|captions\.vtt|segment\d{3}\.ts)", path)
    if not match: raise ValueError("Unknown synthetic track resource")
    variant, mode, name = match.groups()
    if mode == "off" and name in {"subtitles.m3u8", "captions.vtt"}: raise ValueError("Subtitles are disabled")
    return variant, mode, f"master-{mode}.m3u8" if name == "master.m3u8" else name


def media_file(root, variant, name):
    base = Path(root).resolve(strict=True)
    path = base / "tracks" / variant / name
    if variant not in VARIANTS or not re.fullmatch(r"master-(on|off)\.m3u8|video\.m3u8|subtitles\.m3u8|captions\.vtt|segment\d{3}\.ts", name): raise ValueError("Unknown synthetic file")
    if path.is_symlink() or not path.resolve(strict=True).is_relative_to(base): raise ValueError("Unsafe synthetic file")
    for parent in path.parents:
        if parent == base: break
        if parent.is_symlink(): raise ValueError("Symlinked synthetic directory")
    if not path.is_file(): raise ValueError("Missing synthetic file")
    return path


def byte_range(header, size):
    if size <= 0: raise ValueError("Empty resource")
    if not header: return 0, size - 1, 200
    match = re.fullmatch(r"bytes=(\d*)-(\d*)", header)
    if not match or not any(match.groups()): raise ValueError("Unsupported Range")
    left, right = match.groups()
    if not left:
        count = int(right)
        if count <= 0: raise ValueError("Empty suffix range")
        start, end = max(0, size - count), size - 1
    else:
        start, end = int(left), min(int(right) if right else size - 1, size - 1)
    if start > end or start >= size: raise ValueError("Unsatisfiable Range")
    return start, end, 206


def playlist(data, variant, mode, *, retain_subtitles=False):
    def url(name):
        media_route(f"/Videos/reel-tracks/{variant}/{mode}/{name}")
        return f"/Videos/reel-tracks/{variant}/{mode}/{name}?" + urlencode({"ApiKey": TOKEN})
    text = data.decode()
    if retain_subtitles:
        text = text.replace('NAME="Synthetic captions",DEFAULT=YES', 'NAME="Synthetic captions",DEFAULT=NO')
    text = re.sub(r'URI="([^"]+)"', lambda m: 'URI="' + url(m[1]) + '"', text)
    return "\n".join(url(line) if line and not line.startswith("#") else line for line in text.splitlines()).encode() + b"\n"
