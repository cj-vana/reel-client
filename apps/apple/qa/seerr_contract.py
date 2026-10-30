#!/usr/bin/env python3
"""Loopback-only Seerr contract fixture. No production data or credentials."""
import argparse
import copy
import json
import threading
import time
from http.server import BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlsplit

from loopback_server import LoopbackHTTPServer

class SeerrContract:
    def __init__(self):
        self.lock = threading.Lock()
        self.requests = []
        self.events = []
        self.next_id = 500
        self.modes = {}

    def mode(self, name):
        with self.lock:
            return copy.deepcopy(self.modes.get(name, {}))

    def consume_failure(self, name, key):
        with self.lock:
            mode = self.modes.get(name, {})
            if mode.get(key, 0) > 0:
                mode[key] -= 1
                return True
            return False

    def quota(self, name):
        mode = self.mode(name)
        result = {}
        for kind in ("movie", "tv"):
            remaining = mode.get(kind + "QuotaRemaining", 10)
            result[kind] = {"limit": 10, "remaining": remaining,
                            "restricted": mode.get(kind + "Restricted", mode.get("restricted", remaining <= 0))}
        return result

    @staticmethod
    def user(name):
        records = {"admin": (1, 2), "viewer": (2, 32), "restricted": (3, 0), "quota": (4, 32)}
        identity, permissions = records.get(name, records["viewer"])
        return {"id": identity, "username": name, "displayName": name.title(), "permissions": permissions}

    def media(self, identity, kind):
        requests = [copy.deepcopy(request) for request in self.requests if request["media"]["tmdbId"] == identity and request["type"] == kind]
        def availability(is4k):
            matching = [request for request in requests if request.get("is4k", False) == is4k]
            if identity == 102 and not is4k:
                return 5
            if any(request["status"] == 2 for request in matching):
                return 3
            return 2 if matching else 1
        status, status4k = availability(False), availability(True)
        for request in requests:
            request.pop("media", None)
        return {"id": identity + 1000, "tmdbId": identity, "mediaType": kind, "status": status, "status4k": status4k,
                "seasons": [{"seasonNumber": 1, "status": 5, "status4k": 1}] if kind == "tv" else [], "requests": requests}

    def title(self, identity):
        titles = {101: ("Signal of Tomorrow", "movie"), 102: ("Hidden Valley", "movie"), 201: ("Far Horizons", "tv")}
        if identity not in titles:
            return None
        name, kind = titles[identity]
        result = {"id": identity, "mediaType": kind, "title" if kind == "movie" else "name": name,
                  "overview": "Original test metadata for the loopback Seerr contract.", "voteAverage": 8.1,
                  "releaseDate" if kind == "movie" else "firstAirDate": "2026-01-10", "mediaInfo": self.media(identity, kind)}
        if kind == "tv":
            result["seasons"] = [{"id": number * 100, "seasonNumber": number, "name": f"Season {number}", "episodeCount": 6} for number in (1, 2, 3)]
        return result


STATE = SeerrContract()


