"""DNS-independent startup through the real synthetic HTTP fixture interfaces."""
from http.server import BaseHTTPRequestHandler
from http.client import HTTPConnection
import json
from pathlib import Path
import re
import select
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

from loopback_server import LoopbackHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "7")
        self.end_headers()
        self.wfile.write(b"fixture")

    def log_message(self, *_):
        pass


class FixtureStartupTests(unittest.TestCase):
    def get(self, port, path):
        connection = HTTPConnection("127.0.0.1", port, timeout=3)
        try:
            connection.request("GET", path)
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def test_serves_http_without_reverse_dns(self):
        with patch("socket.getfqdn", side_effect=RuntimeError("Reverse DNS unavailable")) as lookup:
            with LoopbackHTTPServer(("127.0.0.1", 0), Handler) as server:
                self.assertEqual(server.server_name, "localhost")
                self.assertGreater(server.server_port, 0)
                worker = threading.Thread(target=server.serve_forever, daemon=True)
                worker.start()
                try:
                    status, body = self.get(server.server_port, "/")
                    self.assertEqual(status, 200)
                    self.assertEqual(body, b"fixture")
                finally:
                    server.shutdown()
                    worker.join(timeout=3)
                self.assertFalse(worker.is_alive())
            lookup.assert_not_called()

    def test_rejects_non_loopback_binding(self):
        for host in ("0.0.0.0", "localhost", "192.0.2.1", "::1"):
            with self.subTest(host=host):
                with patch("socketserver.TCPServer.server_bind") as bind:
                    with self.assertRaisesRegex(ValueError, "127.0.0.1"):
                        LoopbackHTTPServer((host, 0), Handler)
                    bind.assert_not_called()

    def test_fixture_entry_points_start_without_reverse_dns(self):
        directory = Path(__file__).resolve().parent
        for filename in ("fixture_server.py", "seerr_contract.py", "remote_contract.py"):
            with self.subTest(entry=filename), tempfile.TemporaryFile(mode="w+") as errors:
                wrapper = (
                    "import runpy, socket, sys; "
                    f"sys.path.insert(0, {str(directory)!r}); "
                    'socket.getfqdn=lambda *args: (_ for _ in ()).throw(RuntimeError("Reverse DNS unavailable")); '
                    f"runpy.run_path({str(directory / filename)!r}, run_name='__main__')"
                )
                child = subprocess.Popen([sys.executable, "-c", wrapper, "--port", "0"],
                                         stdout=subprocess.PIPE, stderr=errors, text=True)
                try:
                    ready, _, _ = select.select([child.stdout], [], [], 5)
                    self.assertTrue(ready, "Fixture must report its listening address within five seconds.")
                    line = child.stdout.readline()
                    match = re.search(r"http://127\.0\.0\.1:(\d+)", line)
                    if not match:
                        errors.seek(0)
                        self.fail(f"No bound listening address: {line!r}; {errors.read()}")
                    port = int(match.group(1))
                    self.assertGreater(port, 0, "Readiness must report the actual bound port.")
                    path = "/api/v1/qa/state" if filename == "seerr_contract.py" else "/qa/state"
                    status, body = self.get(port, path)
                    self.assertEqual(status, 200)
                    self.assertIsInstance(json.loads(body), dict)
                finally:
                    child.terminate()
                    child.wait(timeout=5)
                    child.stdout.close()


if __name__ == "__main__":
    unittest.main()
