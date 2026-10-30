#!/usr/bin/env python3
"""Owned loopback fixture for TV browsing parity, independent of retained TV ports."""
import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sys
import threading
import time
import uuid
from urllib.parse import parse_qs, urlsplit

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "apps/apple/qa"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import fixture_server
import library_contract
import watched_contract

PARITY = {}
SCOPED_REQUESTS = []
SCOPED_LOCK = threading.Lock()
OWNER = ""
CONTINUITY = {}
MEDIA_MANIFEST_SHA256 = ""
EPISODE_RELEASE = {}


def validated_control(body):
    if not isinstance(body, dict) or not body or set(body) - {"removedLibrary", "removedGenre", "metadataMode", "omitTotals", "denyOptions", "denyItems", "holdEpisodeFeed"}:
        raise ValueError("Expected named option-removal/metadata controls")
    for key, value in body.items():
        if key == "metadataMode":
            if value not in {"normal", "missing", "zero", "invalid", "long"}: raise ValueError("Unknown metadata mode")
        elif type(value) is not bool: raise ValueError("Expected a boolean option-removal flag")
    return body


def metadata(row, mode):
    if not isinstance(row, dict) or row.get("Type") != "Episode": return row
    result = copy.deepcopy(row)
    if mode == "missing":
        for key in ("ParentIndexNumber", "IndexNumber", "DateCreated", "DateLastMediaAdded"): result.pop(key, None)
    elif mode == "zero": result.update(ParentIndexNumber=0, IndexNumber=0)
    elif mode == "invalid": result.update(DateCreated="0001-01-01T00:00:00Z", DateLastMediaAdded="2026-02-31T00:00:00Z")
    elif mode == "long":
        result.update(SeriesName="A long synthetic series title with a clear beginning and a deliberate end " * 2,
                      Name="An individual episode with a long original fixture title and complete metadata " * 2)
    return result