def validated_mode(body):
    if not isinstance(body, dict) or body.get("user") not in ("viewer", "admin", "restricted", "quota"):
        raise ValueError("Known fixture user required")
    booleans = {"reset", "emptyDiscovery", "restricted", "movieRestricted", "tvRestricted"}
    limits = {"authDelayMs": 10000, "browseDelayMs": 5000, "detailDelayMs": 5000,
              "failBrowse": 20, "failDetail": 20, "requestPageSize": 20,
              "movieQuotaRemaining": 10000, "tvQuotaRemaining": 10000}
    if set(body) - booleans - set(limits) - {"user"}:
        raise ValueError("Unknown control")
    for key, value in body.items():
        if key in booleans and type(value) is not bool:
            raise ValueError("Boolean control required")
        if key in limits and (type(value) is not int or not (1 if key == "requestPageSize" else 0) <= value <= limits[key]):
            raise ValueError("Control is outside its bound")
    return {key: value for key, value in body.items() if key not in ("user", "reset")}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def body(self):
        return json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")

    def respond(self, value=None, status=200, cookie=None):
        data = b"" if value is None else json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        try:
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def user(self):
        if self.headers.get("X-Api-Key") == "fixture-seerr":
            return STATE.user("admin")
        cookie = self.headers.get("Cookie", "")
        for name in ("viewer", "restricted", "quota"):
            if f"connect.sid=fixture-{name}" in cookie:
                return STATE.user(name)
        return None

    def route(self):
        parsed = urlsplit(self.path)
        return parsed.path.removeprefix("/api/v1/").rstrip("/"), {key: values[0] for key, values in parse_qs(parsed.query).items()}

    def do_GET(self):
        path, query = self.route()
        if path == "qa/state":
            with STATE.lock:
                return self.respond({"events": copy.deepcopy(STATE.events), "requests": copy.deepcopy(STATE.requests), "modes": copy.deepcopy(STATE.modes)})
        user = self.user()
        if not user:
            return self.respond({"error": "Access denied"}, 403)
        name = user["username"]
        mode = STATE.mode(name)
        with STATE.lock:
            STATE.events.append({"method": "GET", "path": path, "user": name, "query": query})
        if path == "auth/me":
            time.sleep(mode.get("authDelayMs", 0) / 1000)
            return self.respond(user)
        if path in ("discover/trending", "search"):
            time.sleep(mode.get("browseDelayMs", 0) / 1000)
            if STATE.consume_failure(name, "failBrowse"):
                return self.respond({"error": "Temporary fixture discovery failure"}, 503)
            with STATE.lock:
                titles = [] if mode.get("emptyDiscovery") else [STATE.title(identity) for identity in (101, 201, 102)]
            if path == "search":
                titles = [title for title in titles if query.get("query", "").lower() in title.get("title", title.get("name", "")).lower()]
            page = max(1, int(query.get("page", "1")))
            return self.respond({"page": page, "totalPages": max(1, (len(titles) + 1) // 2), "totalResults": len(titles), "results": titles[(page - 1) * 2:page * 2]})
        if path.startswith(("movie/", "tv/")):
            time.sleep(mode.get("detailDelayMs", 0) / 1000)
            if STATE.consume_failure(name, "failDetail"):
                return self.respond({"error": "Temporary fixture detail failure"}, 503)
            with STATE.lock:
                title = STATE.title(int(path.split("/")[-1]))
            if not title:
                return self.respond({"error": "Not found"}, 404)
            title.pop("mediaType", None)  # Detail routes omit this field in Seerr.
            return self.respond(title)
        if path.startswith("user/") and path.endswith("/quota"):
            return self.respond(STATE.quota(name))
        if path.startswith("user/") and path.endswith("/requests"):
            owner = int(path.split("/")[1])
            if owner != user["id"] and not user["permissions"] & 2:
                return self.respond({"error": "Access denied"}, 403)
            with STATE.lock:
                rows = [copy.deepcopy(request) for request in STATE.requests if request["requestedBy"]["id"] == owner]
            skip, take = int(query.get("skip", 0)), int(query.get("take", 20))
            take = min(max(1, take), mode.get("requestPageSize", 20))
            return self.respond({"pageInfo": {"results": len(rows), "pages": (len(rows) + take - 1) // take}, "results": rows[skip:skip + take]})
        return self.respond({"error": "Not found"}, 404)

    def do_POST(self):
        path, _ = self.route()
        body = self.body()
        if path == "qa/control":
            try:
                updates = validated_mode(body)
            except (ValueError, TypeError):
                return self.respond({"error": "Invalid fixture mode"}, 400)
            name = body["user"]
            with STATE.lock:
                mode = {} if body.get("reset") else copy.deepcopy(STATE.modes.get(name, {}))
                mode.update(updates)
                STATE.modes[name] = mode
            return self.respond({"user": name, "mode": mode})
        if path == "qa/reset":
            with STATE.lock:
                STATE.requests = []
                STATE.events = []
            return self.respond()
        if path == "auth/jellyfin":
            name = body.get("username", "viewer")
            time.sleep(STATE.mode(name).get("authDelayMs", 0) / 1000)
            with STATE.lock:
                STATE.events.append({"method": "POST", "path": path, "user": name})
            if body.get("password") != "demo" or name not in ("viewer", "restricted", "quota"):
                return self.respond({"error": "Access denied"}, 403)
            return self.respond(STATE.user(name), cookie=f"connect.sid=fixture-{name}; Path=/; HttpOnly; SameSite=Lax")
        user = self.user()
        if not user:
            return self.respond({"error": "Access denied"}, 403)
        if path == "request":
            if not user["permissions"] or user["username"] == "quota":
                return self.respond({"error": "Permission or quota denied"}, 403)
            kind, identity = body.get("mediaType"), body.get("mediaId")
            seasons = body.get("seasons", [])
            if kind not in ("movie", "tv") or identity not in (101, 102, 201) or (kind == "tv" and (not seasons or (1 in seasons and not body.get("is4k", False)))):
                return self.respond({"error": "No seasons available"}, 202)
            mode = STATE.mode(user["username"])
            remaining = mode.get(kind + "QuotaRemaining")
            cost = len(seasons) if kind == "tv" else 1
            if mode.get(kind + "Restricted", mode.get("restricted", False)) or (remaining is not None and cost > remaining):
                return self.respond({"error": "Fixture quota exceeded"}, 403)
            with STATE.lock:
                if any(request["media"]["tmdbId"] == identity and request["is4k"] == body.get("is4k", False) for request in STATE.requests):
                    return self.respond({"error": "Already requested"}, 409)
                STATE.next_id += 1
                request = {"id": STATE.next_id, "status": 2 if user["permissions"] & 2 else 1, "type": kind, "is4k": body.get("is4k", False),
                           "media": {"id": identity + 1000, "tmdbId": identity, "mediaType": kind, "status": 3}, "requestedBy": user,
                           "seasons": [{"seasonNumber": number} for number in seasons]}
                STATE.requests.append(request)
                if remaining is not None:
                    STATE.modes[user["username"]][kind + "QuotaRemaining"] = max(0, remaining - cost)
                STATE.events.append({"method": "POST", "path": path, "body": body})
            return self.respond(request, 201)
        return self.respond({"error": "Not found"}, 404)

    def do_DELETE(self):
        path, _ = self.route()
        user = self.user()
        if not user:
            return self.respond({"error": "Access denied"}, 403)
        if path.startswith("request/"):
            identity = int(path.split("/")[-1])
            with STATE.lock:
                request = next((request for request in STATE.requests if request["id"] == identity), None)
                if request is None:
                    return self.respond({"error": "Not found"}, 404)
                if not user["permissions"] & 2 and (request["status"] != 1 or request["requestedBy"]["id"] != user["id"]):
                    return self.respond({"error": "Access denied"}, 401)
                STATE.requests.remove(request)
                STATE.events.append({"method": "DELETE", "path": path})
            return self.respond(status=204)
        return self.respond({"error": "Not found"}, 404)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18768)
    args = parser.parse_args()
    server = LoopbackHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Seerr contract fixture on http://127.0.0.1:{server.server_port}", flush=True)
    server.serve_forever()
