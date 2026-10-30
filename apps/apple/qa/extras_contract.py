"""Read-only trickplay/Cast permission fixture hooks. Never used by the app."""
import re
from pathlib import Path


def decorate_item(item, user):
    if user == "notrickplay" or not item or item.get("Type") not in ("Movie", "Episode"):
        return item
    if user == "cast-multiaudio" and item.get("MediaSources"):
        first = item["MediaSources"][0]
        first = {**first, "DefaultAudioStreamIndex": 4, "DefaultSubtitleStreamIndex": 2,
                 "MediaStreams": [*first.get("MediaStreams", []), {"Index": 4, "Type": "Audio", "Codec": "aac"}]}
        item = {**item, "MediaSources": [first, *item["MediaSources"][1:]]}
    sources = item.get("MediaSources", [])
    source = sources[0]["Id"] if sources else item["Id"]
    return {**item, "Trickplay": {source: {"320": {
        "Width": 320, "Height": 180, "TileWidth": 2, "TileHeight": 2,
        "ThumbnailCount": 12, "Interval": 2000
    }}}}


def handle_get(handler, path, query, user):
    if path == "/Users/Me":
        if not user or user == "expired":
            handler.respond(status=401)
        else:
            handler.respond({"Id": user, "Name": user, "Policy": {
                "IsDisabled": False, "EnableMediaPlayback": True,
                "EnableSharedDeviceControl": user != "cast-denied",
                "EnableLiveTvAccess": user != "notv",
                "EnableVideoPlaybackTranscoding": True,
                "EnableAudioPlaybackTranscoding": True,
            }})
        return True
    match = re.fullmatch(r"/Videos/[^/]+/Trickplay/320/(\d+)\.jpg", path)
    if match:
        if not user or user == "expired":
            handler.respond(status=401)
        elif user == "notrickplay" or int(match[1]) >= 3:
            handler.respond(status=404)
        else:
            handler.file(Path(__file__).parent / "artwork" / ("backdrop-" + str(int(match[1])) + ".jpg"), "image/jpeg")
        return True
    return False
