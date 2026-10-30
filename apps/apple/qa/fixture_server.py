#!/usr/bin/env python3
"""Loopback-only Jellyfin contract fixture. No production credentials or library data."""
import argparse
import copy
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import connections_contract
import download_contract
import extras_contract
import library_contract
import livetv_contract
import media_hub_contract
from loopback_server import LoopbackHTTPServer

CONNECTIONS = connections_contract.ConnectionsContract()
ROOT = Path(__file__).resolve().parent
LOCK = threading.Lock()
STATE = {"favorites": {}, "positions": {}, "played": {}, "reports": [], "requests": [], "failures": 0, "failReports": False, "reportDelay": 0, "allowDeniedDownloads": False, "recoveryAllowed": False, "failCleanup": False, "tunerConsumers": {}}
TICKS = 10_000_000


def catalog(user="demo"):
    titles = ["The Quiet Earth", "After the Last Light", "North of Nowhere", "Blue Hours", "The Long Way Home", "A Forest, Remembered"]
    items = []
    for i in range(1, 76):
        series = i in (7, 8, 9)
        name = ["Out of the Blue", "Wild Country", "The Other Side"][i - 7] if series else titles[(i - 1) % 6] + (f" · Volume {i}" if i > 9 else "")
        key = f"series-{i}" if series else f"movie-{i}"
        items.append({"Id": key, "Name": name, "Type": "Series" if series else "Movie", "Overview": "Some journeys bring you somewhere new. Others bring you back to yourself. A quiet, beautifully observed story of unexpected connections and the places we call home.",
                      "ProductionYear": 2026 - i % 5, "OfficialRating": "PG-13", "CommunityRating": 8.2,
                      "RunTimeTicks": 24 * TICKS, "Genres": ["Drama", "Adventure"] if i % 2 == 0 else ["Drama"], "ImageTags": {"Primary": "fixture-v1"}, "BackdropImageTags": ["fixture-v1"],
                      "UserData": {"PlaybackPositionTicks": STATE["positions"].get((user, key), 0), "IsFavorite": STATE["favorites"].get((user, key), False), "Played": STATE["played"].get((user, key), False)},
                      "People": [{"Id": "cast-1", "Name": "Test Actor", "Role": "Alex", "PrimaryImageTag": "fixture"}], "Chapters": [{"Name": "Opening", "StartPositionTicks": 0}, {"Name": "A new chapter", "StartPositionTicks": 8 * TICKS}], "MediaSources": [{"Id": key + "-source", "Container": "mp4", "Name": "Original", "MediaStreams": [{"Index": 0, "Type": "Video", "Codec": "h264"}, {"Index": 1, "Type": "Audio", "DisplayTitle": "English · AAC stereo", "Codec": "aac"}, {"Index": 2, "Type": "Subtitle", "DisplayTitle": "English · VTT", "Codec": "vtt"}]}]})
        if i in (1, 2):
            items[-1]["MediaSources"].append({"Id": key + "-alternate", "Name": "Alternate version", "Container": "mp4", "MediaStreams": [{"Index": 0, "Type": "Video", "Codec": "h264"}, {"Index": 4, "Type": "Audio", "Codec": "aac", "DisplayTitle": "Alternate English"}]})
    return items


