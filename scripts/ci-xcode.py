#!/usr/bin/env python3
"""Build, unit-test or UI-test the iOS or tvOS app on a new, disposable simulator.

Usage:
  ci-xcode.py {ios,tvos} build [--derived-data DIR]
  ci-xcode.py {ios,tvos} test  [--only-testing IDS] [--output-dir DIR] [options]
  ci-xcode.py {ios,tvos} ui    [--only-testing IDS] [--device iphone|ipad] [options]
  ci-xcode.py {ios,tvos} cleanup --output-dir DIR

Run `xcodegen generate` in the app directory first. test and ui also need
Pillow (apps/apple/qa/requirements.txt) and ffmpeg with ffprobe 7.1 or later
to generate the fixture media.

build compiles for the generic simulator without signing. test runs the unit
tests and ui runs UI journeys. Both create a new simulator for the run (named
as the tests' ownership checks require), sign the build ad hoc for the
simulator (no identity, team or keychain prompt), start the synthetic
loopback fixtures each test class needs (see ci-fixtures.py), and delete the
simulator and stop the fixtures at the end. Only simulators this script
created, identified by the UDID it recorded, are ever shut down or deleted.

--only-testing takes identifiers separated by commas, spaces or new lines:
Bundle, Bundle/Class or Bundle/Class/testMethod (the bundle may be left out).
An empty value runs the unit bundle for test and the default UI set for ui
(listed in DEFAULT_UI in ci-fixtures.py). Identifiers of the other platform
are left out, so one list can serve both platforms.

After a failing run the failing tests, their messages with file and line,
and their text attachments are printed. Result bundles, exported
attachments, screen tour images and fixture logs stay in --output-dir.
cleanup removes a simulator or fixture left behind by an interrupted run.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fixtures = load("ci_fixtures", "ci-fixtures.py")
xcresult = load("ci_xcresult", "ci-xcresult.py")

MINIMUM_RUNTIME = (27, 0)
SIGNING = ["CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM="]
TARGETS = {
    "ios": {
        "directory": "apps/apple",
        "project": "Reel.xcodeproj",
        "scheme": "Reel",
        "tests": "ReelTests",
        "runtime": "iOS",
        "device_prefix": "iPhone",
        "generic": "generic/platform=iOS Simulator",
        "destination": "iOS Simulator",
    },
    "tvos": {
        "directory": "apps/tvos",
        "project": "ReelTV.xcodeproj",
        "scheme": "ReelTV",
        "tests": "ReelTVTests",
        "runtime": "tvOS",
        "device_prefix": "Apple TV",
        "generic": "generic/platform=tvOS Simulator",
        "destination": "tvOS Simulator",
    },
}
# Device families and preferred models. Apple TV prefers the 1080p model,
# which matches the layout the TV journeys were written against.
DEVICES = {
    "iphone": ("iPhone", ("iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro", "iPhone 16")),
    "ipad": ("iPad", ("iPad Pro 11-inch (M5)", "iPad Pro 11-inch (M4)", "iPad Air 11-inch (M3)", "iPad Air 11-inch (M2)")),
    "tv": ("Apple TV", ("Apple TV 4K (3rd generation) (at 1080p)", "Apple TV 4K (3rd generation)")),
}
EXECUTION_ALLOWANCE = {"test": "600", "ui": "1200"}


class Failure(RuntimeError):
    pass


class Interrupted(BaseException):
    pass


def github():
    return os.environ.get("GITHUB_ACTIONS") == "true"


def say(message=""):
    print(message, flush=True)


def group_start(title):
    say(("::group::" if github() else "== ") + title)


def group_end():
    if github():
        say("::endgroup::")


# ---------------------------------------------------------------- simulators

def brief(text, width=240):
    """First line of a reason, for the closing summary."""
    line = (text or "").strip().splitlines()[0] if (text or "").strip() else ""
    return line if len(line) <= width else line[:width - 3] + "..."


def runtime_version(identifier):
    """Return the version tuple of a CoreSimulator runtime identifier, e.g. iOS-27-0 -> (27, 0)."""
    tail = identifier.rsplit(".", 1)[-1]
    parts = tail.split("-")[1:]
    return tuple(int(part) for part in parts if part.isdigit())


def pick_simulator(listing, runtime, device_prefix):
    """Return (udid, name) of the newest available runtime's first matching device."""
    candidates = []
    for identifier, devices in listing.get("devices", {}).items():
        if identifier.rsplit(".", 1)[-1].split("-")[0] != runtime:
            continue
        for device in devices:
            if device.get("isAvailable", True) and device.get("name", "").startswith(device_prefix):
                candidates.append((runtime_version(identifier), device["name"], device["udid"]))
    if not candidates:
        raise SystemExit("No available %s simulator named %s*" % (runtime, device_prefix))
    newest = max(version for version, _, _ in candidates)
    _, name, udid = sorted(item for item in candidates if item[0] == newest)[0]
    return udid, name


