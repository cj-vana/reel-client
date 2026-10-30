#!/usr/bin/env python3
"""Loopback Jellyfin remote/SyncPlay contract fixture, including real WebSocket frames.

Run: python3 qa/remote_contract.py --port 18769
Sign in: any username / demo. No upstream server is contacted.
"""
import argparse
import base64
import copy
import hashlib
import json
import socket
import struct
import threading
import time
import uuid
from datetime import datetime, timezone, timedelta
from urllib.parse import parse_qs, urlsplit

from fixture_server import Handler as MediaHandler, catalog, LOCK, STATE, TICKS
from loopback_server import LoopbackHTTPServer

REMOTE_LOCK = threading.RLock()
REMOTE = {"events": [], "paused": False, "position": 5 * TICKS, "playing": True, "members": {}, "groups": {}, "queues": {}, "indices": {}}
SOCKETS = {}
MODES = {}


def validated_mode(body):
    if not isinstance(body, dict):
        raise ValueError("Control body must be an object")
    booleans = {"reset", "sessionsEmpty", "groupsEmpty", "mediaControl", "canSeek", "acceptsVideo", "disconnectSockets"}
    limits = {"sessionsDelayMs": 5000, "groupsDelayMs": 5000, "failSessions": 20, "failGroups": 20, "failCommand": 20}
    if set(body) - booleans - set(limits) - {"syncAccess"}:
        raise ValueError("Unknown control")
    for key, value in body.items():
        if key in booleans and type(value) is not bool:
            raise ValueError("Boolean control required")
        if key in limits and (type(value) is not int or not 0 <= value <= limits[key]):
            raise ValueError("Control is outside its bound")
        if key == "syncAccess" and value not in ("None", "JoinGroups", "CreateAndJoinGroups"):
            raise ValueError("Invalid SyncPlay access")
    return {key: value for key, value in body.items() if key not in ("reset", "disconnectSockets")}


def timestamp(delta=0):
    return (datetime.now(timezone.utc) + timedelta(seconds=delta)).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def group(identifier="fixture-group", name="Test watch party"):
    return {"GroupId": identifier, "GroupName": name, "State": "Paused", "Participants": [], "LastUpdatedAt": timestamp()}


REMOTE["groups"]["fixture-group"] = group()


class Peer:
    def __init__(self, connection):
        self.connection = connection
        self.lock = threading.Lock()

    def frame(self, payload, opcode=1):
        payload = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        if len(payload) < 126:
            header = bytes([0x80 | opcode, len(payload)])
        elif len(payload) < 65536:
            header = bytes([0x80 | opcode, 126]) + struct.pack("!H", len(payload))
        else:
            header = bytes([0x80 | opcode, 127]) + struct.pack("!Q", len(payload))
        with self.lock:
            self.connection.sendall(header + payload)


def emit(user, message_type, data):
    with REMOTE_LOCK:
        peers = list(SOCKETS.get(user, []))
    for peer in peers:
        try:
            peer.frame({"MessageType": message_type, "Data": data, "MessageId": str(uuid.uuid4())})
        except OSError:
            pass


def update(user, kind, data):
    with REMOTE_LOCK:
        identifier = REMOTE["members"].get(user)
        recipients = [name for name, joined in REMOTE["members"].items() if joined == identifier] if kind in ("PlayQueue", "StateUpdate", "UserJoined", "UserLeft") else [user]
    if identifier:
        for recipient in recipients:
            emit(recipient, "SyncPlayGroupUpdate", {"GroupId": identifier, "Type": kind, "Data": data})


