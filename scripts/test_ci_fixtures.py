from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location("ci_fixtures", Path(__file__).with_name("ci-fixtures.py"))
ci_fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci_fixtures)

TESTS = {
    "ReelTests": {"RemoteSessionsTests": ["testRemoteCommand"], "AudioSelectionTests": ["testDefault"]},
    "ReelUITests": {"ReelUITests": ["testDetailsFavoritesSearchAndSeries"], "HomeCompactUITests": ["testCompactHome"],
                    "ScreenTourUITests": ["testCaptureKeyScreens"], "BrowseIntegrityUITests": ["testRoot"],
                    "NewJourneyUITests": ["testNew"]},
    "ReelTVTests": {"TVCoreTests": ["testCore"], "AudioSelectionTests": ["testDefault"]},
    "ReelTVUITests": {"TVJourneys": ["testRemoteSignInHomeDetailsAndBack", "testRemoteSettingsAccountsPrivacyQualityAndRemovalPersist"],
                      "TVEpisodePlayerJourneys": ["testRemoteEOFCancelPlayNowAndAutomaticNext"],
                      "TVLibraryJourneys": ["testRefreshFailureKeepsRowsAndSuccessReplacesEmptyThenRecovers"] + list(ci_fixtures.TV_STORAGE_PHASE_TESTS),
                      "TVWatchedJourneys": ["testEpisodeOnlyHeroUsesPlayAndRetainsIndividualEpisodeIdentity"]},
}


def ids(selected):
    return [item.identifier for item in selected]


class CatalogTests(unittest.TestCase):
    def test_reads_classes_and_methods_per_file(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "apps/apple/ReelUITests").mkdir(parents=True)
            (root / "apps/apple/ReelUITests/Two.swift").write_text(
                "@MainActor final class FirstUITests: XCTestCase {\n func testA() {}\n func helper() {}\n}\n"
                "final class SecondUITests: XCTestCase {\n func testB() async throws {}\n}\n")
            tests = ci_fixtures.catalog(root)
        self.assertEqual(tests["ReelUITests"], {"FirstUITests": ["testA"], "SecondUITests": ["testB"]})
        self.assertEqual(tests["ReelTests"], {})


class ResolveTests(unittest.TestCase):
    def test_defaults(self):
        self.assertEqual(ids(ci_fixtures.resolve("ios", "test", [], tests=TESTS)[0]), ["ReelTests"])
        self.assertEqual(ids(ci_fixtures.resolve("tvos", "test", [""], tests=TESTS)[0]), ["ReelTVTests"])

    def test_separators_bundle_inference_and_call_suffix(self):
        selected, _ = ci_fixtures.resolve("tvos", "ui", ["TVJourneys/testRemoteSignInHomeDetailsAndBack(),\n ReelTVUITests/TVEpisodePlayerJourneys"], tests=TESTS)
        self.assertEqual(ids(selected), ["ReelTVUITests/TVJourneys/testRemoteSignInHomeDetailsAndBack", "ReelTVUITests/TVEpisodePlayerJourneys"])
        self.assertEqual((selected[0].bundle, selected[0].test_class, selected[0].method), ("ReelTVUITests", "TVJourneys", "testRemoteSignInHomeDetailsAndBack"))

    def test_other_platform_is_left_out_with_a_note(self):
        selected, notes = ci_fixtures.resolve("ios", "ui", ["ReelTVUITests/TVJourneys, ReelUITests/HomeCompactUITests"], tests=TESTS)
        self.assertEqual(ids(selected), ["ReelUITests/HomeCompactUITests"])
        self.assertEqual(notes, ["Leaving out ReelTVUITests/TVJourneys: it belongs to the other platform."])

    def test_only_other_platform_is_an_error(self):
        with self.assertRaisesRegex(ci_fixtures.SelectionError, "None of the selected tests belong to iOS"):
            ci_fixtures.resolve("ios", "ui", ["TVJourneys"], tests=TESTS)

    def test_shared_class_name_resolves_to_this_platform(self):
        self.assertEqual(ids(ci_fixtures.resolve("tvos", "test", ["AudioSelectionTests"], tests=TESTS)[0]), ["ReelTVTests/AudioSelectionTests"])

    def test_unknown_names_are_rejected_before_running(self):
        for raw, message in [("TVJourneys/testMissing", "No test testMissing"), ("ReelTVUITests/Nope", "No test class Nope"),
                             ("Nope", "Unknown test bundle or class"), ("TVJourneys; rm -rf", "Not a test identifier"),
                             ("ReelTVTests/TVCoreTests", "run by the test action")]:
            with self.subTest(raw=raw), self.assertRaisesRegex(ci_fixtures.SelectionError, message):
                ci_fixtures.resolve("tvos", "ui", [raw], tests=TESTS)

    def test_duplicates_are_dropped(self):
        self.assertEqual(ids(ci_fixtures.resolve("tvos", "ui", ["TVJourneys TVJourneys"], tests=TESTS)[0]), ["ReelTVUITests/TVJourneys"])


