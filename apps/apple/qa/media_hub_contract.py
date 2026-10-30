"""Native music/photo/book fixture routes. Loopback test content only.

Call handle_get before the main fixture's generic item/image routes (and before
its Authorization-only guard for /Audio). Call handle_post before the generic
PlaybackInfo route. Both return True only after producing a response.
"""
import json
import math
import struct
import copy
import threading
import time
import wave
from pathlib import Path

_CONTROL_LOCK = threading.RLock()
_CONTROL = {}


def _state(user):
    return _CONTROL.setdefault(user, {"mode": {}, "requests": []})


def _configure(handler, user, body):
    if not user:
        handler.respond(status=401); return
    values = {} if body is None else body
    if not isinstance(values, dict):
        handler.respond(status=400); return
    booleans = {"reset", "empty", "lyricsEmpty", "extraBooks", "allowDownload", "denyDownload", "storageRepairRequested", "storageRepairComplete"}
    integers = {**{key: (0, 5000) for key in ("browseDelayMs", "downloadDelayMs", "audioDelayMs", "lyricsDelayMs", "photoDelayMs")}, **{key: (0, 20) for key in ("failBrowse", "failDownload", "failAudio", "failLyrics", "failPhoto")}, "pageSize": (1, 60), "trackCount": (2, 8), "storagePhase": (0, 7), "downloadDelayMs": (0, 15000)}
    if set(values) - booleans - set(integers):
        handler.respond(status=400); return
    for key, value in values.items():
        if key in booleans and not isinstance(value, bool):
            handler.respond(status=400); return
        if key in integers and (type(value) is not int or not integers[key][0] <= value <= integers[key][1]):
            handler.respond(status=400); return
    with _CONTROL_LOCK:
        if values.get("reset"): _CONTROL.pop(user, None)
        state = _state(user)
        state["mode"].update({key: value for key, value in values.items() if key != "reset"})
        result = copy.deepcopy(state)
    handler.respond(result)


def _mode(user):
    with _CONTROL_LOCK: return copy.deepcopy(_state(user)["mode"])


def _gate(handler, user, kind, path):
    with _CONTROL_LOCK:
        state = _state(user)
        state["requests"].append({"method": "GET" if kind != "Audio" else "POST", "path": path, "kind": kind})
        mode = state["mode"]
        failure = "fail" + kind
        fails = mode.get(failure, 0) > 0
        if fails: mode[failure] -= 1
        delay = mode.get(kind.lower() + "DelayMs", 0) / 1000
    if delay: time.sleep(delay)
    if fails: handler.respond(status=503)
    return fails


def catalog(user=None):
    common = {"ImageTags": {"Primary": "hub-fixture-v1"}, "UserData": {"PlaybackPositionTicks": 0}}
    def item(identifier, name, kind, **extra):
        return {**common, "Id": identifier, "Name": name, "Type": kind, **extra}
    sources = [{"Id": "hub-audio-source", "Container": "wav", "MediaStreams": [{"Index": 0, "Type": "Audio", "Codec": "pcm_s16le"}]}]
    values = [
        item("hub-album-1", "Signals at dusk", "MusicAlbum", AlbumArtist="Reel Fixture Ensemble", IsFolder=True),
        item("hub-artist-1", "Reel Fixture Ensemble", "MusicArtist", IsFolder=True),
        item("hub-track-1", "First signal", "Audio", Artists=["Reel Fixture Ensemble"], Album="Signals at dusk", AlbumId="hub-album-1", IndexNumber=1, Container="wav", RunTimeTicks=1_200_000_000, MediaSources=sources, HasLyrics=True),
        item("hub-track-2", "Second signal", "Audio", Artists=["Reel Fixture Ensemble"], Album="Signals at dusk", AlbumId="hub-album-1", IndexNumber=2, Container="wav", RunTimeTicks=1_200_000_000, MediaSources=sources),
        item("hub-playlist-1", "Signals in order", "Playlist", IsFolder=True),
        item("hub-photo-album-1", "Test landscapes", "PhotoAlbum", IsFolder=True),
        item("hub-photo-1", "Morning in the test library", "Photo", Container="jpg"),
        item("hub-photo-2", "Evening in the test library", "Photo", Container="jpg"),
        item("hub-book-1", "The test reader", "Book", Container="pdf", Overview="A locally generated two-page PDF for exercising the native reader, export and offline persistence."),
        item("hub-audiobook-1", "A small journey", "AudioBook", Artists=["Reel Fixture Narrator"], Container="wav", RunTimeTicks=1_200_000_000, MediaSources=sources, Chapters=[{"Name": "A first step", "StartPositionTicks": 0}, {"Name": "A second step", "StartPositionTicks": 100_000_000}]),
    ]
    mode = _mode(user) if user else {}
    values += [item(f"hub-track-{number}", f"Signal {number}", "Audio", Artists=["Reel Fixture Ensemble"], Album="Signals at dusk", Container="wav", RunTimeTicks=1_200_000_000, MediaSources=sources) for number in range(3, mode.get("trackCount", 2) + 1)]
    if mode.get("extraBooks"):
        values += [item("hub-book-text", "The text reader", "Book", Container="txt"), item("hub-book-mobi", "An external reader example", "Book", Container="mobi")]
    return values