class ParityHandler(fixture_server.Handler):
    def owns(self):
        return bool(OWNER) and self.headers.get("X-Reel-Parity-Owner") == OWNER

    def route(self, method):
        raw = urlsplit(self.path)
        self.base_path = "/alternate" if raw.path.startswith("/alternate/") else ""
        if self.base_path: self.path = self.path[len(self.base_path):]
        path = urlsplit(self.path).path
        self.scope_receipt = None
        if path in ("/Items", "/UserViews", "/Genres") or path.endswith("/PlaybackInfo"):
            self.scope_receipt = {"method": method, "path": path, "basePath": self.base_path,
                                  "user": self.user(), "atUnix": time.time(),
                                  "query": {key.lower(): value for key, value in parse_qs(urlsplit(self.path).query, keep_blank_values=True).items()}}
            with SCOPED_LOCK: SCOPED_REQUESTS.append(self.scope_receipt)
        return path

    def respond(self, value=None, *args, **kwargs):
        receipt = getattr(self, "scope_receipt", None)
        if receipt is not None:
            with SCOPED_LOCK: receipt["status"] = kwargs.get("status", args[0] if args else 200)
        path = urlsplit(self.path).path
        mode = PARITY.get(self.user(), {})
        if isinstance(value, dict) and isinstance(value.get("Items"), list):
            if path == "/UserViews" and mode.get("removedLibrary"):
                value = {**value, "Items": [row for row in value["Items"] if row.get("Id") != "library-shows"]}
            if path == "/Genres" and mode.get("removedGenre"):
                value = {**value, "Items": [row for row in value["Items"] if row.get("Id") != "library-drama"]}
            value = {**value, "Items": [metadata(row, mode.get("metadataMode")) for row in value["Items"]]}
            if mode.get("omitTotals"): value.pop("TotalRecordCount", None)
        elif isinstance(value, dict): value = metadata(value, mode.get("metadataMode"))
        return super().respond(value, *args, **kwargs)

    def do_GET(self):
        path = self.route("GET")
        if path.startswith("/qa/") and path != "/qa/parity-identity" and not self.owns(): return self.respond(status=403)
        if watched_contract.handle(self, "GET", path): return
        mode = PARITY.get(self.user(), {})
        if (path in {"/UserViews", "/Genres"} and mode.get("denyOptions")) or (path == "/Items" and mode.get("denyItems")):
            return self.respond({"Message": "Synthetic account permission denies this catalog operation"}, status=403)
        query = {key.lower(): value for key, value in parse_qs(urlsplit(self.path).query).items()}
        if path == "/Items" and query.get("includeitemtypes") == ["Episode"] and query.get("limit") == ["18"]:
            with SCOPED_LOCK: release = EPISODE_RELEASE.get(self.user()) if mode.get("holdEpisodeFeed") else None
            if release is not None and not release.wait(timeout=30): return self.respond({"Message": "Owned episode-feed hold expired"}, status=503)
        if path == "/System/Info/Public":
            name = "Reel Browse Alternate" if self.base_path else "Reel Browse One" if self.server.server_port == 18970 else "Reel Browse Two"
            return self.respond({"ServerName": name, "Version": "12.3.0"})
        if path == "/qa/parity-identity":
            return self.respond({"kind": "reel-tv-library-parity", "owner": OWNER, "pid": os.getpid(), "port": self.server.server_port,
                                 "mediaRoot": str(fixture_server.ROOT), "mediaManifestSHA256": MEDIA_MANIFEST_SHA256})
        if path == "/qa/parity-state":
            if not self.owns(): return self.respond(status=403)
            with library_contract._LOCK:
                users = copy.deepcopy(library_contract._USERS)
            with fixture_server.LOCK:
                reports = copy.deepcopy(fixture_server.STATE["reports"])
                requests = copy.deepcopy(fixture_server.STATE["requests"])
            with SCOPED_LOCK:
                scoped = copy.deepcopy(SCOPED_REQUESTS); continuity = copy.deepcopy(CONTINUITY); options = copy.deepcopy(PARITY)
            return self.respond({"users": users, "reports": reports, "requests": requests, "options": options, "scopedRequests": scoped,
                                 "continuity": continuity})
        super().do_GET()

    def do_POST(self):
        path = self.route("POST")
        if watched_contract.handle(self, "POST", path): return
        if path.startswith("/qa/") and not self.owns(): return self.respond(status=403)
        if path == "/qa/parity-continuity":
            try:
                body = self.read_body()
                if not self.user().startswith("library-tv-storage-") or not isinstance(body, dict): raise ValueError()
                marker = body["marker"]
                if str(uuid.UUID(marker)).lower() != marker.lower(): raise ValueError()
                with SCOPED_LOCK:
                    if body.get("action") == "record":
                        if set(body) != {"action", "marker", "phase", "deviceID", "appState", "coldLaunchAllowed", "observations"}: raise ValueError()
                        if body["phase"] not in {"background-for-retry", "foreground-before-retry", "retry-completed", "reset-cancelled", "reset-completed", "readded-before-cleanup-retry", "cleanup-completed"}: raise ValueError()
                        if body["appState"] not in {"runningBackground", "runningBackgroundSuspended", "runningForeground"} or body["coldLaunchAllowed"] is not False: raise ValueError()
                        if not isinstance(body["observations"], dict) or len(json.dumps(body["observations"])) > 4096: raise ValueError()
                        if marker in CONTINUITY: raise ValueError()
                        CONTINUITY[marker] = {key: value for key, value in body.items() if key != "action"}
                        CONTINUITY[marker].update(owner=OWNER, account={"server": "http://127.0.0.1:18970", "userID": self.user()},
                                                  atUTC=datetime.now(timezone.utc).isoformat(), acknowledged=False)
                    elif body.get("action") == "ack":
                        if set(body) != {"action", "marker", "hostProofSHA256"} or marker not in CONTINUITY: raise ValueError()
                        if CONTINUITY[marker]["account"]["userID"] != self.user(): raise ValueError()
                        pin = body["hostProofSHA256"]
                        if not isinstance(pin, str) or len(pin) != 64 or any(ch not in "0123456789abcdef" for ch in pin): raise ValueError()
                        CONTINUITY[marker].update(acknowledged=True, hostProofSHA256=pin)
                    else: raise ValueError()
                return self.respond({"marker": marker, "recorded": True})
            except (KeyError, ValueError, TypeError, json.JSONDecodeError): return self.respond(status=400)
        if path == "/qa/parity-control":
            user = self.user()
            if not user.startswith("library-"): return self.respond(status=403)
            try:
                values = validated_control(self.read_body())
                with SCOPED_LOCK:
                    PARITY.setdefault(user, {}).update(values)
                    if "holdEpisodeFeed" in values:
                        event = EPISODE_RELEASE.setdefault(user, threading.Event())
                        if values["holdEpisodeFeed"]: event.clear()
                        else: event.set()
            except (ValueError, TypeError, json.JSONDecodeError): return self.respond(status=400)
            return self.respond({"options": PARITY[user]})
        if path == "/qa/reset":
            with SCOPED_LOCK:
                for event in EPISODE_RELEASE.values(): event.set()
                PARITY.clear(); SCOPED_REQUESTS.clear(); CONTINUITY.clear(); EPISODE_RELEASE.clear()
            library_contract.reset()
        super().do_POST()

    def do_DELETE(self):
        path = self.route("DELETE")
        if watched_contract.handle(self, "DELETE", path): return
        if path.startswith("/qa/") and not self.owns(): return self.respond(status=403)
        super().do_DELETE()