def publish_command(user, command, position=0):
    with REMOTE_LOCK:
        identifier = REMOTE["members"].get(user)
        queue = REMOTE["queues"].get(identifier, [])
        if not identifier or not queue:
            return
        entry = queue[REMOTE["indices"].get(identifier, 0)]
        recipients = [name for name, joined in REMOTE["members"].items() if joined == identifier]
        state = "Playing" if command == "Unpause" else "Idle" if command == "Stop" else "Paused"
        REMOTE["groups"][identifier]["State"] = state
    update(user, "StateUpdate", {"State": state, "Reason": command})
    command_data = {"GroupId": identifier, "PlaylistItemId": entry["PlaylistItemId"], "When": timestamp(0.08),
                    "PositionTicks": max(0, position), "Command": command, "EmittedAt": timestamp()}
    for recipient in recipients:
        emit(recipient, "SyncPlayCommand", command_data)


def publish_queue(user, position=0):
    with REMOTE_LOCK:
        identifier = REMOTE["members"].get(user)
        queue = copy.deepcopy(REMOTE["queues"].get(identifier, []))
        index = REMOTE["indices"].get(identifier, 0)
    update(user, "PlayQueue", {"Reason": "NewPlaylist", "LastUpdate": timestamp(), "Playlist": queue,
                              "PlayingItemIndex": index if queue else -1, "StartPositionTicks": position, "IsPlaying": False})


