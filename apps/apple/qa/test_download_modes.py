import json
import threading
import time
import unittest
import urllib.error
import urllib.request
import uuid
from loopback_server import LoopbackHTTPServer

from fixture_server import Handler


class DownloadModeHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = LoopbackHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True); cls.thread.start()
        cls.origin = "http://127.0.0.1:" + str(cls.server.server_port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join(timeout=2)

    def setUp(self): self.user = "download-mode-" + str(uuid.uuid4())

    def request(self, path, body=None, actor=None):
        user = self.user if actor is None else actor
        headers = {"Authorization": 'MediaBrowser Token="fixture-' + user + '"'} if user else {}
        if body is not None: headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.origin + path, data=None if body is None else json.dumps(body).encode(), headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=4) as response:
                data = response.read()
                return response.status, json.loads(data) if "application/json" in response.headers.get("Content-Type", "") and data else data
        except urllib.error.HTTPError as error:
            try: return error.code, error.read()
            finally: error.close()

    def control(self, body): self.assertEqual(self.request("/qa/download-control", body)[0], 200)
    def media(self, suffix): return "/Videos/fixture/" + suffix + "?ApiKey=fixture-" + self.user

    def test_permission_override_is_scoped_and_invalid_update_is_atomic(self):
        self.control({"downloadAllowed": False})
        self.assertFalse(self.request("/Users/Me")[1]["Policy"]["EnableContentDownloading"])
        self.assertTrue(self.request("/Users/Me", actor="other-" + self.user)[1]["Policy"]["EnableContentDownloading"])
        self.assertEqual(self.request("/qa/download-control", {"downloadAllowed": True, "hlsDelayMs": 15001})[0], 400)
        self.assertFalse(self.request("/Users/Me")[1]["Policy"]["EnableContentDownloading"])
        self.control({"downloadAllowed": True}); self.assertTrue(self.request("/Users/Me")[1]["Policy"]["EnableContentDownloading"])

    def test_manifest_and_segment_failures_are_counted_independently_and_recover(self):
        self.control({"failHLS": 1, "failureStage": "manifest"})
        self.assertEqual(self.request(self.media("master.m3u8"))[0], 503)
        status, manifest = self.request(self.media("master.m3u8")); self.assertEqual(status, 200); self.assertTrue(manifest.startswith(b"#EXTM3U"))
        self.control({"failHLS": 1, "failureStage": "segment"})
        self.assertEqual(self.request(self.media("master.m3u8"))[0], 200)
        self.assertEqual(self.request(self.media("segment000.ts"))[0], 503)
        self.assertEqual(self.request(self.media("segment000.ts"))[0], 200)
        state = self.request("/qa/download-state")[1]
        self.assertEqual([(r["stage"], r["failed"]) for r in state["requests"]], [("manifest", True), ("manifest", False), ("manifest", False), ("segment", True), ("segment", False)])
        self.assertEqual(self.request("/qa/download-state", actor="other-" + self.user)[1]["requests"], [])

    def test_delay_and_reset_leave_default_media_behavior_unchanged(self):
        self.control({"hlsDelayMs": 100, "downloadAllowed": False})
        before = time.monotonic(); self.assertEqual(self.request(self.media("master.m3u8"))[0], 200)
        self.assertGreaterEqual(time.monotonic() - before, 0.09)
        self.control({"reset": True})
        self.assertEqual(self.request("/qa/download-state")[1]["mode"], {})
        self.assertTrue(self.request("/Users/Me")[1]["Policy"]["EnableContentDownloading"])
        self.assertEqual(self.request(self.media("master.m3u8"))[0], 200)

    def test_controls_require_fixture_authentication_and_validate_all_fields(self):
        self.assertEqual(self.request("/qa/download-control", {}, actor="")[0], 401)
        self.assertEqual(self.request("/qa/download-state", actor="")[0], 403)
        for values in [{"reset": 1}, {"downloadAllowed": 0}, {"failHLS": True}, {"failHLS": 101}, {"failureStage": "mp4"}, {"unknown": True}]:
            self.assertEqual(self.request("/qa/download-control", values)[0], 400)
        self.assertEqual(self.request("/qa/download-state")[1]["mode"], {})


if __name__ == "__main__": unittest.main()
