#!/usr/bin/env python3
"""Serve only the owned, original multi-audible fixture on loopback18969."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import time
from urllib.parse import parse_qs, urlsplit

sys.dont_write_bytecode = True
import multiaudio_contract as contract
import audio_fault_contract as faults
import fixture_ownership
from track_contract import byte_range

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, choices=(18969,), required=True)
parser.add_argument("--media", required=True)
args = parser.parse_args()
OWNER = fixture_ownership.owner_from_environment()
repository = Path(__file__).resolve().parents[3]
media = Path(args.media).resolve(strict=True)
if media == repository or repository in media.parents or not media.name.startswith("reel-tvos-fixture-"):
    raise SystemExit("Use generated disposable media outside source.")
if not (media / "sample.mp4").is_file() or not (media / "multiaudio-media.json").is_file():
    raise SystemExit("Generate and audit the original multi-audible fixture first.")
sys.path.insert(0, str(repository / "apps/apple/qa"))
import fixture_server
fixture_server.ROOT = media
fixture_server.STATE.update(multiAudioRequests=[], multiAudioNegotiations=[], multiAudioCleanups=[], audioControl={}, failedMasters=[], failedVideos=[])


class MultiAudioHandler(fixture_server.Handler):
    def media_resource(self, path, *, head=False):
        if path == "/Videos/reel-audio-local/movie.mp4":
            query = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
            if query != {"ApiKey": [contract.TOKEN]}:
                self.respond(status=401); return True
            target = media / "multiaudio-local.mp4"
            if target.is_symlink() or not target.is_file() or target.resolve().parent != media:
                self.respond(status=404); return True
            data = target.read_bytes()
            try: start, end, status = byte_range(self.headers.get("Range"), len(data))
            except ValueError:
                self.send_response(416); self.send_header("Content-Range", f"bytes */{len(data)}"); self.send_header("Content-Length", "0"); self.end_headers(); return True
            self.send_response(status); self.send_header("Content-Type", "video/mp4"); self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            if status == 206: self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
            self.end_headers()
            if not head: self.wfile.write(data[start:end + 1])
            return True
        if not path.startswith("/Videos/reel-multiaudio/"):
            return False
        query = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
        if query != {"ApiKey": [contract.TOKEN]}:
            self.respond(status=401)
            return True
        try:
            sequence, audio, subtitle, relative, physical = contract.media_route(path)
            data = contract.media_file(media, physical).read_bytes()
            if relative.endswith(".m3u8"):
                data = contract.playlist(data, audio, subtitle, relative, sequence=sequence)
        except (ValueError, OSError):
            self.respond(status=404)
            return True
        with fixture_server.LOCK:
            missing = ((relative == "master.m3u8" and sequence in fixture_server.STATE["failedMasters"])
                       or (relative.startswith("video/") and sequence in fixture_server.STATE["failedVideos"]))
        if missing:
            self.respond(status=404); return True
        size = len(data)
        try:
            start, end, status = byte_range(self.headers.get("Range"), size)
        except ValueError:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return True
        with fixture_server.LOCK:
            fixture_server.STATE["multiAudioRequests"].append({
                "path": path, "asset": physical, "group": relative.split("/")[0],
                "sha256": hashlib.sha256(data).hexdigest(), "range": self.headers.get("Range"),
                "method": "HEAD" if head else "GET", "time": time.time(),
            })
        self.send_response(status)
        self.send_header("Content-Type", "application/vnd.apple.mpegurl" if relative.endswith(".m3u8") else "text/vtt" if relative.endswith(".vtt") else "video/mp2t")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        if not head:
            self.wfile.write(data[start:end + 1])
        return True

    def do_HEAD(self):
        if not self.media_resource(urlsplit(self.path).path, head=True):
            self.send_error(501, "Unsupported method ('HEAD')")

    def do_GET(self):
        if not fixture_ownership.admit(self, urlsplit(self.path).path, OWNER): return
        path = urlsplit(self.path).path
        if self.media_resource(path):
            return
        if path == "/System/Info/Public":
            return self.respond({"ServerName": "Reel Multi Audio QA", "Version": "12.3.0"})
        if self.user() == contract.USER:
            if path == "/Items/movie-1":
                item = fixture_server.catalog(contract.USER)[0]
                item.update(Name="Synthetic multi-audio", MediaSources=[contract.source()], RunTimeTicks=contract.DURATION_TICKS,
                            Chapters=[{"Name": "Opening", "StartPositionTicks": 0}, {"Name": "Eight seconds", "StartPositionTicks": 80_000_000}, {"Name": "Near the end", "StartPositionTicks": 1_180_000_000}])
                with fixture_server.LOCK:
                    if fixture_server.STATE["audioControl"].get("detailsSubtitleDefault", False):
                        item["MediaSources"][0]["DefaultSubtitleStreamIndex"] = 2
                return self.respond(item)
            if path in ("/Items/Latest", "/UserItems/Resume", "/Shows/NextUp"):
                if path == "/Items/Latest":
                    items = fixture_server.catalog(contract.USER)
                    items[0].update(Name="Synthetic multi-audio", RunTimeTicks=contract.DURATION_TICKS)
                    return self.respond(items[:12])
                return self.respond({"Items": []})
        super().do_GET()

    def do_POST(self):
        if not fixture_ownership.admit(self, urlsplit(self.path).path, OWNER): return
        path = urlsplit(self.path).path
        if path == "/qa/audio-control":
            try: body = self.read_body()
            except (ValueError, TypeError, json.JSONDecodeError): return self.respond(status=400)
            try: body = faults.controls(body)
            except ValueError: return self.respond(status=400)
            with fixture_server.LOCK: fixture_server.STATE["audioControl"].update(body)
            return self.respond({"ok": True})
        if path == "/qa/reset":
            with fixture_server.LOCK:
                fixture_server.STATE.update(multiAudioRequests=[], multiAudioNegotiations=[], multiAudioCleanups=[], audioControl={}, failedMasters=[], failedVideos=[])
        if path == "/Items/movie-1/PlaybackInfo" and self.user() == contract.USER:
            try:
                body = self.read_body()
            except (ValueError, TypeError, json.JSONDecodeError):
                return self.respond(status=400)
            with fixture_server.LOCK:
                sequence = len(fixture_server.STATE["multiAudioNegotiations"]) + 1
                try:
                    response = contract.negotiation(body, sequence=sequence)
                except (ValueError, TypeError):
                    return self.respond(status=400)
                faults.apply(response, fixture_server.STATE["audioControl"], sequence,
                             fixture_server.STATE["failedMasters"], fixture_server.STATE["failedVideos"])
                fixture_server.STATE["reports"].append({"path": path, "user": contract.USER, "body": body, "time": time.time()})
                devices = re.findall(r'(?:^|,\s*)DeviceId="([A-Za-z0-9_-]{1,128})"', self.headers.get("Authorization", ""))
                fixture_server.STATE["multiAudioNegotiations"].append({"source": response["MediaSources"][0]["TranscodingUrl"], "session": response["PlaySessionId"], "user": contract.USER, "deviceId": devices[0] if len(devices) == 1 else None, "time": time.time()})
            return self.respond(response)
        super().do_POST()

    def do_DELETE(self):
        if not fixture_ownership.admit(self, urlsplit(self.path).path, OWNER): return
        if urlsplit(self.path).path == "/Videos/ActiveEncodings" and self.user() == contract.USER:
            query = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
            with fixture_server.LOCK:
                fixture_server.STATE["multiAudioCleanups"].append({"user": contract.USER, "deviceId": query.get("deviceId"), "playSessionId": query.get("playSessionId"), "time": time.time()})
        super().do_DELETE()


class MultiAudioServer(fixture_server.LoopbackHTTPServer):
    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)


server = MultiAudioServer(("127.0.0.1", args.port), MultiAudioHandler)
print(f"Synthetic multi-audible fixture on http://127.0.0.1:{args.port}", flush=True)
server.serve_forever()