def version_of(runtime):
    text = runtime.get("version") or ""
    if re.fullmatch(r"\d+(\.\d+)*", text):
        return tuple(int(part) for part in text.split("."))
    return runtime_version(runtime.get("identifier", ""))


def platform_of(runtime):
    return runtime.get("platform") or runtime.get("identifier", "").rsplit(".", 1)[-1].split("-")[0]


def choose_runtime(inventory, platform, requested=""):
    """Newest available runtime of a platform, or the requested one."""
    runtimes = [item for item in inventory.get("runtimes", []) if item.get("isAvailable") and platform_of(item) == platform]
    if requested:
        runtimes = [item for item in runtimes if requested in (item.get("identifier"), item.get("version"), item.get("name"))]
        if not runtimes:
            raise Failure("The %s simulator runtime %s is not installed." % (platform, requested))
    if not runtimes:
        raise Failure("No %s simulator runtime is installed. Install one in Xcode settings." % platform)
    runtime = max(runtimes, key=version_of)
    if version_of(runtime) < MINIMUM_RUNTIME:
        raise Failure("The newest %s runtime is %s; the app needs %d.%d or later." % (
            platform, runtime.get("version") or runtime.get("identifier"), *MINIMUM_RUNTIME))
    return runtime


def choose_device_type(runtime, family, requested="", listing=None):
    """(identifier, name) of the device type to create for a runtime."""
    product, preferred = DEVICES[family]
    supported = [item for item in runtime.get("supportedDeviceTypes") or [] if item.get("identifier")]
    if requested:
        for item in supported:
            if requested in (item.get("identifier"), item.get("name")):
                return item["identifier"], item.get("name", requested)
        if supported:
            raise Failure("The device type %s is not supported by %s." % (requested, runtime.get("name") or runtime.get("identifier")))
        return requested, requested
    family_types = [item for item in supported if item.get("productFamily") == product or item.get("name", "").startswith(product)]
    for name in preferred:
        for item in family_types:
            if item.get("name") == name:
                return item["identifier"], name
    if family == "iphone":
        plain = [item for item in family_types if not re.search(r"Max|Plus|mini|SE|\de\b", item.get("name", ""))]
        family_types = plain or family_types
    elif family == "ipad":
        family_types = [item for item in family_types if "11-inch" in item.get("name", "")] or family_types
    elif family == "tv":
        family_types = [item for item in family_types if "4K" in item.get("name", "")] or family_types
    if family_types:
        return family_types[-1]["identifier"], family_types[-1].get("name", "")
    if listing:
        # Older simctl output has no supported device types; reuse the model
        # name of an installed simulator, never the simulator itself.
        _, name = pick_simulator(listing, platform_of(runtime), product)
        return name, name
    raise Failure("No %s device type is available for %s." % (product, runtime.get("identifier")))