class Handler(MediaHandler):
    def mode(self):
        with REMOTE_LOCK:
            return copy.deepcopy(MODES.get(self.user(), {}))

    def consume_failure(self, name):
        with REMOTE_LOCK:
            mode = MODES.get(self.user(), {})
            if mode.get(name, 0) > 0:
                mode[name] -= 1
                return True
            return False

    def receipt(self, path, body=None, query=None):
        with REMOTE_LOCK:
            REMOTE["events"].append({"path": path, "user": self.user(), "body": body or {}, "query": query or {}})

    def do_GET(self):
        parsed = urlsplit(self.path)
        path = parsed.path
        if path == "/socket":
            return self.websocket()
        if path == "/qa/remote-state":
            with REMOTE_LOCK:
                result = copy.deepcopy(REMOTE)
                result["modes"] = copy.deepcopy(MODES)
                result["sockets"] = {user: len(peers) for user, peers in SOCKETS.items()}
            return self.respond(result)
        if path == "/GetUtcTime":
            return self.respond({"RequestReceptionTime": timestamp(), "ResponseTransmissionTime": timestamp()})
        if path in ("/Sessions", "/Users/Me", "/SyncPlay/List") or path.startswith("/SyncPlay/"):
            if not self.user() or self.user() == "expired":
                return self.respond(status=401)
            if self.user() == "remote-denied":
                return self.respond(status=403)
            self.receipt(path, query=parse_qs(parsed.query))
            mode = self.mode()
            if path in ("/Sessions", "/SyncPlay/List"):
                time.sleep(mode.get("sessionsDelayMs" if path == "/Sessions" else "groupsDelayMs", 0) / 1000)
                if self.consume_failure("failSessions" if path == "/Sessions" else "failGroups"):
                    return self.respond(status=503)
            if path == "/Sessions":
                if mode.get("sessionsEmpty"):
                    return self.respond([])
                with REMOTE_LOCK:
                    sessions = [{"Id": "qa-living-room", "DeviceId": "qa-tv", "DeviceName": "New account player" if self.user().startswith("remote-new-") else "Living room TV", "Client": "Jellyfin Test TV", "UserName": "Test viewer",
                                 "SupportsRemoteControl": True, "SupportsMediaControl": mode.get("mediaControl", True), "PlayableMediaTypes": ["Video"] if mode.get("acceptsVideo", True) else ["Audio"],
                                 "NowPlayingItem": catalog()[0] if REMOTE["playing"] else None,
                                 "PlayState": {"PositionTicks": REMOTE["position"], "IsPaused": REMOTE["paused"], "CanSeek": mode.get("canSeek", True)}}]
                return self.respond(sessions)
            if path == "/Users/Me":
                return self.respond({"Policy": {"EnableMediaPlayback": True, "SyncPlayAccess": mode.get("syncAccess", "JoinGroups" if self.user() == "join-only" else "CreateAndJoinGroups")}})
            with REMOTE_LOCK:
                if path == "/SyncPlay/List":
                    return self.respond([] if mode.get("groupsEmpty") else list(REMOTE["groups"].values()))
                result = REMOTE["groups"].get(path.rsplit("/", 1)[-1])
                return self.respond(result, status=200 if result else 404)
        return super().do_GET()

    def do_POST(self):
        parsed = urlsplit(self.path)
        path = parsed.path
        if path == "/qa/remote-control":
            user = self.user()
            if not user:
                self.read_body()
                return self.respond(status=401)
            try:
                body = self.read_body()
                updates = validated_mode(body)
            except (ValueError, TypeError):
                return self.respond(status=400)
            with REMOTE_LOCK:
                mode = {} if body.get("reset") else copy.deepcopy(MODES.get(user, {}))
                mode.update(updates)
                MODES[user] = mode
                peers = list(SOCKETS.get(user, [])) if body.get("disconnectSockets") else []
            self.receipt(path, body=body)
            for peer in peers:
                try:
                    peer.frame(struct.pack("!H", 1001), opcode=8)
                    peer.connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            return self.respond({"user": user, "mode": mode})
        if not (path.startswith("/SyncPlay/") or (path.startswith("/Sessions/") and "/Playing" in path and not path.startswith("/Sessions/Playing"))):
            return super().do_POST()
        body = self.read_body()
        query = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        user = self.user()
        if not user:
            return self.respond(status=401)
        if user == "remote-denied":
            return self.respond(status=403)
        self.receipt(path, body=body, query=query)
        if (path.startswith("/Sessions/") or path in ("/SyncPlay/Pause", "/SyncPlay/Unpause", "/SyncPlay/Seek", "/SyncPlay/Stop", "/SyncPlay/NextItem", "/SyncPlay/PreviousItem", "/SyncPlay/Queue", "/SyncPlay/SetNewQueue")) and self.consume_failure("failCommand"):
            return self.respond(status=503)
        if user.startswith("group-command-delayed-") and path == "/SyncPlay/Pause":
            time.sleep(0.4)
            return self.respond(status=403)
        if path.startswith("/Sessions/"):
            if user.startswith("remote-delayed-"): time.sleep(0.4)
            with REMOTE_LOCK:
                command = path.rsplit("/", 1)[-1]
                if command == "Pause": REMOTE["paused"] = True
                elif command == "Unpause": REMOTE["paused"] = False
                elif command == "Stop": REMOTE["playing"] = False
                elif command == "Seek": REMOTE["position"] = int(query.get("seekPositionTicks", 0))
                elif query.get("playCommand") == "PlayNow": REMOTE["playing"] = True
            return self.respond(status=204)
        if path == "/SyncPlay/New":
            if user == "join-only":
                return self.respond(status=403)
            if user.startswith("group-delayed-"): time.sleep(0.4)
            identifier = str(uuid.uuid4())
            with REMOTE_LOCK:
                created = group(identifier, body.get("GroupName", "Watch together"))
                created["Participants"] = [user]
                REMOTE["groups"][identifier] = created
                REMOTE["members"][user] = identifier
                REMOTE["queues"][identifier] = []
                REMOTE["indices"][identifier] = 0
            self.respond(created)
            update(user, "GroupJoined", created)
            return
        if path == "/SyncPlay/Join":
            identifier = body.get("GroupId")
            with REMOTE_LOCK:
                joined = REMOTE["groups"].get(identifier)
                if not joined:
                    return self.respond(status=404)
                REMOTE["members"][user] = identifier
                if user not in joined["Participants"]: joined["Participants"].append(user)
                REMOTE["queues"].setdefault(identifier, [{"ItemId": "movie-1", "PlaylistItemId": str(uuid.uuid4())}])
                REMOTE["indices"].setdefault(identifier, 0)
            self.respond(status=204)
            update(user, "GroupJoined", joined)
            publish_queue(user, 3 * TICKS)
            return
        with REMOTE_LOCK:
            identifier = REMOTE["members"].get(user)
        if path == "/SyncPlay/Leave":
            if identifier:
                update(user, "GroupLeft", None)
                with REMOTE_LOCK:
                    REMOTE["members"].pop(user, None)
                    if identifier in REMOTE["groups"]:
                        REMOTE["groups"][identifier]["Participants"] = [x for x in REMOTE["groups"][identifier]["Participants"] if x != user]
            return self.respond(status=204)
        if not identifier:
            return self.respond(status=400)
        if path == "/SyncPlay/SetNewQueue":
            with REMOTE_LOCK:
                REMOTE["queues"][identifier] = [{"ItemId": item, "PlaylistItemId": str(uuid.uuid4())} for item in body.get("PlayingQueue", [])]
                REMOTE["indices"][identifier] = body.get("PlayingItemPosition", 0)
            self.respond(status=204)
            publish_queue(user, body.get("StartPositionTicks", 0))
            return
        if path == "/SyncPlay/Queue":
            with REMOTE_LOCK:
                entries = [{"ItemId": item, "PlaylistItemId": str(uuid.uuid4())} for item in body.get("ItemIds", [])]
                if body.get("Mode") == "QueueNext":
                    index = REMOTE["indices"].get(identifier, 0) + 1
                    REMOTE["queues"][identifier][index:index] = entries
                else:
                    REMOTE["queues"][identifier].extend(entries)
            self.respond(status=204)
            publish_queue(user)
            return
        if path in ("/SyncPlay/NextItem", "/SyncPlay/PreviousItem"):
            with REMOTE_LOCK:
                index = REMOTE["indices"].get(identifier, 0) + (1 if path.endswith("NextItem") else -1)
                valid = 0 <= index < len(REMOTE["queues"].get(identifier, []))
                if valid: REMOTE["indices"][identifier] = index
            self.respond(status=204)
            if valid: publish_queue(user)
            else: publish_command(user, "Stop")
            return
        self.respond(status=204)
        if path == "/SyncPlay/Ready": publish_command(user, "Unpause", body.get("PositionTicks", 0))
        elif path == "/SyncPlay/Buffering": publish_command(user, "Pause", body.get("PositionTicks", 0))
        elif path == "/SyncPlay/Pause": publish_command(user, "Pause", 5 * TICKS)
        elif path == "/SyncPlay/Unpause": publish_command(user, "Unpause", 5 * TICKS)
        elif path == "/SyncPlay/Seek": publish_command(user, "Seek", body.get("PositionTicks", 0))
        elif path == "/SyncPlay/Stop": publish_command(user, "Stop")

    def websocket(self):
        if not self.user():
            return self.respond(status=401)
        key = self.headers.get("Sec-WebSocket-Key")
        if not key:
            return self.respond(status=400)
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        peer = Peer(self.connection)
        user = self.user()
        with REMOTE_LOCK:
            SOCKETS.setdefault(user, []).append(peer)
        self.close_connection = True
        try:
            while True:
                first = self.rfile.read(2)
                if len(first) != 2: return
                opcode, length = first[0] & 15, first[1] & 127
                if length == 126: length = struct.unpack("!H", self.rfile.read(2))[0]
                elif length == 127: length = struct.unpack("!Q", self.rfile.read(8))[0]
                if length > 1_048_576: return
                mask = self.rfile.read(4) if first[1] & 128 else b""
                payload = self.rfile.read(length)
                if mask: payload = bytes(value ^ mask[i % 4] for i, value in enumerate(payload))
                if opcode == 8:
                    peer.frame(b"", opcode=8)
                    return
                if opcode == 9: peer.frame(payload, opcode=10)
                if opcode == 1:
                    try: json.loads(payload)
                    except (ValueError, UnicodeDecodeError): return
        except (OSError, struct.error):
            return
        finally:
            with REMOTE_LOCK:
                if peer in SOCKETS.get(user, []): SOCKETS[user].remove(peer)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18769)
    args = parser.parse_args()
    server = LoopbackHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Reel remote + SyncPlay fixture on http://127.0.0.1:{server.server_port}", flush=True)
    server.serve_forever()
