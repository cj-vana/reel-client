"""Real HTTP checks for the isolated episode fixture, using an ephemeral owned process."""
import hashlib
import http.client
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid


@unittest.skipUnless(os.environ.get("REEL_TV_EPISODE_HTTP_TESTS") == "1", "Requires exclusive owned port18967")
class EpisodeFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.owner = "episode-http-" + uuid.uuid4().hex
        cls.temp = tempfile.TemporaryDirectory(prefix="reel-tvos-fixture-http-")
        cls.addClassCleanup(cls.temp.cleanup)
        media = Path(cls.temp.name)
        (media / "hls").mkdir()
        (media / "artwork").mkdir()
        (media / "sample.mp4").write_bytes(b"nonplayable HTTP test bytes")
        (media / "hls/index.m3u8").write_text("#EXTM3U\n#EXT-X-ENDLIST\n")
        (media / "artwork/backdrop-1.jpg").write_bytes(b"jpeg fallback")
        (media / "silent-fixture.json").write_text(json.dumps({"kind": "reel-tvos-silent-fixture", "sampleSHA256": hashlib.sha256((media / "sample.mp4").read_bytes()).hexdigest()}))
        cls.process = subprocess.Popen([sys.executable, str(Path(__file__).with_name("run-episode-fixture.py")), "--port", "18967", "--media", str(media)], env={**os.environ, "REEL_TV_QA_OWNER": cls.owner}, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        def stop_owned_process():
            if cls.process.poll() is None:
                cls.process.terminate()
                cls.process.wait(timeout=5)
            cls.process.stderr.close()
        cls.addClassCleanup(stop_owned_process)
        for _ in range(60):
            if cls.process.poll() is not None:
                raise RuntimeError("Episode test listener failed; port18967 must be exclusively owned and free")
            try:
                status, _, body = cls.request("GET", "/qa/tv-identity", owner=False)
                if status == 200 and json.loads(body).get("owner") == cls.owner:
                    return
            except OSError:
                pass
            time.sleep(.05)
        cls.process.terminate()
        cls.process.wait(timeout=5)
        raise RuntimeError("Owned episode listener did not become ready")

    @classmethod
    def request(cls, method, path, body=None, owner=True):
        headers = {"Authorization": 'MediaBrowser Token="fixture-tv-intro-auto"'}
        if owner:
            headers["X-Reel-TV-Owner"] = cls.owner
        connection = http.client.HTTPConnection("127.0.0.1", 18967, timeout=3)
        try:
            connection.request(method, path, json.dumps(body) if body is not None else None, headers)
            response = connection.getresponse()
            return response.status, response.getheader("Content-Type"), response.read()
        finally:
            connection.close()

    def setUp(self):
        self.assertEqual(self.request("POST", "/qa/reset", {})[0], 200)

    def test_control_requires_matching_owner_and_boolean_known_fields(self):
        for method, path in [("GET", "/qa/state"), ("POST", "/qa/reset"), ("DELETE", "/qa/reset")]:
            self.assertEqual(self.request(method, path, {}, owner=False)[0], 403)
        for body in [{"failSeasons": "yes"}, {"unexpected": True}, ["failSeasons"], 1]:
            self.assertEqual(self.request("POST", "/qa/tv-control", body)[0], 400)

    def test_startup_rejects_wrong_port_owner_repository_and_unmarked_media(self):
        script = str(Path(__file__).with_name("run-episode-fixture.py"))
        repository = str(Path(__file__).resolve().parents[3])
        with tempfile.TemporaryDirectory(prefix="reel-tvos-fixture-unmarked-") as unmarked:
            for port, media, owner in [(8096, self.temp.name, self.owner), (18967, self.temp.name, ""), (18967, repository, self.owner), (18967, unmarked, self.owner)]:
                result = subprocess.run([sys.executable, script, "--port", str(port), "--media", media], env={**os.environ, "REEL_TV_QA_OWNER": owner}, capture_output=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)

    def test_adjacent_order_crosses_seasons_and_browser_filters(self):
        page = json.loads(self.request("GET", "/Shows/series-7/Episodes?adjacentTo=episode-2-1")[2])
        self.assertEqual([i["Id"] for i in page["Items"]], [f"episode-{s}-{n}" for s in [1, 2] for n in [1, 2, 3]])
        page = json.loads(self.request("GET", "/Shows/series-7/Episodes?seasonId=season-2")[2])
        self.assertEqual(page["TotalRecordCount"], 3)
        self.assertTrue(all(i["ParentIndexNumber"] == 2 for i in page["Items"]))
        self.assertEqual(self.request("GET", "/Shows/series-7/Episodes?seasonId=unexpected")[0], 400)

    def test_failure_empty_and_reset_are_isolated(self):
        self.request("POST", "/qa/tv-control", {"failSeasons": True, "failAdjacent": True})
        self.assertEqual(self.request("GET", "/Shows/series-7/Seasons")[0], 503)
        self.assertEqual(self.request("GET", "/Shows/series-7/Episodes?adjacentTo=episode-1-1")[0], 503)
        self.request("POST", "/qa/tv-control", {"failSeasons": False, "emptySeasons": True})
        self.assertEqual(json.loads(self.request("GET", "/Shows/series-7/Seasons")[2])["Items"], [])
        self.request("POST", "/qa/reset", {})
        self.assertEqual(len(json.loads(self.request("GET", "/Shows/series-7/Seasons")[2])["Items"]), 2)

    def test_intro_modes_and_optional_artwork_mime(self):
        self.assertEqual(json.loads(self.request("GET", "/streamyfin/config")[2])["settings"]["skipIntro"]["value"], "auto")
        self.assertEqual(json.loads(self.request("GET", "/MediaSegments/episode-1-1")[2])["Items"][0]["EndTicks"], 100_000_000)
        self.request("POST", "/qa/tv-control", {"noIntro": True})
        self.assertEqual(json.loads(self.request("GET", "/MediaSegments/episode-1-1")[2])["Items"], [])
        self.assertEqual(self.request("GET", "/Items/series-7/Images/Backdrop")[1], "image/jpeg")
        (Path(self.temp.name) / "artwork/backdrop-1.png").write_bytes(b"png fixture bytes")
        self.assertEqual(self.request("GET", "/Items/series-7/Images/Backdrop")[1], "image/png")
        self.request("POST", "/qa/tv-control", {"noArtwork": True})
        self.assertEqual(self.request("GET", "/Items/series-7/Images/Backdrop")[0], 404)


if __name__ == "__main__":
    unittest.main()