class PlanTests(unittest.TestCase):
    def plan(self, platform, raw):
        return ci_fixtures.plan(ci_fixtures.resolve(platform, "ui", [raw], tests=TESTS)[0], TESTS)

    def test_port_clash_splits_tv_journeys_from_episode_journeys(self):
        groups = self.plan("tvos", "TVJourneys/testRemoteSettingsAccountsPrivacyQualityAndRemovalPersist TVEpisodePlayerJourneys TVWatchedJourneys")
        self.assertEqual([group.keys for group in groups], [["ReelTVUITests/TVJourneys", "ReelTVUITests/TVWatchedJourneys"], ["ReelTVUITests/TVEpisodePlayerJourneys"]])
        self.assertEqual(groups[0].ports()[18967], "tv-second")
        self.assertEqual(groups[1].ports()[18967], "tv-episodes")
        for group in groups:
            ports = [ci_fixtures.SERVICES[name].port for name in group.services]
            self.assertEqual(len(ports), len(set(ports)))
        self.assertEqual(groups[0].named, ["ReelTVUITests/TVJourneys/testRemoteSettingsAccountsPrivacyQualityAndRemovalPersist"])
        self.assertEqual(groups[0].env["REEL_TV_PARITY_MUTABLE"], "1")
        self.assertEqual(groups[1].env["REEL_TV_EPISODE_JOURNEYS"], "1")
        self.assertNotIn("REEL_TV_EPISODE_JOURNEYS", groups[0].env)

    def test_library_class_skips_storage_phase_tests(self):
        group, = self.plan("tvos", "TVLibraryJourneys")
        self.assertEqual(group.services, ["tv-library", "tv-library-second"])
        self.assertEqual(group.skip, ["ReelTVUITests/TVLibraryJourneys/" + name for name in ci_fixtures.TV_STORAGE_PHASE_TESTS])

    def test_naming_a_storage_phase_test_is_refused(self):
        with self.assertRaisesRegex(ci_fixtures.SelectionError, "staged storage phase"):
            self.plan("tvos", "TVLibraryJourneys/" + ci_fixtures.TV_STORAGE_PHASE_TESTS[0])

    def test_unsupported_and_unmapped_classes_are_refused(self):
        with self.assertRaisesRegex(ci_fixtures.SelectionError, "browse_integrity_server.py"):
            self.plan("ios", "BrowseIntegrityUITests")
        with self.assertRaisesRegex(ci_fixtures.SelectionError, "no fixture mapping"):
            self.plan("ios", "NewJourneyUITests")
        with self.assertRaisesRegex(ci_fixtures.SelectionError, "not the whole bundle"):
            self.plan("ios", "ReelUITests")

    def test_screen_tour_turns_on_the_capture_helper(self):
        group, = self.plan("ios", "ReelUITests/testDetailsFavoritesSearchAndSeries ScreenTourUITests")
        self.assertTrue(group.tour)
        self.assertEqual(group.services, list(ci_fixtures.IOS_FIXTURES))

    def test_unit_profiles_and_runner_environment(self):
        ios, = ci_fixtures.plan(ci_fixtures.resolve("ios", "test", [], tests=TESTS)[0], TESTS)
        self.assertEqual(ios.services, list(ci_fixtures.IOS_FIXTURES) + ["player-main", "multiaudio"])
        self.assertEqual(ci_fixtures.test_runner_env(ios, {"qa_owner": "q" * 48, "parity_owner": "p" * 48, "udid": "UDID-1"}),
                         {"TEST_RUNNER_REEL_TV_QA_OWNER": "q" * 48, "TEST_RUNNER_REEL_PLAYER_QA_DEVICE_UDID": "UDID-1"})
        tv, = ci_fixtures.plan(ci_fixtures.resolve("tvos", "test", [], tests=TESTS)[0], TESTS)
        self.assertEqual(sorted(tv.services), ["multiaudio", "tv-episodes", "tv-library", "tv-main", "tv-subtitles"])
        self.assertEqual(ci_fixtures.test_runner_env(tv, {"qa_owner": "q", "parity_owner": "p", "udid": "U"}), {
            "TEST_RUNNER_REEL_TV_QA_OWNER": "q", "TEST_RUNNER_REEL_TV_QA_DEVICE_UDID": "U",
            "TEST_RUNNER_REEL_TV_PARITY_OWNER": "p", "TEST_RUNNER_REEL_TV_PARITY_DEVICE_UDID": "U",
            "TEST_RUNNER_REEL_TV_EPISODE_JOURNEYS": "1"})
        self.assertEqual(tv.media(), ["tracks", "multiaudio", "silent", "library_manifest"])


