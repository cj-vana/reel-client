import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("ci_xcode", Path(__file__).with_name("ci-xcode.py"))
ci_xcode = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci_xcode)

LISTING = {
    "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [{"name": "iPhone 16", "udid": "A", "isAvailable": True}],
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            {"name": "iPad Pro", "udid": "B", "isAvailable": True},
            {"name": "iPhone 17", "udid": "C", "isAvailable": True},
            {"name": "iPhone 17 Pro", "udid": "D", "isAvailable": False},
        ],
        "com.apple.CoreSimulator.SimRuntime.tvOS-27-0": [{"name": "Apple TV 4K (3rd generation)", "udid": "E", "isAvailable": True}],
    }
}


def device_type(name, family):
    return {"identifier": "com.apple.CoreSimulator.SimDeviceType." + name.replace(" ", "-").replace("(", "").replace(")", ""),
            "name": name, "productFamily": family}


IPHONES = [device_type(name, "iPhone") for name in ("iPhone 16e", "iPhone 17 Pro Max", "iPhone 17 Pro", "iPhone Air")]
RUNTIMES = {"runtimes": [
    {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-4", "platform": "iOS", "version": "26.4", "name": "iOS 26.4", "isAvailable": True, "supportedDeviceTypes": IPHONES},
    {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1", "platform": "iOS", "version": "27.1", "name": "iOS 27.1", "isAvailable": True, "supportedDeviceTypes": IPHONES},
    {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-28-0", "platform": "iOS", "version": "28.0", "name": "iOS 28.0", "isAvailable": False, "supportedDeviceTypes": IPHONES},
    {"identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-27-0", "platform": "tvOS", "version": "27.0", "name": "tvOS 27.0", "isAvailable": True,
     "supportedDeviceTypes": [device_type("Apple TV 4K (3rd generation)", "Apple TV"), device_type("Apple TV 4K (3rd generation) (at 1080p)", "Apple TV")]},
]}
UDID = "8A1F3C2E-6B7D-4E59-9C0A-1D2E3F405162"


class Completed(subprocess.CompletedProcess):
    def __init__(self, args, returncode=0, stdout="", stderr=""):
        super().__init__(args, returncode, stdout, stderr)


class FakeSimctl:
    """A stand-in for `xcrun simctl` with an in-memory device list."""

    def __init__(self, devices=None):
        self.devices = devices if devices is not None else {"com.apple.CoreSimulator.SimRuntime.iOS-27-1": []}
        self.calls = []
        self.created = UDID

    def __call__(self, command, **kwargs):
        self.calls.append(command[2:])
        verb = command[2]
        if command[2:5] == ["list", "runtimes", "--json"]:
            return Completed(command, stdout=json.dumps(RUNTIMES))
        if verb == "list":
            return Completed(command, stdout=json.dumps({"devices": self.devices}))
        if verb == "create":
            self.devices.setdefault(command[5], []).append({"udid": self.created, "name": command[3], "state": "Shutdown", "isAvailable": True})
            return Completed(command, stdout=self.created + "\n")
        if verb in ("shutdown", "boot", "bootstatus"):
            return Completed(command)
        if verb == "delete":
            for devices in self.devices.values():
                devices[:] = [device for device in devices if device["udid"] != command[3]]
            return Completed(command)
        return Completed(command, 1, stderr="unexpected")


class PickSimulatorTests(unittest.TestCase):
    def test_newest_matching_runtime_and_available_device(self):
        self.assertEqual(ci_xcode.pick_simulator(LISTING, "iOS", "iPhone"), ("C", "iPhone 17"))

    def test_tvos_runtime_is_separate(self):
        self.assertEqual(ci_xcode.pick_simulator(LISTING, "tvOS", "Apple TV")[0], "E")

    def test_missing_device_exits(self):
        with self.assertRaises(SystemExit):
            ci_xcode.pick_simulator(LISTING, "tvOS", "iPhone")

    def test_runtime_version_ordering(self):
        self.assertGreater(ci_xcode.runtime_version("x.iOS-27-0"), ci_xcode.runtime_version("x.iOS-26-4"))


class RuntimeAndDeviceTests(unittest.TestCase):
    def test_newest_available_runtime_of_the_platform(self):
        self.assertEqual(ci_xcode.choose_runtime(RUNTIMES, "iOS")["version"], "27.1")
        self.assertEqual(ci_xcode.choose_runtime(RUNTIMES, "tvOS")["version"], "27.0")

    def test_requested_runtime_and_missing_ones(self):
        with self.assertRaisesRegex(ci_xcode.Failure, "needs 27.0 or later"):
            ci_xcode.choose_runtime(RUNTIMES, "iOS", "26.4")
        with self.assertRaisesRegex(ci_xcode.Failure, "not installed"):
            ci_xcode.choose_runtime(RUNTIMES, "iOS", "28.0")
        with self.assertRaisesRegex(ci_xcode.Failure, "No visionOS simulator runtime"):
            ci_xcode.choose_runtime(RUNTIMES, "visionOS")

    def test_iphone_prefers_listed_models_then_a_standard_size(self):
        runtime = ci_xcode.choose_runtime(RUNTIMES, "iOS")
        self.assertEqual(ci_xcode.choose_device_type(runtime, "iphone")[1], "iPhone 17 Pro")
        others = dict(runtime, supportedDeviceTypes=[item for item in IPHONES if item["name"] != "iPhone 17 Pro"])
        self.assertEqual(ci_xcode.choose_device_type(others, "iphone")[1], "iPhone Air")

    def test_apple_tv_prefers_the_1080p_model(self):
        runtime = ci_xcode.choose_runtime(RUNTIMES, "tvOS")
        self.assertEqual(ci_xcode.choose_device_type(runtime, "tv")[1], "Apple TV 4K (3rd generation) (at 1080p)")

    def test_ipad_family_and_explicit_device_type(self):
        runtime = {"identifier": "x.iOS-27-1", "supportedDeviceTypes": [device_type(name, "iPad") for name in ("iPad Pro 13-inch (M5)", "iPad Air 11-inch (M4)", "iPad mini (A17 Pro)")] + IPHONES}
        self.assertEqual(ci_xcode.choose_device_type(runtime, "ipad")[1], "iPad Air 11-inch (M4)")
        self.assertEqual(ci_xcode.choose_device_type(runtime, "ipad", "iPad Pro 13-inch (M5)")[1], "iPad Pro 13-inch (M5)")
        with self.assertRaisesRegex(ci_xcode.Failure, "not supported"):
            ci_xcode.choose_device_type(runtime, "ipad", "iPad 2")

    def test_older_simctl_without_device_types_uses_an_installed_model_name(self):
        runtime = {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "platform": "iOS"}
        self.assertEqual(ci_xcode.choose_device_type(runtime, "iphone", listing=LISTING), ("iPhone 17", "iPhone 17"))

    def test_names_match_the_test_ownership_checks(self):
        self.assertEqual(ci_xcode.simulator_name("tvos"), "Reel QA Apple TV")
        name = ci_xcode.simulator_name("ios")
        self.assertRegex(name, r"^Reel QA Improvements Player [0-9a-f]{8}$")
        self.assertNotEqual(name, ci_xcode.simulator_name("ios"))


class SimulatorLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.state = ci_xcode.State(Path(self.folder.name) / "state.json")
        self.output = mock.patch.object(ci_xcode, "say")
        self.output.start()

    def tearDown(self):
        self.output.stop()
        self.folder.cleanup()

    def test_create_records_the_new_udid_before_using_it(self):
        simctl = FakeSimctl()
        udid, name = ci_xcode.create_simulator("tvos", "tv", self.state, runner=simctl)
        self.assertEqual((udid, name), (UDID, "Reel QA Apple TV"))
        create = next(call for call in simctl.calls if call[0] == "create")
        self.assertEqual(create, ["create", "Reel QA Apple TV", "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-at-1080p",
                                  "com.apple.CoreSimulator.SimRuntime.tvOS-27-0"])
        self.assertEqual(json.loads((Path(self.folder.name) / "state.json").read_text())["simulators"], [{"udid": UDID, "name": "Reel QA Apple TV"}])

    def test_create_refuses_an_existing_simulator(self):
        simctl = FakeSimctl({"x.tvOS-27-0": [{"udid": UDID, "name": "Reel QA Apple TV", "state": "Booted"}]})
        with self.assertRaisesRegex(ci_xcode.Failure, "existing simulator"):
            ci_xcode.create_simulator("tvos", "tv", self.state, runner=simctl)
        self.assertNotIn(["delete", UDID], simctl.calls)

    def test_create_rejects_output_that_is_not_an_identifier(self):
        simctl = FakeSimctl()
        simctl.created = "Invalid device type"
        with self.assertRaisesRegex(ci_xcode.Failure, "did not return a simulator identifier"):
            ci_xcode.create_simulator("ios", "iphone", self.state, runner=simctl)

    def test_delete_touches_only_the_recorded_simulator(self):
        other = {"udid": "11111111-2222-3333-4444-555555555555", "name": "Reel QA Apple TV", "state": "Booted"}
        simctl = FakeSimctl({"x.tvOS-27-0": [dict(other), {"udid": UDID, "name": "Reel QA Apple TV", "state": "Booted"}]})
        self.state.record("simulator", {"udid": UDID, "name": "Reel QA Apple TV"})
        ci_xcode.delete_simulator(UDID, "Reel QA Apple TV", state=self.state, runner=simctl)
        self.assertEqual([call for call in simctl.calls if call[0] != "list"], [["shutdown", UDID], ["delete", UDID]])
        self.assertEqual(simctl.devices["x.tvOS-27-0"], [other])
        self.assertEqual(self.state.data["simulators"], [])

    def test_delete_leaves_a_renamed_simulator_alone(self):
        simctl = FakeSimctl({"x.iOS-27-1": [{"udid": UDID, "name": "My iPhone", "state": "Shutdown"}]})
        with self.assertRaisesRegex(ci_xcode.Failure, "leaving it alone"):
            ci_xcode.delete_simulator(UDID, "Reel QA Improvements Player 0a1b2c3d", runner=simctl)
        self.assertEqual([call for call in simctl.calls if call[0] != "list"], [])

    def test_shut_down_simulator_is_deleted_without_shutdown(self):
        simctl = FakeSimctl({"x.iOS-27-1": [{"udid": UDID, "name": "Reel QA Improvements Player 0a1b2c3d", "state": "Shutdown"}]})
        ci_xcode.delete_simulator(UDID, "Reel QA Improvements Player 0a1b2c3d", runner=simctl)
        self.assertEqual([call for call in simctl.calls if call[0] != "list"], [["delete", UDID]])

    def test_state_round_trip(self):
        self.state.record("process", {"pid": 41, "script": "apps/tvos/qa/run-fixture.py", "name": "tv-main"})
        self.state.record("process", {"pid": 42, "script": "apps/tvos/qa/run-fixture.py", "name": "tv-second"})
        self.state.record("process-stopped", {"pid": 41})
        self.assertEqual([item["pid"] for item in ci_xcode.State(self.state.path).data["processes"]], [42])


class CommandTests(unittest.TestCase):
    def group(self, **values):
        return ci_xcode.fixtures.Group(**values)

    def test_build_for_testing_signs_ad_hoc_for_the_owned_simulator(self):
        command = ci_xcode.build_for_testing_command(ci_xcode.TARGETS["ios"], UDID, Path("/dd"))
        self.assertEqual(command[:2], ["xcodebuild", "build-for-testing"])
        self.assertIn("platform=iOS Simulator,id=" + UDID, command)
        self.assertEqual(command[-4:], ["CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM="])
        self.assertNotIn("CODE_SIGNING_ALLOWED=NO", command)

    def test_test_command_selects_and_skips_and_never_collects_diagnostics(self):
        group = self.group(only=["ReelTVUITests/TVLibraryJourneys"], skip=["ReelTVUITests/TVLibraryJourneys/testSeed"])
        command = ci_xcode.test_command(ci_xcode.TARGETS["tvos"], UDID, Path("/dd"), Path("/out/r.xcresult"), group, "ui")
        self.assertEqual(command[:2], ["xcodebuild", "test-without-building"])
        pairs = dict(zip(command, command[1:]))
        self.assertEqual(pairs["-destination"], "platform=tvOS Simulator,id=" + UDID)
        self.assertEqual(pairs["-collect-test-diagnostics"], "never")
        self.assertEqual(pairs["-parallel-testing-enabled"], "NO")
        self.assertEqual(pairs["-resultBundlePath"], "/out/r.xcresult")
        self.assertEqual(pairs["-default-test-execution-time-allowance"], "1200")
        self.assertIn("-only-testing:ReelTVUITests/TVLibraryJourneys", command)
        self.assertIn("-skip-testing:ReelTVUITests/TVLibraryJourneys/testSeed", command)
        self.assertFalse([item for item in command if item.startswith("CODE_SIGN")])

    def test_runner_environment_replaces_inherited_test_values(self):
        with mock.patch.dict(os.environ, {"TEST_RUNNER_REEL_LIVE_PREVIEW_TESTS": "1", "TEST_RUNNER_OTHER": "kept", "HOME": "/h"}):
            env = ci_xcode.xcodebuild_env({"TEST_RUNNER_REEL_TV_QA_OWNER": "q"})
        self.assertNotIn("TEST_RUNNER_REEL_LIVE_PREVIEW_TESTS", env)
        self.assertEqual((env["TEST_RUNNER_REEL_TV_QA_OWNER"], env["TEST_RUNNER_OTHER"], env["NSUnbufferedIO"]), ("q", "kept", "YES"))

    def test_build_errors_are_extracted_in_order(self):
        log = "\n".join([
            "CompileSwift normal arm64 Home.swift",
            "/r/apps/tvos/ReelTV/TVHomeView.swift:12:5: error: cannot find 'spotlight' in scope",
            "/r/apps/tvos/ReelTV/TVHomeView.swift:12:5: error: cannot find 'spotlight' in scope",
            "warning: unused variable",
            "** TEST BUILD FAILED **",
            "",
            "The following build commands failed:",
            "\tCompileSwift normal arm64 /r/apps/tvos/ReelTV/TVHomeView.swift",
            "(1 failure)",
            "",
        ])
        self.assertEqual(ci_xcode.build_errors(log), [
            "/r/apps/tvos/ReelTV/TVHomeView.swift:12:5: error: cannot find 'spotlight' in scope",
            "** TEST BUILD FAILED **",
            "The following build commands failed:",
            "CompileSwift normal arm64 /r/apps/tvos/ReelTV/TVHomeView.swift",
            "(1 failure)",
        ])

    def test_contributor_build_stays_unsigned_and_generic(self):
        with mock.patch.object(ci_xcode.subprocess, "call", return_value=0) as call, mock.patch.dict(os.environ, {"RUNNER_TEMP": "/rt"}):
            self.assertEqual(ci_xcode.main(["tvos", "build"]), 0)
        command = call.call_args.args[0]
        self.assertEqual(command[:2], ["xcodebuild", "build"])
        self.assertIn("generic/platform=tvOS Simulator", command)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", command)
        self.assertEqual(dict(zip(command, command[1:]))["-derivedDataPath"], "/rt/DerivedData")
        self.assertEqual(call.call_args.kwargs["cwd"], ci_xcode.ROOT / "apps/tvos")

    def test_parser_works_without_a_module_docstring(self):
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(ci_xcode, "__doc__", None), mock.patch.object(ci_xcode, "say"):
            self.assertEqual(ci_xcode.main(["ios", "cleanup", "--output-dir", folder]), 0)

    def test_output_directory_must_be_new_and_outside_the_repository(self):
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / "old.txt").write_text("x")
            with self.assertRaisesRegex(ci_xcode.Failure, "not empty"):
                ci_xcode.output_directory(folder, "ios", "test")
            fresh = ci_xcode.output_directory(str(Path(folder) / "run"), "ios", "test")
            self.assertEqual(sorted(path.name for path in fresh.iterdir()), ["logs", "media", "results"])
        with self.assertRaisesRegex(ci_xcode.Failure, "outside the repository"):
            ci_xcode.output_directory(str(ci_xcode.ROOT / "build" / "reel-ci-output-test"), "ios", "test")
        self.assertFalse((ci_xcode.ROOT / "build" / "reel-ci-output-test").exists())


class TourWatcherTests(unittest.TestCase):
    def test_request_is_answered_with_a_complete_screenshot(self):
        calls = []

        def runner(command, **kwargs):
            calls.append(command)
            Path(command[-1]).write_bytes(b"\x89PNG")
            return Completed(command)

        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / "home.request").write_text("home")
            watcher = ci_xcode.TourWatcher(folder, UDID, runner=runner)
            watcher.poll()
            self.assertEqual(sorted(path.name for path in Path(folder).iterdir()), ["home.png"])
        self.assertEqual(calls[0][:6], ["xcrun", "simctl", "io", UDID, "screenshot", "--type=png"])
        self.assertTrue(Path(calls[0][-1]).name.startswith(".partial-"))
        self.assertEqual(watcher.captured, ["home"])

    def test_failed_capture_is_reported_and_retried(self):
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / "detail.request").write_text("detail")
            watcher = ci_xcode.TourWatcher(folder, UDID, runner=lambda command, **kwargs: Completed(command, 1, stderr="No devices are booted."))
            watcher.poll()
            self.assertTrue((Path(folder) / "detail.request").exists())
        self.assertEqual(watcher.errors, ["detail: No devices are booted."])