def episode(number, user="demo", season=1):
    return {"Id": f"episode-{season}-{number}", "Name": ["A new beginning", "Below the surface", "The way back"][number - 1], "Type": "Episode", "SeriesId": "series-7", "SeriesName": "Out of the Blue", "SeriesPrimaryImageTag": "fixture-v1", "ParentBackdropItemId": "series-7", "ParentBackdropImageTags": ["fixture-v1"], "IndexNumber": number, "ParentIndexNumber": season, "Overview": "The journey continues, with a new perspective on a familiar world.", "RunTimeTicks": 24 * TICKS, "ImageTags": {"Primary": "fixture-v1"}, "UserData": {"PlaybackPositionTicks": STATE["positions"].get((user, f"episode-{season}-{number}"), 0)}, "MediaSources": [{"Id": "episode-source", "MediaStreams": [{"Index": 1, "Type": "Audio", "DisplayTitle": "English · AAC stereo"}]}]}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def read_body(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        return json.loads(data) if data else {}

    def respond(self, value=None, status=200, content_type="application/json"):
        data = value if isinstance(value, bytes) else json.dumps(value).encode() if value is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def user(self):
        match = re.search(r'Token="fixture-([^\"]+)"', self.headers.get("Authorization", ""))
        return match[1] if match else None

    def do_GET(self):
        parsed = urlsplit(self.path)
        path = parsed.path
        q = {k.lower(): v[0] for k, v in parse_qs(parsed.query).items()}
        user = self.user()
        with LOCK:
            STATE["requests"].append({"method": "GET", "path": path, "authenticated": bool(user)})
        if path == "/qa/state":
            with LOCK:
                result = {k: copy.deepcopy(v) for k, v in STATE.items() if k not in ("favorites", "positions", "played")}
            result["livetv"] = livetv_contract.snapshot()
            return self.respond(result)
        handled = CONNECTIONS.handle("GET", path, q, {}, self.headers)
        if handled is not None: return self.respond(handled[1], handled[0])
        if user and user.startswith("library-") and library_contract.handle(self, "GET", path, q, user): return
        if media_hub_contract.handle_get(self, path, q, user, ROOT): return
        if download_contract.handle_get(self, path, q, user): return
        if livetv_contract.handle_permissions(self, path, user): return
        if path == "/Users/Me" and user and user != "expired":
            return self.respond({"Id": user, "Name": user, "Policy": {"IsDisabled": False, "EnableMediaPlayback": True, "EnableContentDownloading": user != "nodownload", "EnableSharedDeviceControl": user != "cast-denied", "EnableVideoPlaybackTranscoding": True, "EnableAudioPlaybackTranscoding": True, "SyncPlayAccess": "CreateAndJoinGroups", **livetv_contract.user_policy(user), **download_contract.policy(user)}})
        if extras_contract.handle_get(self, path, q, user): return
        if path == "/System/Info/Public":
            return self.respond({"ServerName": "Reel Test Library" if self.server.server_port == 18766 else "Reel Second Server", "Version": "12.3.0"})
        if path.startswith("/Videos/"):
            if q.get("apikey") == "fixture-failed-recovery" and not STATE["recoveryAllowed"]:
                return self.respond(b"invalid media", content_type="video/mp4")
            if q.get("apikey") != "fixture-demo" and not q.get("apikey", "").startswith("fixture-"):
                return self.respond(status=401)
            if path.endswith("master.m3u8"):
                playlist = (ROOT / "hls/index.m3u8").read_text()
                playlist = re.sub(r"^(segment\d+\.ts)$", lambda m: "/Videos/fixture/" + m[1] + "?ApiKey=" + q["apikey"], playlist, flags=re.MULTILINE)
                return self.respond(playlist.encode(), content_type="application/vnd.apple.mpegurl")
            if path.endswith(".ts"):
                return self.file(ROOT / "hls" / path.rsplit("/", 1)[-1], "video/mp2t")
            return self.file(ROOT / "sample.mp4", "video/mp4")
        if not user or user == "expired":
            return self.respond(status=401)
        if livetv_contract.handle(self, "GET", path, q, user): return
        if user == "slow":
            time.sleep(0.7)
        if user == "flaky" and path == "/Items/Latest":
            with LOCK:
                fail = STATE["failures"] == 0
                STATE["failures"] += 1
            if fail:
                return self.respond(status=503)
        items = [] if user == "empty" else catalog(user)
        if path.endswith("/Images/Primary") or path.endswith("/Images/Backdrop") or path.endswith("/Images/Thumb"):
            key = path.split("/")[2]
            n = int(re.search(r"\d+", key)[0]) % 6 if re.search(r"\d+", key) else 0
            if user == "missingart":
                return self.respond(status=404)
            kind = "poster" if path.endswith("Primary") else "backdrop"
            return self.file(ROOT / "artwork" / f"{kind}-{n}.jpg", "image/jpeg")
        if path.endswith("/Download"):
            if user == "nodownload" and not STATE["allowDeniedDownloads"]: return self.respond(status=403)
            if user == "slowdownload": time.sleep(10)
            return self.file(ROOT / "sample.mp4", "video/mp4")
        if path.startswith("/MediaSegments/"):
            return self.respond({"Items": [{"Id": "intro", "Type": "Intro", "StartTicks": 0, "EndTicks": 4 * TICKS}]})
        if path.endswith("/Similar"):
            return self.respond({"Items": items[1:4]})
        if path == "/Genres":
            return self.respond({"Items": [{"Id": "drama", "Name": "Drama"}, {"Id": "adventure", "Name": "Adventure"}]})
        if path == "/LiveTv/Channels":
            return self.respond({"Items": [] if user == "notv" else [{**catalog(user)[0], "Id": "channel-1", "Type": "TvChannel", "Name": "Reel Test TV", "CurrentProgram": {"Name": "Local test program"}}]})
        if path == "/UserViews":
            return self.respond({"Items": [{"Id": "films", "Name": "Films", "Type": "CollectionFolder"}, {"Id": "shows", "Name": "Series", "Type": "CollectionFolder"}]})
        if path == "/Items/Latest":
            return self.respond([x for x in items if x["Type"] == q.get("includeitemtypes")][:18])
        if path == "/UserItems/Resume":
            resume = [] if not items else [episode(1, user), items[3]]
            for item in resume:
                item["UserData"]["PlaybackPositionTicks"] = STATE["positions"].get((user, item["Id"]), 5 * TICKS)
            return self.respond({"Items": resume})
        if path == "/Shows/NextUp":
            return self.respond({"Items": [episode(2, user)] if items else []})
        if path.endswith("/Seasons"):
            return self.respond({"Items": [{"Id": f"season-{i}", "Name": f"Season {i}", "Type": "Season"} for i in (1, 2)]})
        if path.endswith("/Episodes"):
            season = int(q.get("seasonid", "season-1").split("-")[-1])
            if q.get("adjacentto", "").startswith("episode-"):
                season = int(q["adjacentto"].split("-")[1])
            return self.respond({"Items": [episode(i, user, season) for i in (1, 2, 3)]})
        if path.startswith("/Playlists/") and path.endswith("/Items"):
            return self.respond({"Items": [{**items[0], "PlaylistItemId": "entry-1"}, {**items[0], "PlaylistItemId": "entry-2"}, {**items[1], "PlaylistItemId": "entry-3"}], "TotalRecordCount": 3})
        if path == "/Items":
            if q.get("includeitemtypes") == "BoxSet": return self.respond({"Items": [{"Id": "collection-1", "Name": "Test collection", "Type": "BoxSet"}], "TotalRecordCount": 1})
            if q.get("includeitemtypes") == "Playlist": return self.respond({"Items": [{"Id": "playlist-1", "Name": "Weekend watchlist", "Type": "Playlist"}], "TotalRecordCount": 1})
            types = q.get("includeitemtypes", "Movie,Series").split(",")
            if "Episode" in types and items:
                items += [episode(i, user) for i in (1, 2, 3)]
            items = [x for x in items if x["Type"] in types]
            if q.get("parentid") == "collection-1": items = items[:3]
            elif q.get("parentid"):
                items = [x for x in items if x["Type"] == ("Movie" if q["parentid"] == "films" else "Series")]
            if q.get("isplayed") is not None: items = [x for x in items if x["UserData"].get("Played", False) == (q["isplayed"] == "true")]
            if q.get("filters") == "IsFavorite":
                items = [x for x in items if x["UserData"].get("IsFavorite")]
            if q.get("searchterm"):
                items = [x for x in items if q["searchterm"].lower() in (x["Name"] + x.get("SeriesName", "")).lower()]
            if q.get("genreids") == "adventure": items = [x for x in items if "Adventure" in x.get("Genres", [])]
            if q.get("sortby") == "ProductionYear": items.sort(key=lambda x: x.get("ProductionYear", 0), reverse=True)
            if q.get("sortby") == "DateCreated": items.reverse()
            if q.get("sortby") == "SortName":
                items.sort(key=lambda x: x["Name"])
            start = int(q.get("startindex", 0))
            return self.respond({"Items": items[start:start + int(q.get("limit", 60))], "TotalRecordCount": len(items)})
        if path.startswith("/Items/"):
            key = path.split("/")[2]
            if key == "channel-1": return self.respond({**catalog(user)[0], "Id": key, "Type": "TvChannel", "Name": "Reel Test TV"})
            if key.startswith("episode"):
                return self.respond(extras_contract.decorate_item(episode(int(key.split("-")[-1]), user, int(key.split("-")[1])), user))
            item = next((x for x in items if x["Id"] == key), None)
            return self.respond(extras_contract.decorate_item(item, user), 200 if item else 404)
        return self.respond(status=404)

    def file(self, path, content_type):
        if not path.is_file():
            return self.respond(status=404)
        data = path.read_bytes()
        start, end = 0, len(data) - 1
        range_header = self.headers.get("Range")
        if range_header:
            match = re.match(r"bytes=(\d+)-(\d*)", range_header)
            if match:
                start = int(match[1]); end = min(int(match[2]) if match[2] else end, end)
        if start > end:
            self.send_response(416); self.send_header("Content-Length", "0"); self.end_headers(); return
        self.send_response(206 if range_header else 200)
        self.send_header("Content-Type", content_type)
        self.send_header("Accept-Ranges", "bytes")
        if range_header:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        self.wfile.write(data[start:end + 1])

    def do_POST(self):
        path = urlsplit(self.path).path
        body = self.read_body()
        handled = CONNECTIONS.handle("POST", path, {}, body, self.headers)
        if handled is not None: return self.respond(handled[1], handled[0])
        if path == "/qa/reset":
            livetv_contract.reset()
            download_contract.reset()
            with LOCK:
                STATE.update(favorites={}, positions={}, played={}, reports=[], requests=[], failures=0)
            return self.respond()
        if path == "/qa/control":
            with LOCK:
                STATE["failReports"] = body.get("failReports", False)
                STATE["reportDelay"] = body.get("reportDelay", 0)
                if "failCleanup" in body: STATE["failCleanup"] = body["failCleanup"]
                if "recoveryAllowed" in body: STATE["recoveryAllowed"] = body["recoveryAllowed"]
                if "allowDeniedDownloads" in body: STATE["allowDeniedDownloads"] = body["allowDeniedDownloads"]
            return self.respond()
        if path == "/Users/AuthenticateByName":
            if body.get("Pw") != "demo":
                return self.respond(status=401)
            name = body.get("Username", "demo")
            return self.respond({"AccessToken": "fixture-" + name, "User": {"Id": name, "Name": "Alex"}})
        user = self.user()
        if not user:
            return self.respond(status=401)
        if user.startswith("library-") and library_contract.handle(self, "POST", path, {}, user, body): return
        if download_contract.handle_post(self, path, body, user): return
        if media_hub_contract.handle_post(self, path, body, user, STATE, LOCK): return
        if livetv_contract.handle(self, "POST", path, {}, user, body): return
        if path.endswith("/PlaybackInfo"):
            key = path.split("/")[2]
            if key.startswith("channel") and not body.get("LiveStreamId"):
                with LOCK: STATE["tunerConsumers"][user] = STATE["tunerConsumers"].get(user, 0) + 1
            direct = body.get("EnableDirectPlay") and body.get("MaxStreamingBitrate", 0) > 2_000_000
            source = {"Id": body.get("MediaSourceId") or key + "-source", "LiveStreamId": "fixture-tuner" if key.startswith("channel") else None, "RequiresClosing": key.startswith("channel"), "SupportsDirectPlay": bool(direct), "Container": "mp4", "RunTimeTicks": 24 * TICKS, "TranscodingUrl": f"/Videos/{key}/master.m3u8", "DefaultAudioStreamIndex": 1, "DefaultSubtitleStreamIndex": -1}
            with LOCK:
                STATE["reports"].append({"path": path, "user": user, "body": body})
            return self.respond({"MediaSources": [source], "PlaySessionId": "fixture-session"})
        if path == "/LiveStreams/Close":
            if STATE["failCleanup"]: return self.respond(status=503)
            with LOCK:
                STATE["reports"].append({"path": path, "user": user, "body": {}})
                STATE["tunerConsumers"][user] = max(0, STATE["tunerConsumers"].get(user, 0) - 1)
            return self.respond()
        if path.startswith("/Sessions/Playing"):
            if STATE["failReports"]:
                return self.respond(status=503)
            if STATE["reportDelay"]:
                time.sleep(STATE["reportDelay"])
            with LOCK:
                STATE["reports"].append({"path": path, "user": user, "body": body})
                if "ItemId" in body:
                    STATE["positions"][(user, body["ItemId"])] = body.get("PositionTicks", 0)
            return self.respond()
        if path.startswith("/UserPlayedItems/"):
            STATE["played"][(user, path.split("/")[-1])] = True
            return self.respond()
        if path.startswith("/UserFavoriteItems/"):
            STATE["favorites"][(user, path.split("/")[-1])] = True
            return self.respond({"IsFavorite": True})
        if path == "/Sessions/Logout":
            return self.respond()
        return self.respond(status=404)

    def do_DELETE(self):
        self.read_body()
        path = urlsplit(self.path).path
        if not self.user():
            return self.respond(status=401)
        if self.user().startswith("library-") and library_contract.handle(self, "DELETE", path, {}, self.user()): return
        if livetv_contract.handle(self, "DELETE", path, {}, self.user()): return
        if path.startswith("/UserPlayedItems/"):
            STATE["played"][(self.user(), path.split("/")[-1])] = False
            return self.respond()
        if path.startswith("/UserFavoriteItems/"):
            STATE["favorites"][(self.user(), path.split("/")[-1])] = False
            return self.respond()
        if path == "/Videos/ActiveEncodings":
            if STATE["failCleanup"]: return self.respond(status=503)
            with LOCK:
                STATE["reports"].append({"path": path, "user": self.user(), "body": {}})
            return self.respond()
        return self.respond(status=404)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18766)
    port = parser.parse_args().port
    server = LoopbackHTTPServer(("127.0.0.1", port), Handler)
    if port == 18766: connections_contract.DiscoveryContract(http_port=port, udp_port=17359).start()
    print(f"Reel fixture listening on http://127.0.0.1:{server.server_port}", flush=True)
    server.serve_forever()
