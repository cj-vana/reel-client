#!/usr/bin/env python3
"""Host the existing synthetic contract on TV-owned loopback ports only."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time
from urllib.parse import parse_qs, urlsplit

sys.dont_write_bytecode = True
import track_contract
import fixture_ownership
from native_fixture_contract import native_audio_metadata
parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, choices=(18966, 18967, 18968), required=True)
parser.add_argument("--media", required=True)
parser.add_argument("--subtitle-selection-fixture", action="store_true")
args = parser.parse_args()
OWNER = fixture_ownership.owner_from_environment()
if args.subtitle_selection_fixture != (args.port == 18968):
    raise SystemExit("The retained-subtitle candidate fixture is isolated to port18968.")
repository = Path(__file__).resolve().parents[3]
media = Path(args.media).resolve(strict=True)
if repository == media or repository in media.parents or not media.name.startswith("reel-tvos-fixture-"):
    raise SystemExit("Use the generated disposable TV fixture directory outside the repository.")
if not (media / "sample.mp4").is_file() or not (media / "hls/index.m3u8").is_file():
    raise SystemExit("Generate the TV fixtures first.")
sys.path.insert(0, str(repository / "apps/apple/qa"))
import fixture_server
fixture_server.ROOT = media
TV_DEFAULTS = {"homeFailure": True, "browseFailure": True, "appendFailure": True, "detailFailure": True, "episodeFailure": True, "subtitleManifestDelay": False, "subtitleMetadataFailure": False, "subtitleRefreshedResume": False, "subtitleWrongName": False, "subtitleCatalogRenamed": False, "subtitleCatalogAmbiguous": False, "subtitleCatalogDelay": False, "subtitleCatalogUnavailable": False}
TV_STATE = TV_DEFAULTS.copy()


class TVHandler(fixture_server.Handler):
    def respond(self, value=None, status=200, content_type="application/json"):
        return super().respond(value if self.user() == track_contract.USER else native_audio_metadata(value), status, content_type)

    def track_resource(self, path, *, head=False):
        if not path.startswith("/Videos/reel-tracks/"): return False
        query = parse_qs(urlsplit(self.path).query)
        if query.get("ApiKey") != [track_contract.TOKEN]:
            self.respond(status=401)
            return True
        try:
            variant, mode, name = track_contract.media_route(path)
            data = track_contract.media_file(media, variant, name).read_bytes()
            if name.endswith(".m3u8"):
                data = track_contract.playlist(data, variant, mode, retain_subtitles=args.subtitle_selection_fixture)
                if args.subtitle_selection_fixture and TV_STATE["subtitleWrongName"]:
                    data = data.replace(b'NAME="Synthetic captions"', b'NAME="Different synthetic track"')
        except (ValueError, OSError):
            self.respond(status=404)
            return True
        size = len(data)
        try: start, end, status = track_contract.byte_range(self.headers.get("Range"), size)
        except ValueError:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return True
        with fixture_server.LOCK:
            fixture_server.STATE.setdefault("trackRequests", []).append({"path": path, "asset": variant + "/" + name, "sha256": hashlib.sha256(data).hexdigest(), "range": self.headers.get("Range"), "method": "HEAD" if head else "GET"})
        if args.subtitle_selection_fixture and name == "master-on.m3u8" and TV_STATE["subtitleManifestDelay"]:
            time.sleep(2.5)
        self.send_response(status)
        self.send_header("Content-Type", "application/vnd.apple.mpegurl" if name.endswith(".m3u8") else "text/vtt" if name.endswith(".vtt") else "video/mp2t")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        if status == 206: self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        if not head: self.wfile.write(data[start:end + 1])
        return True

    def do_HEAD(self):
        if not self.track_resource(urlsplit(self.path).path, head=True): self.send_error(501, "Unsupported method ('HEAD')")

    def do_GET(self):
        if not fixture_ownership.admit(self, urlsplit(self.path).path, OWNER): return
        path = urlsplit(self.path).path
        if self.track_resource(path): return
        if path == "/Items/movie-1" and self.user() == track_contract.USER:
            if args.subtitle_selection_fixture and TV_STATE["subtitleCatalogUnavailable"]:
                return self.respond(status=503)
            if args.subtitle_selection_fixture and TV_STATE["subtitleCatalogDelay"]:
                deadline = time.monotonic() + 15
                while TV_STATE["subtitleCatalogDelay"] and time.monotonic() < deadline:
                    time.sleep(0.05)
            item = fixture_server.catalog(track_contract.USER)[0]
            item.update(MediaSources=track_contract.sources(renamed_subtitle=args.subtitle_selection_fixture and TV_STATE["subtitleCatalogRenamed"], ambiguous_subtitle=args.subtitle_selection_fixture and TV_STATE["subtitleCatalogAmbiguous"]), RunTimeTicks=600_000_000)
            if args.subtitle_selection_fixture and TV_STATE["subtitleRefreshedResume"]:
                item["UserData"]["PlaybackPositionTicks"] = 80_000_000
            return self.respond(item)
        if path == "/System/Info/Public":
            return self.respond({"ServerName": "Reel Cinema" if self.server.server_port == 18966 else "Reel Second Cinema", "Version": "12.3.0"})
        query = {key.lower(): values for key, values in parse_qs(urlsplit(self.path).query).items()}
        home_episodes = path == "/Items" and query.get("includeitemtypes") == ["Episode"] and query.get("limit") == ["18"]
        if path in ("/Items/Latest", "/UserItems/Resume", "/Shows/NextUp") or home_episodes:
            if self.user() == "tv-home-slow":
                time.sleep(2.5)
            if self.user() == "tv-home-recovery" and TV_STATE["homeFailure"]:
                return self.respond(status=503)
        if path == "/Items":
            if self.user() == "tv-browse-slow":
                time.sleep(3)
            if self.user() == "tv-browse-recovery" and TV_STATE["browseFailure"]:
                return self.respond(status=503)
            if self.user() == "tv-append-recovery" and int(parse_qs(urlsplit(self.path).query).get("startIndex", ["0"])[0]) > 0 and TV_STATE["appendFailure"]:
                return self.respond(status=503)
        if path == "/Items/movie-1":
            if self.user() == "tv-detail-slow":
                time.sleep(3)
            if self.user() == "tv-detail-recovery" and TV_STATE["detailFailure"]:
                return self.respond(status=503)
        if path.endswith("/Seasons") and self.user() == "tv-empty-seasons":
            return self.respond({"Items": []})
        if path.endswith("/Episodes") and self.user() in ("tv-slow-season", "tv-fail-season"):
            time.sleep(1)
            if self.user() == "tv-fail-season":
                return self.respond(status=503)
        if path.endswith("/Episodes") and self.user() == "tv-episode-recovery" and TV_STATE["episodeFailure"]:
            return self.respond(status=503)
        if path.startswith("/Videos/") and parse_qs(urlsplit(self.path).query).get("ApiKey") == ["fixture-tv-slow-media"]:
            time.sleep(2)
        if path.startswith("/Videos/") and parse_qs(urlsplit(self.path).query).get("ApiKey") == ["fixture-tv-ui-slow-media"]:
            time.sleep(6)
        super().do_GET()

    def do_POST(self):
        if not fixture_ownership.admit(self, urlsplit(self.path).path, OWNER): return
        path = urlsplit(self.path).path
        if path == "/qa/reset":
            TV_STATE.update(TV_DEFAULTS)
            with fixture_server.LOCK:
                fixture_server.STATE["trackRequests"] = []
                fixture_server.STATE["subtitleCleanups"] = []
                fixture_server.STATE["subtitleNegotiations"] = []
        if path == "/qa/tv-control":
            body = self.read_body()
            if not body or not set(body).issubset(TV_DEFAULTS) or not all(isinstance(value, bool) for value in body.values()):
                return self.respond(status=400)
            TV_STATE.update(body)
            return self.respond()
        if path == "/Users/AuthenticateByName":
            body = self.read_body()
            if body.get("Username") == "tv-slow-auth":
                time.sleep(4)
            if body.get("Pw") != "demo":
                return self.respond(status=401)
            name = body.get("Username", "demo")
            return self.respond({"AccessToken": "fixture-" + name, "User": {"Id": name, "Name": "Alex"}})
        if path == "/Items/movie-1/PlaybackInfo" and self.user() == track_contract.USER:
            try:
                body = self.read_body()
                if not isinstance(body, dict): raise ValueError("Expected object")
                response = track_contract.negotiation(body, retain_subtitles=args.subtitle_selection_fixture)
                if args.subtitle_selection_fixture and TV_STATE["subtitleMetadataFailure"]:
                    TV_STATE["subtitleMetadataFailure"] = False
                    response["MediaSources"][0]["TranscodingUrl"] = "/Videos/reel-tracks/original440/on/missing.m3u8"
                    response["PlaySessionId"] = "synthetic-bad-metadata-session"
            except (ValueError, TypeError, json.JSONDecodeError): return self.respond(status=400)
            with fixture_server.LOCK:
                fixture_server.STATE["reports"].append({"path": path, "user": track_contract.USER, "body": body})
                if args.subtitle_selection_fixture:
                    fixture_server.STATE.setdefault("subtitleNegotiations", []).append({"source": response["MediaSources"][0]["TranscodingUrl"], "session": response["PlaySessionId"]})
            return self.respond(response)
        if path == "/Sessions/Logout":
            with fixture_server.LOCK:
                fixture_server.STATE["reports"].append({"path": path, "user": self.user(), "body": {}})
        super().do_POST()

    def do_DELETE(self):
        if not fixture_ownership.admit(self, urlsplit(self.path).path, OWNER): return
        if args.subtitle_selection_fixture and urlsplit(self.path).path == "/Videos/ActiveEncodings":
            query = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
            with fixture_server.LOCK:
                fixture_server.STATE.setdefault("subtitleCleanups", []).append({"user": self.user(), "deviceId": query.get("deviceId"), "playSessionId": query.get("playSessionId")})
        super().do_DELETE()


class TVFixtureServer(fixture_server.LoopbackHTTPServer):
    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)


server = TVFixtureServer(("127.0.0.1", args.port), TVHandler)
print(f"TV-only synthetic fixture on http://127.0.0.1:{args.port}", flush=True)
server.serve_forever()
