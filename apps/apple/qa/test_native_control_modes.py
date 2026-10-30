import json
import threading
import time
import unittest
import urllib.error
import urllib.request
import uuid
from loopback_server import LoopbackHTTPServer

from fixture_server import Handler


class NativeControlModeHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = LoopbackHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.origin = "http://127.0.0.1:" + str(cls.server.server_port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join(timeout=2)

    def setUp(self):
        self.user = "native-modes-" + str(uuid.uuid4())

    def request(self, path, body=None, method=None, user=None):
        headers = {"Authorization": 'MediaBrowser Token="fixture-' + (user or self.user) + '"'}
        data = None if body is None else json.dumps(body).encode()
        if data is not None: headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.origin + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=8) as response:
                data = response.read()
                if "application/json" in response.headers.get("Content-Type", ""):
                    return response.status, json.loads(data) if data else None
                return response.status, data
        except urllib.error.HTTPError as error:
            try: return error.code, error.read()
            finally: error.close()

    def tv(self, values):
        self.assertEqual(self.request("/qa/livetv-control", values)[0], 200)

    def hub(self, values):
        self.assertEqual(self.request("/qa/hub-control", values)[0], 200)

    def test_tv_modes_are_isolated_and_invalid_updates_are_atomic(self):
        self.tv({"emptyPrograms": True, "pageSize": 2})
        self.assertEqual(self.request("/LiveTv/Programs")[1]["Items"], [])
        self.assertEqual(len(self.request("/LiveTv/Programs", user="other-" + self.user)[1]["Items"]), 6)
        self.assertEqual(self.request("/qa/livetv-control", {"emptyPrograms": False, "pageSize": 0})[0], 400)
        self.assertEqual(self.request("/LiveTv/Programs")[1]["Items"], [])
        self.tv({"reset": True})
        self.assertEqual(len(self.request("/LiveTv/Programs")[1]["Items"]), 6)

    def test_tv_pagination_keeps_concrete_channel_program_and_recording_ids(self):
        self.tv({"pageSize": 2, "channelCount": 3, "recordingCount": 3})
        for route, key, total in [("Channels", "channel-", 3), ("Programs", "program-", 6), ("Recordings", "recording-", 3)]:
            first = self.request("/LiveTv/" + route)[1]
            self.assertEqual(first["TotalRecordCount"], total)
            self.assertEqual([row["Id"] for row in first["Items"]], [key + "1", key + "2"])
            second = self.request("/LiveTv/" + route + "?startIndex=2")[1]
            self.assertEqual(second["Items"][0]["Id"], key + "3")

    def test_recording_metadata_does_not_steal_playback_or_artwork_routes(self):
        status, item = self.request("/Items/recording-1")
        self.assertEqual(status, 200)
        self.assertEqual(item["Id"], "recording-1")
        status, info = self.request("/Items/recording-1/PlaybackInfo", {
            "EnableDirectPlay": True, "MaxStreamingBitrate": 120_000_000,
            "MediaSourceId": "recording-1-source",
        })
        self.assertEqual(status, 200)
        self.assertEqual(info["MediaSources"][0]["Id"], "recording-1-source")
        self.assertTrue(info["MediaSources"][0]["SupportsDirectPlay"])
        self.assertEqual(self.request("/Items/recording-1/PlaybackInfo", {
            "EnableDirectPlay": True, "MaxStreamingBitrate": 120_000_000,
        }, user="readonlytv")[0], 200)
        status, artwork = self.request("/Items/recording-1/Images/Primary")
        self.assertEqual(status, 200)
        self.assertTrue(artwork.startswith(bytes.fromhex("ffd8")))
        reports = self.request("/qa/state")[1]["reports"]
        self.assertTrue(any(row["user"] == self.user and row["path"] == "/Items/recording-1/PlaybackInfo" for row in reports))

    def test_tv_single_use_write_failures_preserve_state_until_retry(self):
        defaults = self.request("/LiveTv/Timers/Defaults?programId=program-2")[1]
        self.tv({"failPost": 1})
        self.assertEqual(self.request("/LiveTv/Timers", defaults)[0], 503)
        self.assertEqual(self.request("/LiveTv/Timers")[1]["Items"], [])
        self.assertEqual(self.request("/LiveTv/Timers", defaults)[0], 204)
        self.tv({"failDelete": 1})
        self.assertEqual(self.request("/LiveTv/Timers/timer-1", {}, method="DELETE")[0], 503)
        self.assertEqual(len(self.request("/LiveTv/Timers")[1]["Items"]), 1)
        self.assertEqual(self.request("/LiveTv/Timers/timer-1", {}, method="DELETE")[0], 204)
        state = self.request("/qa/state")[1]["livetv"][self.user]
        self.assertEqual([event["method"] for event in state["events"]], ["POST", "DELETE"])

    def test_tv_delayed_failure_is_recoverable_and_records_query(self):
        self.tv({"delayMs": 100, "failGet": 1, "failPath": "/LiveTv/Programs"})
        start = time.monotonic()
        self.assertEqual(self.request("/LiveTv/Programs?channelIds=channel-1")[0], 503)
        self.assertGreaterEqual(time.monotonic() - start, 0.09)
        self.tv({"delayMs": 0})
        self.assertEqual(self.request("/LiveTv/Programs")[0], 200)
        state = self.request("/qa/state")[1]["livetv"][self.user]
        self.assertEqual(state["requests"][0]["query"]["channelids"], "channel-1")

    def test_tv_permission_check_failure_is_scoped_and_can_recover(self):
        self.tv({"failPermissions": 1})
        self.assertEqual(self.request("/Users/Me", user="other-" + self.user)[0], 200)
        self.assertEqual(self.request("/Users/Me")[0], 503)
        recovered = self.request("/Users/Me")
        self.assertEqual(recovered[0], 200)
        self.assertTrue(recovered[1]["Policy"]["EnableLiveTvManagement"])

    def test_hub_modes_are_isolated_bounded_and_resettable(self):
        self.hub({"empty": True})
        self.assertEqual(self.request("/Items?includeItemTypes=Audio")[1]["Items"], [])
        self.assertEqual(len(self.request("/Items?includeItemTypes=Audio", user="other-" + self.user)[1]["Items"]), 2)
        self.assertEqual(self.request("/qa/hub-control", {"empty": False, "browseDelayMs": 5001})[0], 400)
        self.assertEqual(self.request("/Items?includeItemTypes=Audio")[1]["Items"], [])
        self.hub({"reset": True})
        self.assertEqual(len(self.request("/Items?includeItemTypes=Audio")[1]["Items"]), 2)

    def test_hub_storage_handshake_and_cancel_window_are_bounded_per_user(self):
        self.hub({"storagePhase": 7, "downloadDelayMs": 10000})
        mode = self.request("/qa/hub-state")[1]["mode"]
        self.assertEqual(mode["storagePhase"], 7)
        self.assertEqual(mode["downloadDelayMs"], 10000)
        self.assertEqual(self.request("/qa/hub-state", user="other-" + self.user)[1]["mode"].get("storagePhase", 0), 0)
        self.assertEqual(self.request("/qa/hub-control", {"storagePhase": 8})[0], 400)
        self.assertEqual(self.request("/qa/hub-control", {"downloadDelayMs": 15001})[0], 400)
        self.assertEqual(self.request("/qa/hub-control", {"audioDelayMs": 5001})[0], 400)
        self.assertEqual(self.request("/qa/hub-state")[1]["mode"]["storagePhase"], 7)
        self.hub({"reset": True})
        self.assertEqual(self.request("/qa/hub-state")[1]["mode"].get("storagePhase", 0), 0)

    def test_hub_browse_pagination_empty_search_and_one_shot_failure(self):
        self.hub({"trackCount": 5, "pageSize": 2, "failBrowse": 1})
        self.assertEqual(self.request("/Items?includeItemTypes=Audio")[0], 503)
        first = self.request("/Items?includeItemTypes=Audio")[1]
        self.assertEqual(first["TotalRecordCount"], 5)
        self.assertEqual(len(first["Items"]), 2)
        second = self.request("/Items?includeItemTypes=Audio&startIndex=2")[1]
        self.assertEqual([row["Id"] for row in second["Items"]], ["hub-track-3", "hub-track-4"])
        self.assertEqual(self.request("/Items?includeItemTypes=Audio&searchTerm=absent")[1]["Items"], [])

    def test_hub_audio_lyrics_and_photo_errors_are_per_user_and_recover(self):
        self.hub({"failAudio": 1, "failLyrics": 1, "failPhoto": 1})
        for route, body in [("/Items/hub-track-1/PlaybackInfo", {}), ("/Audio/hub-track-1/Lyrics", None), ("/Items/hub-photo-1/Images/Primary", None)]:
            self.assertEqual(self.request(route, body)[0], 503)
            self.assertEqual(self.request(route, body)[0], 200)
        self.hub({"lyricsEmpty": True})
        self.assertEqual(self.request("/Audio/hub-track-1/Lyrics")[1]["Lyrics"], [])
        self.hub({"lyricsEmpty": False})
        self.assertEqual(len(self.request("/Audio/hub-track-1/Lyrics")[1]["Lyrics"]), 2)

    def test_hub_download_failure_delay_and_extra_document_routes(self):
        self.hub({"failDownload": 1, "downloadDelayMs": 100, "extraBooks": True})
        start = time.monotonic()
        self.assertEqual(self.request("/Items/hub-book-1/Download")[0], 503)
        self.assertGreaterEqual(time.monotonic() - start, 0.09)
        self.hub({"downloadDelayMs": 0})
        self.assertEqual(self.request("/Items/hub-book-1/Download")[0], 200)
        books = self.request("/Items?includeItemTypes=Book")[1]["Items"]
        self.assertEqual({row["Container"] for row in books}, {"pdf", "txt", "mobi"})
        self.assertIn(b"Reel native text reader", self.request("/Items/hub-book-text/Download")[1])
        self.assertEqual(self.request("/Items/hub-book-mobi/Download")[0], 200)
        state = self.request("/qa/hub-state")[1]
        self.assertTrue(any(row["kind"] == "Download" for row in state["requests"]))

    def test_hub_download_forbidden_permission_can_recover_per_user(self):
        self.hub({"denyDownload": True})
        self.assertEqual(self.request("/Items/hub-book-1/Download")[0], 403)
        self.assertEqual(self.request("/Items/hub-book-1/Download", user="other-" + self.user)[0], 200)
        self.hub({"allowDownload": True})
        self.assertEqual(self.request("/Items/hub-book-1/Download")[0], 200)


if __name__ == "__main__":
    unittest.main()