class CleanupTests(unittest.TestCase):
    def test_cleanup_stops_only_matching_processes_and_recorded_simulators(self):
        with tempfile.TemporaryDirectory() as folder:
            state = ci_xcode.State(Path(folder) / "state.json")
            state.record("process", {"pid": 4101, "script": "apps/tvos/qa/run-fixture.py", "name": "tv-main"})
            state.record("process", {"pid": 4102, "script": "apps/tvos/qa/run-episode-fixture.py", "name": "tv-episodes"})
            state.record("simulator", {"udid": UDID, "name": "Reel QA Apple TV"})
            simctl = FakeSimctl({"x.tvOS-27-0": [{"udid": UDID, "name": "Reel QA Apple TV", "state": "Booted"}]})

            def runner(command, **kwargs):
                if command[0] == "ps":
                    # 4102 now belongs to an unrelated program.
                    text = {"4101": "python3 /r/apps/tvos/qa/run-fixture.py --port 18966", "4102": "/usr/bin/vim notes"}[command[-1]]
                    return Completed(command, stdout=text)
                return simctl(command, **kwargs)

            with mock.patch.object(ci_xcode.os, "killpg") as killpg, mock.patch.object(ci_xcode, "say"):
                self.assertEqual(ci_xcode.cleanup(mock.Mock(output_dir=folder), runner=runner), 0)
            killpg.assert_called_once_with(4101, ci_xcode.signal.SIGTERM)
            self.assertIn(["delete", UDID], simctl.calls)
            self.assertEqual(ci_xcode.State(state.path).data, {"simulators": [], "processes": []})