def ensure_assets(root):
    root = Path(root)
    directory = root / "hub-assets"
    directory.mkdir(exist_ok=True)
    audio = directory / "test-audio.wav"
    if not audio.exists():
        with wave.open(str(audio), "wb") as output:
            output.setnchannels(1); output.setsampwidth(2); output.setframerate(22050)
            second = b"".join(struct.pack("<h", int(650 * math.sin(2 * math.pi * 220 * n / 22050))) for n in range(22050))
            for _ in range(120): output.writeframesraw(second)
    pdf = directory / "test-reader.pdf"
    if not pdf.exists():
        objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
                   b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 7 0 R >> >> /Contents 4 0 R >>"]
        stream = b"BT /F1 26 Tf 60 700 Td (Reel native reader) Tj 0 -42 Td /F1 14 Tf (Page one - local test content.) Tj ET"
        objects.append(b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream")
        objects.append(b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 7 0 R >> >> /Contents 6 0 R >>")
        stream = b"BT /F1 26 Tf 60 700 Td (The next page) Tj 0 -42 Td /F1 14 Tf (Page two - your place can be restored.) Tj ET"
        objects.append(b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream")
        objects.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        data = bytearray(b"%PDF-1.4\n"); offsets = [0]
        for index, obj in enumerate(objects, 1):
            offsets.append(len(data)); data += f"{index} 0 obj\n".encode() + obj + b"\nendobj\n"
        xref = len(data)
        data += f"xref\n0 {len(objects)+1}\n0000000000 65535 f \n".encode()
        for offset in offsets[1:]: data += f"{offset:010d} 00000 n \n".encode()
        data += f"trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
        pdf.write_bytes(data)
    return directory


def handle_get(handler, path, query, user, root):
    if path == "/qa/hub-state":
        if not user: handler.respond(status=401); return True
        with _CONTROL_LOCK: value = copy.deepcopy(_state(user))
        handler.respond(value); return True
    hub = catalog(user)
    by_id = {item["Id"]: item for item in hub}
    if path.startswith("/Audio/hub-") and path.endswith("/Lyrics"):
        if not user: handler.respond(status=401); return True
        if _gate(handler, user, "Lyrics", path): return True
        handler.respond({"Metadata": {"IsSynced": True}, "Lyrics": [] if _mode(user).get("lyricsEmpty") else [{"Text": "A first signal in the quiet", "Start": 0}, {"Text": "A second signal finding home", "Start": 100_000_000}]}); return True
    if path.startswith("/Audio/hub-"):
        if not query.get("apikey", "").startswith("fixture-"):
            handler.respond(status=401); return True
        return serve(handler, ensure_assets(root) / "test-audio.wav", "audio/wav")
    if not user or user == "expired": return False
    if path == "/Artists":
        items = [by_id["hub-artist-1"]]
    elif path.startswith("/Playlists/hub-playlist-1/Items"):
        items = [by_id["hub-track-2"], by_id["hub-track-1"]]
    elif path == "/Items":
        types = set(query.get("includeitemtypes", "").split(","))
        hub_types = {"MusicAlbum", "MusicArtist", "Audio", "Photo", "PhotoAlbum", "Book", "AudioBook"}
        if not types.intersection(hub_types) and not (types == {"Playlist"} and query.get("mediatypes") == "Audio") and not query.get("parentid", "").startswith("hub-"):
            return False
        items = [item for item in hub if item["Type"] in types]
        parent = query.get("parentid")
        if parent == "hub-album-1": items = [by_id["hub-track-1"], by_id["hub-track-2"]]
        elif parent == "hub-photo-album-1": items = [by_id["hub-photo-1"], by_id["hub-photo-2"]]
        if query.get("artistids") == "hub-artist-1": items = [by_id["hub-album-1"]]
    elif path.startswith("/Items/hub-"):
        parts = path.split("/")
        item = by_id.get(parts[2])
        if not item: handler.respond(status=404); return True
        if path.endswith("/Download") or path.endswith("/File"):
            if _gate(handler, user, "Download", path): return True
            mode = _mode(user)
            if (user == "nodownload" or mode.get("denyDownload")) and not mode.get("allowDownload"): handler.respond(status=403); return True
            assets = ensure_assets(root)
            if item.get("Container") == "txt":
                text = assets / "test-reader.txt"; text.write_text("Reel native text reader\nLocal fixture content for Quick Look.\n")
                return serve(handler, text, "text/plain")
            if item.get("Container") == "mobi":
                document = assets / "external-reader.mobi"; document.write_bytes(b"Loopback example for the external-reader fallback and original-file export.")
                return serve(handler, document, "application/octet-stream")
            return serve(handler, assets / ("test-reader.pdf" if item["Type"] == "Book" else "test-audio.wav"), "application/pdf" if item["Type"] == "Book" else "audio/wav")
        if "/Images/" in path:
            if item["Type"] == "Photo" and _gate(handler, user, "Photo", path): return True
            number = 1 if item["Id"].endswith("2") else 0
            return serve(handler, Path(root) / "artwork" / f"backdrop-{number}.jpg", "image/jpeg")
        handler.respond(item); return True
    else: return False
    if _gate(handler, user, "Browse", path): return True
    if user == "hubempty": items = []
    if _mode(user).get("empty"): items = []
    if user == "huberror": handler.respond(status=503); return True
    term = query.get("searchterm", "").lower()
    if term: items = [item for item in items if term in (item["Name"] + " " + " ".join(item.get("Artists", []))).lower()]
    start = int(query.get("startindex", 0)); limit = min(int(query.get("limit", 60)), _mode(user).get("pageSize", 60))
    handler.respond({"Items": items[start:start+limit], "TotalRecordCount": len(items)})
    return True


def serve(handler, path, content_type):
    handler.file(path, content_type)
    return True


def handle_post(handler, path, body, user, state, lock):
    if path == "/qa/hub-control":
        _configure(handler, user, body); return True
    if not path.startswith("/Items/hub-") or not path.endswith("/PlaybackInfo"): return False
    if not user: handler.respond(status=401); return True
    if user == "hubaudioerror": handler.respond(status=503); return True
    if _gate(handler, user, "Audio", path): return True
    item_id = path.split("/")[2]
    with lock: state["reports"].append({"path": path, "user": user, "body": body})
    handler.respond({"MediaSources": [{"Id": item_id + "-source", "Container": "wav", "SupportsDirectPlay": True, "RunTimeTicks": 1_200_000_000, "MediaStreams": [{"Index": 0, "Type": "Audio", "Codec": "pcm_s16le"}]}], "PlaySessionId": "hub-fixture-session"})
    return True