class ParityServer(fixture_server.LoopbackHTTPServer):
    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)): return
        super().handle_error(request, client_address)


def main():
    global OWNER, MEDIA_MANIFEST_SHA256
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, choices=(18970, 18971), required=True)
    parser.add_argument("--media", type=Path, required=True)
    parser.add_argument("--media-manifest", type=Path, required=True)
    args = parser.parse_args()
    OWNER = os.environ.get("REEL_TV_PARITY_OWNER", "")
    if len(OWNER) < 24 or len(OWNER) > 120 or not all(ch.isalnum() or ch in "-_" for ch in OWNER):
        raise SystemExit("Provide a new task-owned fixture owner identity privately in the environment")
    media = args.media.resolve(strict=True)
    if ROOT == media or ROOT in media.parents or not media.name.startswith("reel-tvos-fixture-"):
        raise SystemExit("Use newly generated disposable TV fixture media outside source")
    if not (media / "sample.mp4").is_file() or not (media / "hls/index.m3u8").is_file():
        raise SystemExit("Generate original media before activating this fixture")
    if args.media_manifest.is_symlink(): raise SystemExit("Do not follow a fixture manifest link")
    record = json.loads(args.media_manifest.read_text())
    if Path(record["root"]) != media or not {"sample.mp4", "hls/index.m3u8"} <= set(record["files"]): raise SystemExit("Wrong sealed media inventory")
    for name, pin in record["files"].items():
        if Path(name).is_absolute() or ".." in Path(name).parts: raise SystemExit("Media inventory traversal")
        path = media / name
        cursor = media
        for part in Path(name).parts:
            cursor /= part
            if cursor.is_symlink(): raise SystemExit("Do not follow media links")
        if hashlib.sha256(path.read_bytes()).hexdigest() != pin: raise SystemExit("Fixture media changed")
    MEDIA_MANIFEST_SHA256 = hashlib.sha256(args.media_manifest.read_bytes()).hexdigest()
    fixture_server.ROOT = media
    server = ParityServer(("127.0.0.1", args.port), ParityHandler)
    print(json.dumps({"kind": "reel-tv-library-parity", "pid": os.getpid(), "port": args.port,
                      "sourceSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}), flush=True)
    try: server.serve_forever()
    finally: server.server_close()


if __name__ == "__main__": main()