def simulator_name(platform):
    """Names the ownership checks in the tests accept."""
    if platform == "tvos":
        return "Reel QA Apple TV"
    return "Reel QA Improvements Player " + secrets.token_hex(4)


def simctl(*arguments, check=True, capture=True, runner=subprocess.run, timeout=600):
    completed = runner(["xcrun", "simctl"] + list(arguments), capture_output=capture, text=True, timeout=timeout)
    if check and completed.returncode != 0:
        raise Failure("xcrun simctl %s failed: %s" % (" ".join(arguments[:2]), (completed.stderr or completed.stdout or "").strip()))
    return completed


def parse_udid(text):
    value = (text or "").strip()
    try:
        uuid.UUID(value)
    except ValueError:
        raise Failure("simctl create did not return a simulator identifier: %r" % value)
    return value


def find_device(listing, udid):
    for runtime, devices in listing.get("devices", {}).items():
        for device in devices:
            if device.get("udid") == udid:
                return runtime, device
    return None, None


class State:
    """Remembers what this run created, so cleanup can undo only that."""

    def __init__(self, path):
        self.path = Path(path)
        self.data = {"simulators": [], "processes": []}
        if self.path.is_file():
            self.data = json.loads(self.path.read_text())

    def save(self):
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.data, indent=2) + "\n")
        os.replace(temporary, self.path)

    def record(self, event, value):
        if event == "simulator":
            self.data["simulators"].append(value)
        elif event == "simulator-deleted":
            self.data["simulators"] = [item for item in self.data["simulators"] if item["udid"] != value["udid"]]
        elif event == "process":
            self.data["processes"].append(value)
        elif event == "process-stopped":
            self.data["processes"] = [item for item in self.data["processes"] if item["pid"] != value["pid"]]
        self.save()


def create_simulator(platform, family, state, *, runtime="", device_type="", runner=subprocess.run):
    runtimes = json.loads(simctl("list", "runtimes", "--json", runner=runner).stdout)
    chosen = choose_runtime(runtimes, TARGETS[platform]["runtime"], runtime)
    listing = None
    if not chosen.get("supportedDeviceTypes"):
        listing = json.loads(simctl("list", "devices", "available", "--json", runner=runner).stdout)
    type_id, type_name = choose_device_type(chosen, family, device_type, listing)
    before = json.loads(simctl("list", "devices", "--json", runner=runner).stdout)
    name = simulator_name(platform)
    udid = parse_udid(simctl("create", name, type_id, chosen["identifier"], runner=runner).stdout)
    if find_device(before, udid)[1]:
        raise Failure("simctl create returned an existing simulator; refusing to use it.")
    state.record("simulator", {"udid": udid, "name": name})
    say("Created simulator %s (%s, %s) %s" % (name, type_name, chosen.get("name") or chosen["identifier"], udid))
    return udid, name


def delete_simulator(udid, name, state=None, runner=subprocess.run):
    """Shut down and delete a simulator this run created, checking its name first."""
    listing = json.loads(simctl("list", "devices", "--json", runner=runner).stdout)
    _, device = find_device(listing, udid)
    if device is None:
        if state:
            state.record("simulator-deleted", {"udid": udid})
        return
    if device.get("name") != name:
        raise Failure("Simulator %s is now named %r, not %r; leaving it alone." % (udid, device.get("name"), name))
    if device.get("state") != "Shutdown":
        simctl("shutdown", udid, check=False, runner=runner)
    simctl("delete", udid, runner=runner)
    if state:
        state.record("simulator-deleted", {"udid": udid})
    say("Deleted simulator %s" % udid)


# ---------------------------------------------------------------- xcodebuild

def test_arguments(target, udid, derived_data):
    return [
        "-project", target["project"],
        "-scheme", target["scheme"],
        "-destination", "platform=%s,id=%s" % (target["destination"], udid),
        "-derivedDataPath", str(derived_data),
    ]


