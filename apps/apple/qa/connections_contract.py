"""Loopback contract helper for advanced connection tests. Never use with a real server."""
import json
import secrets
import socket
import threading


class ConnectionsContract:
    def __init__(self):
        self._requests = {}
        self._lock = threading.Lock()
        self._enabled = True
        self._logout_count = 0

    def handle(self, method, path, query, body, headers):
        """Return (status, JSON body), or None when the parent fixture owns the route."""
        if path == "/streamyfin/config" and method == "GET":
            if 'Token="fixture-' not in headers.get("Authorization", ""): return 401, {}
            return 200, {"settings": {"forwardSkipTime": {"value": 30, "locked": True}, "rewindSkipTime": {"value": 10}, "defaultPlaybackSpeed": {"value": 1.25, "locked": True}, "defaultBitrate": {"value": 4000000, "locked": True}, "skipIntro": {"value": "ask"}}}
        if path == "/QuickConnect/Enabled" and method == "GET":
            return 200, self._enabled
        if path == "/QuickConnect/Initiate" and method == "POST":
            if not self._enabled:
                return 401, {"Message": "Quick Connect disabled"}
            secret = secrets.token_hex(24)
            code = str(secrets.randbelow(900000) + 100000)
            with self._lock:
                while any(request["Code"] == code for request in self._requests.values()):
                    code = str(secrets.randbelow(900000) + 100000)
                result = {"Secret": secret, "Code": code, "Authenticated": False}
                self._requests[secret] = result
            return 200, dict(result)
        if path == "/QuickConnect/Connect" and method == "GET":
            secret = query.get("secret", "")
            with self._lock:
                result = self._requests.get(secret)
                return (200, dict(result)) if result else (404, {"Message": "Expired code"})
        if path == "/Users/AuthenticateWithQuickConnect" and method == "POST":
            with self._lock:
                result = self._requests.get(body.get("Secret", ""))
                if not result or not result["Authenticated"]:
                    return 401, {"Message": "Approval required"}
                del self._requests[result["Secret"]]
            return 200, {"AccessToken": "fixture-quickconnect", "User": {"Id": "quickconnect", "Name": "Quick Connect Test"}}
        if path == "/qa/quick-connect/approve" and method == "POST":
            with self._lock:
                result = next((request for request in self._requests.values() if request["Code"] == body.get("code")), None)
                if not result:
                    return 404, {"Message": "Unknown code"}
                result["Authenticated"] = True
            return 200, {"Approved": True}
        if path == "/qa/quick-connect/expire" and method == "POST":
            with self._lock:
                self._requests = {secret: request for secret, request in self._requests.items() if request["Code"] != body.get("code")}
            return 200, {}
        if path == "/qa/quick-connect/enabled" and method == "POST":
            with self._lock:
                self._enabled = bool(body.get("enabled", True))
            return 200, {}
        if path == "/qa/gateway" and method == "GET":
            # Only presence/match booleans are returned. Values and real credentials are never echoed.
            return 200, {"HasGatewayHeader": headers.get("X-Reel-Fixture-Gateway") == "fixture-gateway-secret",
                         "HasJellyfinAuthorization": headers.get("Authorization", "").startswith("MediaBrowser ")}
        if path == "/qa/quick-connect/state" and method == "GET":
            with self._lock:
                return 200, {"LogoutCount": self._logout_count}
        if path == "/Sessions/Logout" and method == "POST" and 'Token="fixture-quickconnect"' in headers.get("Authorization", ""):
            with self._lock:
                self._logout_count += 1
        return None


class DiscoveryContract:
    """Unicast loopback UDP responder; it never binds a public/LAN interface."""
    def __init__(self, http_port=18766, udp_port=17359):
        self.http_port = http_port
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._socket.bind(("127.0.0.1", udp_port))
        self.port = self._socket.getsockname()[1]
        self._socket.settimeout(0.2)
        self._stopped = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self._thread.start()
        return self

    def _run(self):
        while not self._stopped.is_set():
            try:
                data, address = self._socket.recvfrom(8192)
                if data.lower() == b"who is jellyfinserver?":
                    response = {"Id": "fixture-discovery", "Name": "Reel Nearby Test Server",
                                "Address": f"http://127.0.0.1:{self.http_port}"}
                    self._socket.sendto(json.dumps(response).encode(), address)
            except socket.timeout:
                continue
            except OSError:
                return

    def stop(self):
        self._stopped.set()
        self._socket.close()
        self._thread.join(timeout=1)