class SourceContractTests(unittest.TestCase):
    """The mapping must follow the real test sources."""

    @classmethod
    def setUpClass(cls):
        cls.tests = ci_fixtures.catalog()

    def test_defaults_name_real_tests(self):
        for (platform, device), items in ci_fixtures.DEFAULT_UI.items():
            with self.subTest(platform=platform, device=device):
                selected, _ = ci_fixtures.resolve(platform, "ui", [], device=device, tests=self.tests)
                self.assertEqual(ids(selected), list(items))
                ci_fixtures.plan(selected, self.tests)

    def test_every_ui_class_is_mapped_or_explained(self):
        for bundle in ("ReelUITests", "ReelTVUITests"):
            for test_class in self.tests[bundle]:
                key = bundle + "/" + test_class
                with self.subTest(key=key):
                    self.assertTrue(key in ci_fixtures.PROFILES or key in ci_fixtures.UNSUPPORTED,
                                    key + " needs a fixture profile or a reason in scripts/ci-fixtures.py")
        for key in list(ci_fixtures.PROFILES) + list(ci_fixtures.UNSUPPORTED):
            bundle, _, test_class = key.partition("/")
            with self.subTest(key=key):
                self.assertIn(test_class or bundle, self.tests[bundle] if test_class else self.tests)

    def test_storage_phase_list_matches_the_tests_that_need_it(self):
        text = (ci_fixtures.ROOT / "apps/tvos/ReelTVUITests/TVLibraryJourneys.swift").read_text()
        needs = set()
        for match in re.finditer(r"func (test\w+)\(\)[^{]*\{(.*?)\n    \}", text, re.S):
            if "storageUser(" in match.group(2):
                needs.add(match.group(1))
        self.assertEqual(needs, set(ci_fixtures.TV_STORAGE_PHASE_TESTS))

    def test_fixture_scripts_exist_and_accept_their_ports(self):
        for service in ci_fixtures.SERVICES.values():
            with self.subTest(service=service.name):
                script = ci_fixtures.ROOT / service.script
                self.assertTrue(script.is_file())
                self.assertIn(str(service.port), script.read_text() + " ".join(service.args))