def build_for_testing_command(target, udid, derived_data):
    return ["xcodebuild", "build-for-testing"] + test_arguments(target, udid, derived_data) + [
        "-configuration", "Debug", "-enableCodeCoverage", "NO"] + SIGNING


def test_command(target, udid, derived_data, result, group, action):
    command = ["xcodebuild", "test-without-building"] + test_arguments(target, udid, derived_data) + [
        "-resultBundlePath", str(result),
        "-parallel-testing-enabled", "NO",
        "-collect-test-diagnostics", "never",
        "-enableCodeCoverage", "NO",
        "-test-timeouts-enabled", "YES",
        "-default-test-execution-time-allowance", EXECUTION_ALLOWANCE[action],
    ]
    command += ["-only-testing:" + item for item in group.only]
    command += ["-skip-testing:" + item for item in group.skip]
    return command


def xcodebuild_env(extra):
    """The parent environment without inherited TEST_RUNNER_REEL_ values, plus ours."""
    env = {key: value for key, value in os.environ.items() if not key.startswith("TEST_RUNNER_REEL_")}
    env.update(extra)
    env["NSUnbufferedIO"] = "YES"
    return env


class Runner:
    """Runs long commands with their output in the log and in a file."""

    def __init__(self):
        self.current = None

    def run(self, command, *, cwd, env, log_path, title):
        group_start(title)
        say("$ " + " ".join(command))
        with open(log_path, "w") as log:
            self.current = subprocess.Popen(command, cwd=str(cwd), env=env, stdout=subprocess.PIPE,
                                            stderr=subprocess.STDOUT, text=True, errors="replace", bufsize=1)
            try:
                for line in self.current.stdout:
                    sys.stdout.write(line)
                    log.write(line)
                code = self.current.wait()
            finally:
                process, self.current = self.current, None
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        process.kill()
        sys.stdout.flush()
        group_end()
        return code


def build_errors(text, limit=80):
    """Compiler and build-system errors from xcodebuild output, in order."""
    lines, seen, collecting = [], set(), False
    for line in text.splitlines():
        stripped = line.strip()
        if "The following build commands failed:" in stripped:
            collecting = True
        elif collecting and not stripped:
            collecting = False
        if collecting or re.search(r"(^|\s|:)(error|fatal error):\s", stripped) or stripped.startswith(("** BUILD FAILED", "** TEST BUILD FAILED", "xcodebuild: error")):
            if stripped not in seen:
                seen.add(stripped)
                lines.append(stripped)
    return lines[:limit]


def source_index():
    """Swift file name -> repository path, for failure annotations."""
    index = {}
    for sources in fixtures.TEST_SOURCES.values():
        for source in sources:
            path = ROOT / source
            for file in (sorted(path.rglob("*.swift")) if path.is_dir() else [path]):
                index.setdefault(file.name, file.relative_to(ROOT).as_posix())
    for folder in ("apps/tvos/TestSupport",):
        for file in sorted((ROOT / folder).rglob("*.swift")):
            index.setdefault(file.name, file.relative_to(ROOT).as_posix())
    return index


# ---------------------------------------------------------------- screen tour

class TourWatcher(threading.Thread):
    """Answers ScreenTourUITests: for each <name>.request it writes <name>.png
    from `simctl io screenshot`, renamed into place so the test never reads
    a partial image."""

    def __init__(self, folder, udid, runner=subprocess.run):
        super().__init__(daemon=True)
        self.folder = Path(folder)
        self.udid = udid
        self.runner = runner
        self.stopping = threading.Event()
        self.captured = []
        self.errors = []

    def poll(self):
        for request in sorted(self.folder.glob("*.request")):
            name = request.stem
            partial = self.folder / (".partial-" + name + ".png")
            completed = self.runner(["xcrun", "simctl", "io", self.udid, "screenshot", "--type=png", str(partial)],
                                    capture_output=True, text=True, timeout=60)
            if completed.returncode != 0 or not partial.is_file():
                self.errors.append("%s: %s" % (name, (completed.stderr or "").strip()))
                continue
            os.replace(partial, self.folder / (name + ".png"))
            request.unlink()
            self.captured.append(name)

    def run(self):
        while not self.stopping.is_set():
            try:
                self.poll()
            except (OSError, subprocess.SubprocessError) as error:
                self.errors.append(str(error))
            self.stopping.wait(0.25)

    def stop(self):
        self.stopping.set()
        self.join(timeout=90)


