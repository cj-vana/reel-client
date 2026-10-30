#!/usr/bin/env python3
"""Owned loopback-only browse QA server. Requires a fresh supervisor nonce.

This entrypoint is intentionally separate from the existing 18766 fixture and
never discovers, forwards to, or sends a request to any Jellyfin server.
"""
import argparse
import json
import re
import signal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

from browse_integrity_contract import Contract, Reply


class Server(ThreadingHTTPServer):
    allow_reuse_address = False
    daemon_threads = True
    block_on_close = False

    def server_bind(self):
        if self.server_address[0] != "127.0.0.1" or self.server_address[1] not in (19140, 19141):
            raise ValueError("Only owned loopback19140/19141 are supported")
        super().server_bind()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def send(self, status, value=None, content_type="application/json"):
        data = value if isinstance(value, bytes) else json.dumps(value, separators=(",", ":")).encode() if value is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def handle_request(self, method):
        receipt = None
        try:
            if self.client_address[0] != "127.0.0.1":
                return self.send(403)
            parsed = urlsplit(self.path)
            path = parsed.path
            if path.startswith("/jellyfin/"):
                path = path[len("/jellyfin"):]
            pairs = parse_qsl(parsed.query, keep_blank_values=True)
            if len(pairs) > 50 or len({key.lower() for key, _ in pairs}) != len(pairs):
                return self.send(400, {"error": "Repeated or excessive query keys"})
            query = {k.lower(): v for k, v in pairs}
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 <= length <= 65536:
                return self.send(413)
            body = json.loads(self.rfile.read(length)) if length else {}
            if path == "/qa/status" and method == "GET":
                if self.headers.get("X-Reel-QA-Nonce") != self.server.nonce:
                    return self.send(403)
                return self.send(200, {"kind": "reel-native-browse-fixture", "nonce": self.server.nonce, "sourceSHA256": self.server.source_sha, "port": self.server.server_port})
            if path == "/System/Info/Public" and method == "GET":
                return self.send(200, {"ServerName": "Synthetic browse " + str(self.server.server_port), "Version": "12.3.0"})
            if path == "/Users/AuthenticateByName" and method == "POST":
                if not isinstance(body, dict) or not self.server.contract.valid_user(body.get("Username")) or body.get("Pw") != "demo":
                    return self.send(401)
                user = body["Username"]
                return self.send(200, {"AccessToken": "fixture-" + user, "User": {"Id": user, "Name": user}})
            match = re.search(r'Token="fixture-(browse-[A-Za-z0-9_-]{1,100})"', self.headers.get("Authorization", ""))
            user = match[1] if match else None
            if not user:
                return self.send(401)
            if path.startswith("/qa/") and self.headers.get("X-Reel-QA-Nonce") != self.server.nonce:
                return self.send(403)
            receipt = self.server.contract.begin(user, method, path, query)
            receipt["queryItems"] = pairs
            if method == "GET" and re.fullmatch(r"/Items/[A-Za-z0-9_-]+/Images/(Primary|Backdrop|Thumb)", path):
                kind = "poster" if path.endswith("Primary") else "backdrop"
                # Existing generated original QA artwork, read-only. No generator.
                image = (Path(__file__).resolve().parent / "artwork" / (kind + "-0.jpg")).read_bytes()
                reply = Reply(200, image)
                content_type = "image/jpeg"
            else:
                reply = self.server.contract.dispatch(user, method, path, query, body, receipt)
                content_type = "application/json"
            self.server.contract.wait(user, reply)
            try:
                self.send(reply.status, reply.value, content_type)
                self.server.contract.complete(receipt, reply.status)
            except (BrokenPipeError, ConnectionResetError) as error:
                self.server.contract.complete(receipt, reply.status, type(error).__name__)
        except (ValueError, TypeError, KeyError) as error:
            if receipt is not None:
                self.server.contract.complete(receipt, 400, type(error).__name__)
            try:
                self.send(400, {"error": str(error)})
            except (BrokenPipeError, ConnectionResetError):
                pass

    def do_GET(self):
        self.handle_request("GET")

    def do_POST(self):
        self.handle_request("POST")

    def do_DELETE(self):
        self.handle_request("DELETE")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, choices=(19140, 19141), required=True)
    parser.add_argument("--nonce", required=True)
    parser.add_argument("--source-sha256", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{32}", args.nonce) or not re.fullmatch(r"[0-9a-f]{64}", args.source_sha256):
        parser.error("Require canonical fresh nonce and approved source digest")
    stopping = False

    def stop(_signal, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGINT, signal.SIGTERM})
    with Server(("127.0.0.1", args.port), Handler) as server:
        server.nonce = args.nonce
        server.source_sha = args.source_sha256
        server.contract = Contract()
        server.timeout = 0.2
        print(json.dumps({"event": "ready", "port": args.port, "sourceSHA256": args.source_sha256}), flush=True)
        while not stopping:
            server.handle_request()
        print(json.dumps({"event": "stopped", "port": args.port}), flush=True)


if __name__ == "__main__":
    main()