class MediaTests(unittest.TestCase):
    def test_library_manifest_root_is_the_resolved_media_path(self):
        with tempfile.TemporaryDirectory() as folder:
            real = Path(folder) / "real"
            media = real / "reel-tvos-fixture-tracks"
            (media / "hls").mkdir(parents=True)
            (media / "sample.mp4").write_bytes(b"video")
            (media / "hls/index.m3u8").write_text("#EXTM3U\n")
            (Path(folder) / "link").symlink_to(real)
            manifest = Path(folder) / "library-media.json"
            ci_fixtures.write_library_manifest(Path(folder) / "link/reel-tvos-fixture-tracks", manifest)
            record = json.loads(manifest.read_text())
            self.assertEqual(record["root"], str(media.resolve()))
            self.assertEqual(sorted(record["files"]), ["hls/index.m3u8", "sample.mp4"])
            self.assertEqual(len(record["files"]["sample.mp4"]), 64)

    def test_library_manifest_needs_the_sample_and_playlist(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(ci_fixtures.FixtureError, "sample.mp4"):
                ci_fixtures.write_library_manifest(folder, Path(folder) / "m.json")

    def test_media_is_prepared_in_dependency_order(self):
        calls = []

        def runner(command, **kwargs):
            calls.append([Path(command[1]).name] + command[2:])
            return subprocess.CompletedProcess(command, 0)

        with tempfile.TemporaryDirectory() as folder:
            paths = ci_fixtures.media_paths(folder)
            original = ci_fixtures.write_library_manifest
            ci_fixtures.write_library_manifest = lambda media, manifest: calls.append(["manifest", str(media), str(manifest)])
            try:
                ci_fixtures.prepare_media(["library_manifest", "multiaudio", "silent"], folder, folder, runner=runner, say=lambda text: None)
            finally:
                ci_fixtures.write_library_manifest = original
        self.assertEqual(calls, [
            ["prepare-track-fixtures.py", "--output", str(paths["tracks"])],
            ["verify-track-media.py", "--media", str(paths["tracks"])],
            ["prepare-fixtures.py", "--silent", "--output", str(paths["silent"])],
            ["prepare-multiaudio-fixtures.py", "--output", str(paths["multiaudio_source"])],
            ["verify-multiaudio-media.py", "--media", str(paths["multiaudio_source"])],
            ["prepare-multiaudio-local.py", "--input", str(paths["multiaudio_source"]), "--output", str(paths["multiaudio"])],
            ["manifest", str(paths["tracks"]), str(paths["library_manifest"])],
        ])
        for key in ("tracks", "silent", "multiaudio_source", "multiaudio"):
            self.assertTrue(paths[key].name.startswith("reel-tvos-fixture-"))
        self.assertNotEqual(paths["multiaudio_source"], paths["multiaudio"])

    def test_failed_media_step_reports_its_output(self):
        def runner(command, **kwargs):
            kwargs["stdout"].write(b"ffprobe is required\n")
            kwargs["stdout"].flush()
            return subprocess.CompletedProcess(command, 1)

        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(ci_fixtures.FixtureError, "(?s)silent media failed.*ffprobe is required"):
                ci_fixtures.prepare_media(["silent"], folder, folder, runner=runner, say=lambda text: None)


class IdentityHandler(BaseHTTPRequestHandler):
    reply = {}

    def do_GET(self):
        data = json.dumps(self.reply).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class ProcessTests(unittest.TestCase):
    def test_owned_fixture_must_answer_with_this_runs_owner(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), IdentityHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            port = server.server_address[1]
            service = ci_fixtures.Service("probe", port, "x.py", owner=ci_fixtures.QA_OWNER)
            fixtures = ci_fixtures.Fixtures({}, {ci_fixtures.QA_OWNER: "a" * 48}, ".")
            IdentityHandler.reply = {"kind": "reel-tv-owned-fixture", "owner": "a" * 48, "port": port}
            self.assertTrue(fixtures.answers(service))
            IdentityHandler.reply = {"kind": "reel-tv-owned-fixture", "owner": "b" * 48, "port": port}
            self.assertFalse(fixtures.answers(service))
            IdentityHandler.reply = {"kind": "reel-tv-library-parity", "owner": "a" * 48, "port": port}
            self.assertFalse(fixtures.answers(service))
        finally:
            server.shutdown()
            server.server_close()

    def test_busy_ports_lists_tcp_and_udp(self):
        free = {18766: False, 17359: True, 18767: True}
        busy = ci_fixtures.busy_ports(["ios-primary", "ios-secondary"], check=lambda port, kind=socket.SOCK_STREAM: free[port])
        self.assertEqual(busy, ["18766 (TCP, ios-primary)"])

    def test_port_free_sees_a_listener(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            self.assertFalse(ci_fixtures.port_free(listener.getsockname()[1]))

    def test_stop_process_ends_the_child_session(self):
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
        ci_fixtures.stop_process(process, timeout=5)
        self.assertIsNotNone(process.poll())
        with self.assertRaises(ProcessLookupError):
            os.killpg(process.pid, 0)

    def test_owner_tokens_are_fresh_and_accepted_by_the_fixtures(self):
        first, second = ci_fixtures.new_owners(), ci_fixtures.new_owners()
        self.assertNotEqual(first, second)
        for value in first.values():
            self.assertRegex(value, r"^[A-Za-z0-9_-]{24,120}$")


if __name__ == "__main__":
    unittest.main()
