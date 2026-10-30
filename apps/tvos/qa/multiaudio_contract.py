"""Fixed synthetic multi-audible HLS contract; no generic resource access."""
from pathlib import Path
import re
from urllib.parse import urlencode

USER = "tv-multiaudio"
TOKEN = "fixture-" + USER
SOURCE = "movie-1-multiaudio"
CAPTION = "REEL TV MULTI AUDIO CAPTION"
DURATION_TICKS = 1_200_000_000


def source(audio=1, subtitle=-1, sequence=1):
    if type(sequence) is not int or not 1 <= sequence <= 9999:
        raise ValueError("Invalid synthetic playback generation")
    if type(audio) is not int or audio not in (1, 3):
        raise ValueError("Unknown synthetic audible rendition")
    if type(subtitle) is not int or subtitle not in (-1, 2):
        raise ValueError("Unknown synthetic caption choice")
    return {
        "Id": SOURCE, "Name": "Synthetic multi-audio", "Container": "hls",
        "SupportsDirectPlay": False, "DefaultAudioStreamIndex": audio,
        "DefaultSubtitleStreamIndex": subtitle, "RunTimeTicks": DURATION_TICKS,
        "MediaStreams": [
            {"Index": 0, "Type": "Video", "Codec": "h264"},
            {"Index": 1, "Type": "Audio", "Codec": "aac", "Language": "eng", "DisplayTitle": "English synthetic 440 Hz", "Channels": 2, "SampleRate": 48000},
            {"Index": 3, "Type": "Audio", "Codec": "aac", "Language": "spa", "DisplayTitle": "Español sintético 880 Hz", "Channels": 2, "SampleRate": 48000},
            {"Index": 2, "Type": "Subtitle", "Codec": "vtt", "Language": "eng", "DisplayTitle": "Synthetic multi-audio captions", "DeliveryMethod": "Hls"},
        ],
        "TranscodingUrl": f"/Videos/reel-multiaudio/p{sequence}/a{audio}/s{subtitle}/master.m3u8",
    }


def negotiation(body, *, sequence=1):
    if not isinstance(body, dict) or body.get("MediaSourceId", SOURCE) != SOURCE:
        raise ValueError("Unknown synthetic source")
    ticks = body.get("StartTimeTicks", 0)
    if type(ticks) is not int or not 0 <= ticks < DURATION_TICKS:
        raise ValueError("Invalid synthetic position")
    selected = source(body.get("AudioStreamIndex", 1), body.get("SubtitleStreamIndex", -1), sequence)
    return {"MediaSources": [selected], "PlaySessionId": f"synthetic-multiaudio-session-{sequence}"}


def media_route(path):
    match = re.fullmatch(r"/Videos/reel-multiaudio/p([1-9]\d{0,3})/a(1|3)/s(-1|2)/(master\.m3u8|(?:video|en|es)/(?:index\.m3u8|segment\d{3}\.ts)|captions/(?:index\.m3u8|cue\.vtt))", path)
    if not match:
        raise ValueError("Unknown synthetic media route")
    sequence, audio, subtitle, relative = int(match[1]), int(match[2]), int(match[3]), match[4]
    source(audio, subtitle, sequence)
    physical = f"master-a{audio}-s{subtitle}.m3u8" if relative == "master.m3u8" else relative
    return sequence, audio, subtitle, relative, physical


def media_file(root, physical):
    if not re.fullmatch(r"master-a(?:1|3)-s(?:-1|2)\.m3u8|(?:video|en|es)/(?:index\.m3u8|segment\d{3}\.ts)|captions/(?:index\.m3u8|cue\.vtt)", physical):
        raise ValueError("Unknown synthetic file")
    base = Path(root).resolve(strict=True)
    path = base / "multiaudio" / physical
    if path.is_symlink() or not path.resolve(strict=True).is_relative_to(base):
        raise ValueError("Unsafe synthetic file")
    for parent in path.parents:
        if parent == base:
            break
        if parent.is_symlink():
            raise ValueError("Symlinked synthetic directory")
    if not path.is_file():
        raise ValueError("Missing synthetic file")
    return path


def playlist(data, audio, subtitle, relative, *, sequence=1):
    source(audio, subtitle, sequence)
    directory = relative.rsplit("/", 1)[0] + "/" if "/" in relative else ""

    def authenticated(name):
        resource = directory + name
        path = f"/Videos/reel-multiaudio/p{sequence}/a{audio}/s{subtitle}/{resource}"
        media_route(path)
        return path + "?" + urlencode({"ApiKey": TOKEN})

    text = re.sub(r'URI="([^"]+)"', lambda match: 'URI="' + authenticated(match[1]) + '"', data.decode())
    return ("\n".join(authenticated(line) if line and not line.startswith("#") else line for line in text.splitlines()) + "\n").encode()