# ---------------------------------------------------------------- run

def output_directory(value, platform, action):
    if value:
        path = Path(value).resolve()
        if path.exists() and any(path.iterdir()):
            raise Failure("The output directory %s is not empty. Use a new one." % path)
    else:
        path = Path(tempfile.mkdtemp(prefix="reel-ci-%s-%s-" % (platform, action))).resolve()
    if path == ROOT or ROOT in path.parents:
        raise Failure("Use an output directory outside the repository.")
    for name in ("logs", "media", "results"):
        (path / name).mkdir(parents=True, exist_ok=True)
    return path


class Session:
    """Everything one test or ui run owns, released in stop()."""

    def __init__(self, platform, action, args):
        self.platform, self.action, self.args = platform, action, args
        self.target = TARGETS[platform]
        self.app = ROOT / self.target["directory"]
        self.family = "tv" if platform == "tvos" else (args.device or "iphone")
        self.runner = Runner()
        self.simulator = None
        self.fixtures = None
        self.tour = None
        self.stopped = False

    def interrupt(self, signum, frame):
        raise Interrupted("Stopped by signal %d" % signum)

    def run(self):
        selected, notes = fixtures.resolve(self.platform, self.action, self.args.only_testing, device=self.family)
        groups = fixtures.plan(selected)
        for note in notes:
            say(note)
        if not shutil.which("xcrun"):
            raise Failure("xcrun was not found. This needs macOS with Xcode installed.")
        self.output = output_directory(self.args.output_dir, self.platform, self.action)
        self.logs, self.results = self.output / "logs", self.output / "results"
        self.state = State(self.output / "state.json")
        self.state.save()
        say("Output: %s" % self.output)
        for index, group in enumerate(groups, 1):
            say("Group %d: %s%s" % (index, " ".join(group.only), "" if not group.skip else " (skipping %d tests that need a staged storage phase)" % len(group.skip)))
        everything = sorted({name for group in groups for name in group.services})
        busy = fixtures.busy_ports(everything)
        if busy:
            raise Failure("These loopback ports are in use: %s. Stop whatever holds them first." % ", ".join(busy))
        udid, name = create_simulator(self.platform, self.family, self.state, runtime=self.args.runtime, device_type=self.args.device_type)
        self.simulator = (udid, name)
        simctl("boot", udid, check=False)
        kinds = []
        for group in groups:
            kinds += [kind for kind in group.media() if kind not in kinds]
        paths = fixtures.prepare_media(kinds, self.output / "media", self.logs, say=say)
        derived = (self.app / (self.args.derived_data or default_derived_data())).resolve()
        log = self.logs / "build-for-testing.log"
        code = self.runner.run(build_for_testing_command(self.target, udid, derived), cwd=self.app,
                               env=xcodebuild_env({}), log_path=log, title="Build for testing (%s)" % self.platform)
        if code != 0:
            errors = build_errors(log.read_text(errors="replace"))
            say("Build for testing failed with status %d." % code)
            for line in errors or ["(no error lines found; see %s)" % log]:
                say("  " + line)
            raise Failure("The %s build for testing failed." % self.platform)
        simctl("bootstatus", udid, "-b")
        owners = fixtures.new_owners()
        values = {"qa_owner": owners[fixtures.QA_OWNER], "parity_owner": owners[fixtures.PARITY_OWNER], "udid": udid}
        index_of_sources = source_index()
        outcomes = []
        for index, group in enumerate(groups, 1):
            outcomes.append(self.run_group(index, len(groups), group, paths, owners, values, derived, index_of_sources))
        say("")
        say("Summary")
        for index, (group, reasons) in enumerate(zip(groups, outcomes), 1):
            say("  Group %d (%s): %s" % (index, ", ".join(group.keys), "passed" if not reasons else "FAILED: " + " ".join(brief(reason) for reason in reasons)))
        return 1 if any(outcomes) else 0

    def run_group(self, index, count, group, paths, owners, values, derived, sources):
        udid = self.simulator[0]
        label = "%s-%s-%d" % (self.platform, self.action, index)
        result = self.results / (label + ".xcresult")
        self.fixtures = fixtures.Fixtures(paths, owners, self.logs, record=self.state.record, say=say)
        reasons = []
        tour_folder = self.results / (label + "-tour")
        try:
            self.fixtures.start(group.services)
            env = fixtures.test_runner_env(group, values)
            env["TEST_RUNNER_REEL_LIVE_PREVIEW_TESTS"] = "0"
            if group.tour:
                tour_folder.mkdir()
                env["TEST_RUNNER_REEL_TOUR_DIR"] = str(tour_folder)
                self.tour = TourWatcher(tour_folder, udid)
                self.tour.start()
            title = "Tests, group %d of %d (%s)" % (index, count, ", ".join(group.keys))
            code = self.runner.run(test_command(self.target, udid, derived, result, group, self.action), cwd=self.app,
                                   env=xcodebuild_env(env), log_path=self.logs / (label + ".log"), title=title)
            try:
                self.fixtures.check_alive()
            except fixtures.FixtureError as error:
                reasons.append(str(error))
        except fixtures.FixtureError as error:
            code = None
            reasons.append(str(error))
        finally:
            if self.tour:
                self.tour.stop()
                if self.tour.errors:
                    reasons.append("Screen tour captures failed: " + "; ".join(self.tour.errors[:5]))
                if self.tour.captured:
                    say("Screen tour images: %d in %s" % (len(self.tour.captured), tour_folder))
                self.tour = None
            reasons += ["Stopping a fixture failed: " + problem for problem in self.fixtures.stop()]
            self.fixtures = None
        say("")
        say("Results, group %d of %d (%s)" % (index, count, ", ".join(group.keys)))
        if code is None:
            say("  The tests did not start.")
            for reason in reasons:
                say("  " + reason.replace("\n", "\n  "))
            return reasons
        if not result.exists():
            say("  xcodebuild exited with status %d and wrote no result bundle. Last output:" % code)
            say("\n".join("  | " + line for line in fixtures.tail(self.logs / (label + ".log"), 60).splitlines()))
            return reasons + ["xcodebuild exited with status %d without results." % code]
        report = xcresult.read(result)
        if report.count("Failed"):
            report.attachments, notes = xcresult.export_attachments(result, self.results / (label + "-attachments"))
            report.problems.extend(notes)
        say(xcresult.render(report, sources=sources, annotate=github(), base=self.output))
        if report.total() == 0:
            say("  No test results were recorded. Last xcodebuild output:")
            say("\n".join("  | " + line for line in fixtures.tail(self.logs / (label + ".log"), 60).splitlines()))
        reasons += xcresult.problems(report, group.only, named_methods=group.named if self.action == "ui" else (),
                                     allow_skips=self.action == "test")
        if code != 0 and not reasons:
            reasons.append("xcodebuild exited with status %d." % code)
        if reasons:
            say("Fixture logs: %s" % self.logs)
        return reasons

    def stop(self):
        if self.stopped:
            return []
        self.stopped = True
        problems = []
        if self.tour:
            self.tour.stop()
        if self.fixtures:
            problems += self.fixtures.stop()
        if self.simulator:
            try:
                delete_simulator(*self.simulator, state=self.state)
            except (Failure, OSError, subprocess.SubprocessError, ValueError) as error:
                problems.append(str(error))
        return problems