class SessionTests(unittest.TestCase):
    """The whole run with simctl, xcodebuild and the fixtures replaced."""

    def test_groups_run_in_order_and_everything_is_released(self):
        events = []

        class FakeFixtures:
            def __init__(self, paths, owners, logs, record=None, say=None):
                self.record = record

            def start(self, names):
                events.append(("start", tuple(names)))
                self.record("process", {"pid": 1, "script": "x", "name": names[0]})

            def check_alive(self):
                pass

            def stop(self):
                events.append(("stop",))
                self.record("process-stopped", {"pid": 1})
                return []

        def run(runner, command, *, cwd, env, log_path, title):
            events.append((command[1], [item for item in command if item.startswith("-only-testing")],
                           {key: value for key, value in env.items() if key.startswith("TEST_RUNNER_")}))
            if command[1] == "test-without-building":
                Path(command[command.index("-resultBundlePath") + 1]).mkdir()
            return 0

        report = ci_xcode.xcresult.Report([ci_xcode.xcresult.Case("ReelTVUITests/TVJourneys/testRemoteSignInHomeDetailsAndBack", "Passed"),
                                           ci_xcode.xcresult.Case("ReelTVUITests/TVEpisodePlayerJourneys/testRemoteEOFCancelPlayNowAndAutomaticNext", "Passed")])
        with tempfile.TemporaryDirectory() as folder:
            args = mock.Mock(only_testing=["TVJourneys/testRemoteSignInHomeDetailsAndBack, TVEpisodePlayerJourneys/testRemoteEOFCancelPlayNowAndAutomaticNext"],
                             output_dir=str(Path(folder) / "out"), derived_data=None, runtime="", device_type="", device=None)
            with mock.patch.object(ci_xcode, "create_simulator", return_value=(UDID, "Reel QA Apple TV")), \
                    mock.patch.object(ci_xcode, "simctl") as simctl, \
                    mock.patch.object(ci_xcode, "delete_simulator") as delete, \
                    mock.patch.object(ci_xcode.shutil, "which", return_value="/usr/bin/xcrun"), \
                    mock.patch.object(ci_xcode.fixtures, "busy_ports", return_value=[]), \
                    mock.patch.object(ci_xcode.fixtures, "prepare_media", return_value={}) as media, \
                    mock.patch.object(ci_xcode.fixtures, "Fixtures", FakeFixtures), \
                    mock.patch.object(ci_xcode.Runner, "run", run), \
                    mock.patch.object(ci_xcode.xcresult, "read", return_value=report), \
                    mock.patch.object(ci_xcode, "say"):
                code = ci_xcode.run_tests("tvos", "ui", args)
        self.assertEqual(code, 0)
        self.assertEqual(media.call_args.args[0], ["tracks", "multiaudio", "silent"])
        self.assertEqual([event[0] for event in events], ["build-for-testing", "start", "test-without-building", "stop", "start", "test-without-building", "stop"])
        self.assertEqual(events[1][1], ("tv-main", "tv-second", "tv-subtitles", "multiaudio"))
        self.assertEqual(events[4][1], ("tv-episodes",))
        first, second = events[2], events[5]
        self.assertEqual(first[1], ["-only-testing:ReelTVUITests/TVJourneys/testRemoteSignInHomeDetailsAndBack"])
        self.assertEqual(first[2]["TEST_RUNNER_REEL_TV_QA_DEVICE_UDID"], UDID)
        self.assertEqual(first[2]["TEST_RUNNER_REEL_LIVE_PREVIEW_TESTS"], "0")
        self.assertEqual(len(first[2]["TEST_RUNNER_REEL_TV_QA_OWNER"]), 48)
        self.assertNotIn("TEST_RUNNER_REEL_TV_EPISODE_JOURNEYS", first[2])
        self.assertEqual(second[2]["TEST_RUNNER_REEL_TV_EPISODE_JOURNEYS"], "1")
        self.assertEqual(second[2]["TEST_RUNNER_REEL_TV_QA_OWNER"], first[2]["TEST_RUNNER_REEL_TV_QA_OWNER"])
        delete.assert_called_once()
        self.assertEqual(delete.call_args.args[:2], (UDID, "Reel QA Apple TV"))
        simctl.assert_any_call("bootstatus", UDID, "-b")

    def test_failed_group_does_not_stop_later_groups_and_fails_the_run(self):
        reports = [ci_xcode.xcresult.Report([ci_xcode.xcresult.Case("ReelTVUITests/TVJourneys/testRemoteSignInHomeDetailsAndBack", "Failed",
                                                                    [ci_xcode.xcresult.Failure("Remote focus could not reach gearshape", "TVJourneys.swift", 2185)])]),
                   ci_xcode.xcresult.Report([ci_xcode.xcresult.Case("ReelTVUITests/TVEpisodePlayerJourneys/testRemoteEOFCancelPlayNowAndAutomaticNext", "Passed")])]
        ran = []

        def run(runner, command, *, cwd, env, log_path, title):
            ran.append(command[1])
            if command[1] == "test-without-building":
                Path(command[command.index("-resultBundlePath") + 1]).mkdir()
                return 65 if len(ran) == 2 else 0
            return 0

        fake = mock.MagicMock()
        fake.return_value.stop.return_value = []
        printed = io.StringIO()
        with tempfile.TemporaryDirectory() as folder:
            args = mock.Mock(only_testing=["TVJourneys/testRemoteSignInHomeDetailsAndBack TVEpisodePlayerJourneys/testRemoteEOFCancelPlayNowAndAutomaticNext"],
                             output_dir=str(Path(folder) / "out"), derived_data=None, runtime="", device_type="", device=None)
            with mock.patch.object(ci_xcode, "create_simulator", return_value=(UDID, "Reel QA Apple TV")), \
                    mock.patch.object(ci_xcode, "simctl"), mock.patch.object(ci_xcode, "delete_simulator") as delete, \
                    mock.patch.object(ci_xcode.shutil, "which", return_value="/usr/bin/xcrun"), \
                    mock.patch.object(ci_xcode.fixtures, "busy_ports", return_value=[]), \
                    mock.patch.object(ci_xcode.fixtures, "prepare_media", return_value={}), \
                    mock.patch.object(ci_xcode.fixtures, "Fixtures", fake), \
                    mock.patch.object(ci_xcode.Runner, "run", run), \
                    mock.patch.object(ci_xcode.xcresult, "read", side_effect=reports), \
                    mock.patch.object(ci_xcode.xcresult, "export_attachments", return_value=([], [])), \
                    mock.patch.object(sys, "stdout", printed):
                code = ci_xcode.run_tests("tvos", "ui", args)
        self.assertEqual(code, 1)
        self.assertEqual(ran, ["build-for-testing", "test-without-building", "test-without-building"])
        text = printed.getvalue()
        self.assertIn("FAILED ReelTVUITests/TVJourneys/testRemoteSignInHomeDetailsAndBack", text)
        self.assertIn("TVJourneys.swift:2185: Remote focus could not reach gearshape", text)
        self.assertIn("Group 2 (ReelTVUITests/TVEpisodePlayerJourneys): passed", text)
        delete.assert_called_once()

    def test_selection_errors_stop_before_any_simulator_exists(self):
        with mock.patch.object(ci_xcode, "create_simulator") as create, mock.patch.object(ci_xcode, "say") as say:
            code = ci_xcode.run_tests("ios", "ui", mock.Mock(only_testing=["ReelUITests/BrowseIntegrityUITests"], device=None))
        self.assertEqual(code, 1)
        create.assert_not_called()
        self.assertIn("browse_integrity_server.py", say.call_args_list[0].args[0])


if __name__ == "__main__":
    unittest.main()