def run_tests(platform, action, args):
    session = Session(platform, action, args)
    previous = {sig: signal.signal(sig, session.interrupt) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    code = 1
    try:
        code = session.run()
    except (Failure, fixtures.FixtureError, fixtures.SelectionError, OSError, subprocess.SubprocessError) as error:
        say("Error: %s" % error)
    except Interrupted as error:
        say("Interrupted: %s. Cleaning up." % error)
        code = 130
    finally:
        for sig in previous:
            signal.signal(sig, signal.SIG_IGN)
        for problem in session.stop():
            say("Cleanup problem: %s" % problem)
            code = code or 1
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    return code


def cleanup(args, runner=subprocess.run):
    """Undo what an interrupted run recorded in its state file."""
    if not args.output_dir:
        raise Failure("cleanup needs --output-dir")
    path = Path(args.output_dir) / "state.json"
    if not path.is_file():
        say("Nothing to clean up.")
        return 0
    state = State(path)
    problems = []
    for item in list(state.data["processes"]):
        pid, script = int(item["pid"]), item["script"]
        completed = runner(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True)
        if completed.returncode == 0 and script in completed.stdout:
            try:
                os.killpg(pid, signal.SIGTERM)
                say("Stopped leftover fixture %s (pid %d)" % (item.get("name", script), pid))
            except ProcessLookupError:
                pass
            except OSError as error:
                problems.append("Fixture %d: %s" % (pid, error))
        state.record("process-stopped", {"pid": pid})
    for item in list(state.data["simulators"]):
        try:
            delete_simulator(item["udid"], item["name"], state=state, runner=runner)
        except (Failure, OSError, subprocess.SubprocessError, ValueError) as error:
            problems.append(str(error))
    for problem in problems:
        say("Cleanup problem: %s" % problem)
    return 1 if problems else 0


def default_derived_data():
    """Shared by build, test and ui; relative paths are inside the app folder."""
    return os.path.join(os.environ.get("RUNNER_TEMP", "build"), "DerivedData")


def build(platform, args):
    target = TARGETS[platform]
    command = [
        "xcodebuild", "build",
        "-project", target["project"],
        "-scheme", target["scheme"],
        "-derivedDataPath", args.derived_data or default_derived_data(),
        "-destination", target["generic"],
        "CODE_SIGNING_ALLOWED=NO",
    ]
    return subprocess.call(command, cwd=ROOT / target["directory"], env=dict(os.environ, REEL_LIVE_PREVIEW_TESTS="0"))


def main(argv):
    parser = argparse.ArgumentParser(description=(__doc__ or "").partition("\n")[0])
    parser.add_argument("platform", choices=sorted(TARGETS))
    parser.add_argument("action", choices=("build", "test", "ui", "cleanup"))
    parser.add_argument("--derived-data", help="DerivedData folder, relative to the app folder (default build/DerivedData, or DerivedData in RUNNER_TEMP)")
    parser.add_argument("--only-testing", action="append", default=[], help="Test identifiers to run")
    parser.add_argument("--output-dir", help="New or empty folder outside the repository for results, logs and fixture media (default: a new temporary folder)")
    parser.add_argument("--device", choices=("iphone", "ipad"), help="iOS simulator family (default iphone)")
    parser.add_argument("--device-type", default="", help="Simulator device type name or identifier")
    parser.add_argument("--runtime", default="", help="Simulator runtime identifier or version")
    args = parser.parse_args(argv)
    if args.platform == "tvos" and args.device:
        say("Ignoring --device for tvOS.")
        args.device = None
    try:
        if args.action == "build":
            return build(args.platform, args)
        if args.action == "cleanup":
            return cleanup(args)
    except Failure as error:
        say("Error: %s" % error)
        return 1
    return run_tests(args.platform, args.action, args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
