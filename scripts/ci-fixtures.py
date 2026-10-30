#!/usr/bin/env python3
"""Synthetic loopback fixtures for the iOS and tvOS simulator tests.

Every test class is mapped to a profile: the fixture servers it talks to,
the values it reads from its environment (passed to xcodebuild with the
TEST_RUNNER_ prefix) and any tests that cannot run unattended. Classes whose
fixtures clash, such as TVJourneys and TVEpisodePlayerJourneys, which both
use port 18967 for different servers, run in separate groups.

ci-xcode.py uses this module. It can also be run on its own to generate the
media, start one platform's fixtures, check each one answers as its owner,
and stop them again:

    python3 scripts/ci-fixtures.py tvos --output-dir NEW_EMPTY_DIRECTORY

Fixture servers bind 127.0.0.1 only. Media for the Apple TV fixtures is
generated outside the repository; the iPhone fixture media is generated in
apps/apple/qa, where it is git-ignored.
"""
import argparse
from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import ProxyHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[1]
QA_OWNER = "REEL_TV_QA_OWNER"
PARITY_OWNER = "REEL_TV_PARITY_OWNER"
TEST_SOURCES = {
    "ReelTests": ("apps/apple/ReelTests",),
    "ReelUITests": ("apps/apple/ReelUITests",),
    "ReelTVTests": ("apps/tvos/ReelTVTests", "apps/apple/ReelTests/AudioSelectionTests.swift"),
    "ReelTVUITests": ("apps/tvos/ReelTVUITests",),
}
BUNDLES = {
    ("ios", "test"): ("ReelTests",),
    ("ios", "ui"): ("ReelUITests",),
    ("tvos", "test"): ("ReelTVTests",),
    ("tvos", "ui"): ("ReelTVUITests",),
}


@dataclass(frozen=True)
class Service:
    """One fixture server. Arguments may name media paths in braces."""
    name: str
    port: int
    script: str
    args: tuple = ()
    media: tuple = ()
    owner: str = ""
    udp: tuple = ()

    def identity_path(self):
        if self.owner == QA_OWNER:
            return "/qa/tv-identity"
        if self.owner == PARITY_OWNER:
            return "/qa/parity-identity"
        return ""

    def identity_kind(self):
        return "reel-tv-library-parity" if self.owner == PARITY_OWNER else "reel-tv-owned-fixture"


SERVICES = {service.name: service for service in (
    Service("ios-primary", 18766, "apps/apple/qa/fixture_server.py", ("--port", "18766"), ("ios",), udp=(17359,)),
    Service("ios-secondary", 18767, "apps/apple/qa/fixture_server.py", ("--port", "18767"), ("ios",)),
    Service("ios-requests", 18768, "apps/apple/qa/seerr_contract.py", ("--port", "18768"), ("ios",)),
    Service("ios-remote", 18769, "apps/apple/qa/remote_contract.py", ("--port", "18769"), ("ios",)),
    Service("player-main", 18966, "apps/apple/qa/run-player-fixture.py", ("--port", "18966", "--media", "{tracks}"), ("tracks",), QA_OWNER),
    Service("tv-main", 18966, "apps/tvos/qa/run-fixture.py", ("--port", "18966", "--media", "{tracks}"), ("tracks",), QA_OWNER),
    Service("tv-second", 18967, "apps/tvos/qa/run-fixture.py", ("--port", "18967", "--media", "{tracks}"), ("tracks",), QA_OWNER),
    Service("tv-subtitles", 18968, "apps/tvos/qa/run-fixture.py", ("--port", "18968", "--media", "{tracks}", "--subtitle-selection-fixture"), ("tracks",), QA_OWNER),
    Service("multiaudio", 18969, "apps/tvos/qa/run-multiaudio-fixture.py", ("--port", "18969", "--media", "{multiaudio}"), ("multiaudio",), QA_OWNER),
    Service("tv-episodes", 18967, "apps/tvos/qa/run-episode-fixture.py", ("--port", "18967", "--media", "{silent}"), ("silent",), QA_OWNER),
    Service("tv-library", 18970, "apps/tvos/qa/run-library-fixture.py", ("--port", "18970", "--media", "{tracks}", "--media-manifest", "{library_manifest}"), ("tracks", "library_manifest"), PARITY_OWNER),
    Service("tv-library-second", 18971, "apps/tvos/qa/run-library-fixture.py", ("--port", "18971", "--media", "{tracks}", "--media-manifest", "{library_manifest}"), ("tracks", "library_manifest"), PARITY_OWNER),
)}


@dataclass(frozen=True)
class Profile:
    """What a test class needs. Environment values may be {qa_owner},
    {parity_owner} or {udid}; each key is passed as TEST_RUNNER_<key>."""
    services: tuple = ()
    env: tuple = ()
    staged: tuple = ()
    tour: bool = False


IOS_FIXTURES = ("ios-primary", "ios-secondary", "ios-requests", "ios-remote")
IOS_UI = Profile(IOS_FIXTURES)
TV_QA_ENV = (("REEL_TV_QA_OWNER", "{qa_owner}"), ("REEL_TV_QA_DEVICE_UDID", "{udid}"))
TV_PARITY_ENV = (("REEL_TV_PARITY_OWNER", "{parity_owner}"), ("REEL_TV_PARITY_DEVICE_UDID", "{udid}"))
# Tests in TVLibraryJourneys that need a host to stage storage phases and
# acknowledge recovery handshakes; nothing in CI drives those phases.
TV_STORAGE_PHASE_TESTS = (
    "testSeedChoicesForOwnedUnreadableRecovery",
    "testSeedLastAccountAndSiblingChoicesForRemovalRecovery",
    "testUnreadableSeeAllViewEditRecoversInSameOwnedAppProcess",
    "testUnreadableFilePermissionRecoversPendingViewInSameOwnedProcess",
    "testSyntheticDirectoryWriteDenialKeepsQueryUntilSameProcessRetry",
    "testUnreadableResetRequiresConfirmationAndKeepsCatalogReachable",
    "testRemovedChoicesFailureSurvivesConnectAndExplicitRetryClearsOnlyRemovedScope",
    "testReaddedAccountKeepsNewChoicesWhenOldRemovalCleanupRetries",
)
PROFILES = {
    # PlaybackStreamChangeTests read REEL_PLAYER_QA_DEVICE_UDID and the owned
    # player fixtures on 18966 and 18969; the rest use the four iPhone fixtures.
    "ReelTests": Profile(IOS_FIXTURES + ("player-main", "multiaudio"),
                         (("REEL_TV_QA_OWNER", "{qa_owner}"), ("REEL_PLAYER_QA_DEVICE_UDID", "{udid}"))),
    "ReelTVTests": Profile(("tv-main", "tv-subtitles", "multiaudio", "tv-episodes", "tv-library"),
                           TV_QA_ENV + TV_PARITY_ENV + (("REEL_TV_EPISODE_JOURNEYS", "1"),)),
    "ReelUITests/ReelUITests": IOS_UI,
    "ReelUITests/HomeCompactUITests": IOS_UI,
    "ReelUITests/ConnectKeyboardUITests": IOS_UI,
    "ReelUITests/PhoneNavigationUITests": IOS_UI,
    "ReelUITests/PlayerCompatibilityUITests": IOS_UI,
    "ReelUITests/LibraryFilteringUITests": IOS_UI,
    "ReelUITests/FullScopeUITests": IOS_UI,
    "ReelUITests/RemoteRequestsExtendedUITests": IOS_UI,
    "ReelUITests/ConnectionsPlayerExtendedUITests": IOS_UI,
    "ReelUITests/DiscoveryControlsUITests": IOS_UI,
    "ReelUITests/NativeControlsUITests": IOS_UI,
    "ReelUITests/NativeDownloadsUITests": IOS_UI,
    "ReelUITests/PlaybackExtrasUITests": IOS_UI,
    "ReelUITests/ScreenTourUITests": Profile(IOS_FIXTURES, tour=True),
    "ReelTVUITests/TVJourneys": Profile(("tv-main", "tv-second", "tv-subtitles", "multiaudio"), TV_QA_ENV),
    "ReelTVUITests/TVLibraryJourneys": Profile(("tv-library", "tv-library-second"), TV_PARITY_ENV, staged=TV_STORAGE_PHASE_TESTS),
    "ReelTVUITests/TVWatchedJourneys": Profile(("tv-library",), TV_PARITY_ENV + (("REEL_TV_PARITY_MUTABLE", "1"),)),
    "ReelTVUITests/TVEpisodePlayerJourneys": Profile(("tv-episodes",), TV_QA_ENV + (("REEL_TV_EPISODE_JOURNEYS", "1"),)),
}
UNSUPPORTED = {
    "ReelUITests/BrowseIntegrityUITests": "it needs qa/browse_integrity_server.py on 19140 and 19141 with a per-run nonce and source digest",
    "ReelUITests/NativePresentationUITests": "it needs the player design fixture and its artwork, which this runner does not start",
    "ReelUITests/PlayerPresentationUITests": "it needs the player presentation fixtures, which this runner does not start",
    "ReelUITests/PlayerStreamOptionsUITests": "it needs the player fixtures on 18966, 18968 and 18969 and the SyncPlay fixture on 18974",
    "ReelUITests/NativeStorageUITests": "it needs qa/runtime_storage_recovery.py to inject storage faults around the run",
    "ReelUITests/LivePreviewUITests": "it signs in to a real server and never runs in CI",
    "ReelUITests/HoldScreenUITests": "it holds one screen open on a signed-in simulator for manual screenshots",
}
# Used when --only-testing is empty. iPhone: the phone journeys that guarded
# earlier releases plus the main ReelUITests journeys and the screen tour.
# iPad: the screen tour and the main journeys. Apple TV: remote journeys
# through every top tab, Details, playback end and Home recovery.
DEFAULT_UI = {
    ("ios", "iphone"): (
        "ReelUITests/HomeCompactUITests",
        "ReelUITests/ConnectKeyboardUITests",
        "ReelUITests/PhoneNavigationUITests",
        "ReelUITests/PlayerCompatibilityUITests",
        "ReelUITests/ReelUITests",
        "ReelUITests/ScreenTourUITests",
    ),
    ("ios", "ipad"): (
        "ReelUITests/ScreenTourUITests",
        "ReelUITests/ReelUITests",
    ),
    ("tvos", "tv"): tuple("ReelTVUITests/TVJourneys/" + name for name in (
        "testRemoteSignInHomeDetailsAndBack",
        "testRemoteEveryHomeShelfOpensItsOwnTitle",
        "testRemoteOnlyHomeRowsTabBarSeriesSeasonAndEpisode",
        "testRemoteDetailLoadingBackRejectsLateTitle",
        "testRemoteEmptyHomeRefreshAndManageServers",
        "testRemotePartialHomeRetryRestoresShelf",
        "testRemoteEndedPlayAgainStartsFromZero",
        "testRemoteDetailAndEpisodeRetryAndEmptySeasons",
        "testRemoteLibraryPaginationSeasonEpisodeAndSearchClear",
        "testRemoteSettingsAccountsPrivacyQualityAndRemovalPersist",
    )),
}


class FixtureError(RuntimeError):
    pass


class SelectionError(ValueError):
    pass


# ---------------------------------------------------------------- selection

def catalog(root=ROOT):
    """{bundle: {class: [test methods]}} read from the Swift sources."""
    result = {}
    for bundle, sources in TEST_SOURCES.items():
        classes = result.setdefault(bundle, {})
        files = []
        for source in sources:
            path = root / source
            files += sorted(path.rglob("*.swift")) if path.is_dir() else [path] if path.is_file() else []
        for path in files:
            text = path.read_text(errors="replace")
            declarations = list(re.finditer(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", text))
            for index, declaration in enumerate(declarations):
                end = declarations[index + 1].start() if index + 1 < len(declarations) else len(text)
                methods = classes.setdefault(declaration.group(1), [])
                methods += [name for name in re.findall(r"\bfunc\s+(test\w+)\s*\(", text[declaration.end():end]) if name not in methods]
    return result


def split_identifiers(values):
    items = []
    for value in values or ():
        items += [item.strip() for item in re.split(r"[\s,]+", value or "") if item.strip()]
    return items


@dataclass(frozen=True)
class Selected:
    identifier: str
    bundle: str
    test_class: str = ""
    method: str = ""


def resolve(platform, action, raw, *, device="", tests=None):
    """Turn --only-testing values into checked identifiers for one platform.

    Returns (selected, notes). Identifiers of the other platform are left out
    with a note, so one list can drive both platforms."""
    tests = catalog() if tests is None else tests
    own = BUNDLES[(platform, action)]
    other_platform = "tvos" if platform == "ios" else "ios"
    foreign = set(BUNDLES[(other_platform, "test")] + BUNDLES[(other_platform, "ui")])
    wrong_action = set(BUNDLES[(platform, "ui" if action == "test" else "test")])
    items = split_identifiers(raw)
    explicit = bool(items)
    if not items:
        if action == "test":
            items = list(own)
        else:
            items = list(DEFAULT_UI[(platform, device or ("tv" if platform == "tvos" else "iphone"))])
    selected, notes = [], []
    for item in items:
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(/[A-Za-z_][A-Za-z0-9_]*(\(\))?){0,2}", item):
            raise SelectionError("Not a test identifier: %r. Use Bundle/Class/testMethod." % item)
        parts = item.replace("()", "").split("/")
        if parts[0] not in tests:
            owners = [bundle for bundle, classes in tests.items() if parts[0] in classes]
            mine = [bundle for bundle in owners if bundle in own]
            if len(mine) == 1:
                owners = mine
            if not owners:
                raise SelectionError("Unknown test bundle or class: %s" % item)
            if len(owners) > 1:
                raise SelectionError("%s is in %s; add the bundle name." % (item, " and ".join(owners)))
            parts = [owners[0]] + parts
        bundle = parts[0]
        if len(parts) > 3:
            raise SelectionError("Too many parts in %s" % item)
        if len(parts) == 2 and parts[1] not in tests[bundle] and parts[1] in tests[bundle].get(bundle, ()):
            # ReelUITests/testX: the class shares the bundle's name.
            parts = [bundle] + parts
        if bundle in foreign:
            notes.append("Leaving out %s: it belongs to the other platform." % item)
            continue
        if bundle in wrong_action:
            raise SelectionError("%s is run by the %s action, not %s." % (item, "ui" if action == "test" else "test", action))
        if bundle not in own:
            raise SelectionError("Unknown test bundle: %s" % bundle)
        test_class = parts[1] if len(parts) > 1 else ""
        method = parts[2] if len(parts) > 2 else ""
        if test_class and test_class not in tests[bundle]:
            raise SelectionError("No test class %s in %s." % (test_class, bundle))
        if method and method not in tests[bundle][test_class]:
            raise SelectionError("No test %s in %s/%s." % (method, bundle, test_class))
        identifier = "/".join(part for part in (bundle, test_class, method) if part)
        if any(existing.identifier == identifier for existing in selected):
            continue
        selected.append(Selected(identifier, bundle, test_class, method))
    if explicit and not selected:
        raise SelectionError("None of the selected tests belong to %s." % ("iOS" if platform == "ios" else "tvOS"))
    return selected, notes


def profile_for(selected, tests=None):
    """(profile key, Profile) for one selection, or a SelectionError."""
    if selected.bundle in PROFILES and selected.bundle in ("ReelTests", "ReelTVTests"):
        return selected.bundle, PROFILES[selected.bundle]
    if not selected.test_class:
        tests = catalog() if tests is None else tests
        raise SelectionError("Select %s classes or tests, not the whole bundle: %s" % (selected.bundle, ", ".join(sorted(tests[selected.bundle]))))
    key = selected.bundle + "/" + selected.test_class
    if key in UNSUPPORTED:
        raise SelectionError("%s cannot run here: %s." % (key, UNSUPPORTED[key]))
    if key not in PROFILES:
        raise SelectionError("%s has no fixture mapping in scripts/ci-fixtures.py. Add one before running it." % key)
    profile = PROFILES[key]
    if selected.method and selected.method in profile.staged:
        raise SelectionError("%s needs a staged storage phase that CI does not drive." % selected.identifier)
    return key, profile


@dataclass
class Group:
    """Tests that share one set of compatible fixtures and one xcodebuild run."""
    services: list = field(default_factory=list)
    env: dict = field(default_factory=dict)
    only: list = field(default_factory=list)
    skip: list = field(default_factory=list)
    named: list = field(default_factory=list)
    tour: bool = False
    keys: list = field(default_factory=list)

    def ports(self):
        return {SERVICES[name].port: name for name in self.services}

    def media(self):
        kinds = []
        for name in self.services:
            kinds += [kind for kind in SERVICES[name].media if kind not in kinds]
        return kinds


def compatible(group, profile):
    ports = group.ports()
    return all(ports.get(SERVICES[name].port, name) == name for name in profile.services)


def plan(selected, tests=None):
    """Assign selections to groups; a group never holds two servers on one port."""
    groups = []
    for item in selected:
        key, profile = profile_for(item, tests)
        group = next((candidate for candidate in groups if compatible(candidate, profile)), None)
        if group is None:
            group = Group()
            groups.append(group)
        group.services += [name for name in profile.services if name not in group.services]
        for name, value in profile.env:
            if group.env.get(name, value) != value:
                raise SelectionError("Conflicting %s values in one group." % name)
            group.env[name] = value
        group.only.append(item.identifier)
        if item.method:
            group.named.append(item.identifier)
        elif item.test_class:
            group.skip += [key + "/" + name for name in profile.staged if key + "/" + name not in group.skip]
        group.tour = group.tour or profile.tour
        if key not in group.keys:
            group.keys.append(key)
    return groups


def test_runner_env(group, values):
    """The TEST_RUNNER_ variables for a group, filled from values."""
    return {"TEST_RUNNER_" + name: value.format(**values) for name, value in group.env.items()}


# ---------------------------------------------------------------- media

def media_paths(media_root):
    media_root = Path(media_root)
    return {
        "tracks": media_root / "reel-tvos-fixture-tracks",
        "silent": media_root / "reel-tvos-fixture-silent",
        "multiaudio_source": media_root / "reel-tvos-fixture-multiaudio-source",
        "multiaudio": media_root / "reel-tvos-fixture-multiaudio",
        "library_manifest": media_root / "library-media.json",
    }


def media_commands(kind, paths, python=sys.executable):
    apple, tv = ROOT / "apps/apple/qa", ROOT / "apps/tvos/qa"
    if kind == "ios":
        return [[python, str(apple / "prepare_synthetic_fixtures.py")]]
    if kind == "tracks":
        return [[python, str(tv / "prepare-track-fixtures.py"), "--output", str(paths["tracks"])],
                [python, str(tv / "verify-track-media.py"), "--media", str(paths["tracks"])]]
    if kind == "silent":
        return [[python, str(tv / "prepare-fixtures.py"), "--silent", "--output", str(paths["silent"])]]
    if kind == "multiaudio":
        return [[python, str(tv / "prepare-multiaudio-fixtures.py"), "--output", str(paths["multiaudio_source"])],
                [python, str(tv / "verify-multiaudio-media.py"), "--media", str(paths["multiaudio_source"])],
                [python, str(tv / "prepare-multiaudio-local.py"), "--input", str(paths["multiaudio_source"]), "--output", str(paths["multiaudio"])]]
    return []


def write_library_manifest(media, manifest):
    """The sealed inventory run-library-fixture.py checks before it serves.

    Its root must be the resolved media path, because the fixture compares it
    with --media after resolving symbolic links (macOS temporary folders)."""
    media = Path(media).resolve(strict=True)
    files = {}
    for path in sorted(media.rglob("*")):
        if path.is_symlink():
            raise FixtureError("Fixture media must not contain links: " + str(path))
        if path.is_file():
            files[path.relative_to(media).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    for required in ("sample.mp4", "hls/index.m3u8"):
        if required not in files:
            raise FixtureError("Fixture media is missing " + required)
    Path(manifest).write_text(json.dumps({"root": str(media), "files": files}, indent=2) + "\n")


def prepare_media(kinds, media_root, logs, runner=subprocess.run, say=print):
    """Generate the media the fixtures need, in dependency order."""
    paths = media_paths(media_root)
    wanted = set(kinds) | ({"tracks"} if "library_manifest" in kinds else set())
    order = [kind for kind in ("ios", "tracks", "silent", "multiaudio", "library_manifest") if kind in wanted]
    for kind in order:
        say("Preparing %s fixture media" % kind)
        if kind == "library_manifest":
            write_library_manifest(paths["tracks"], paths["library_manifest"])
            continue
        log_path = Path(logs) / ("media-%s.log" % kind)
        with open(log_path, "ab") as log:
            for command in media_commands(kind, paths):
                completed = runner(command, cwd=str(ROOT), stdout=log, stderr=subprocess.STDOUT, env=child_env())
                if completed.returncode != 0:
                    raise FixtureError("Preparing %s media failed (%s exited %d). Last output:\n%s" % (
                        kind, Path(command[1]).name, completed.returncode, tail(log_path)))
    return paths


# ---------------------------------------------------------------- processes

def child_env(extra=None):
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONUNBUFFERED="1")
    env.update(extra or {})
    return env


def tail(path, lines=40):
    try:
        return "\n".join(Path(path).read_text(errors="replace").splitlines()[-lines:])
    except OSError:
        return "(no output)"


def port_free(port, kind=socket.SOCK_STREAM):
    """True when 127.0.0.1:port can be bound the way the fixtures bind it."""
    with socket.socket(socket.AF_INET, kind) as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


def busy_ports(service_names, check=port_free):
    busy = []
    for name in service_names:
        service = SERVICES[name]
        if not check(service.port):
            busy.append("%d (TCP, %s)" % (service.port, name))
        for port in service.udp:
            if not check(port, socket.SOCK_DGRAM):
                busy.append("%d (UDP, %s)" % (port, name))
    return busy


def listener_pids(port, runner=subprocess.run):
    """PIDs listening on a TCP port, or None when lsof is unavailable."""
    if not shutil.which("lsof"):
        return None
    completed = runner(["lsof", "-nP", "-a", "-iTCP:%d" % port, "-sTCP:LISTEN", "-t"], capture_output=True, text=True)
    if completed.returncode not in (0, 1):
        return None
    return {int(pid) for pid in completed.stdout.split() if pid.isdigit()}


OPENER = build_opener(ProxyHandler({}))


def fetch_json(url, headers=None, timeout=2):
    request = Request(url, headers=headers or {})
    with OPENER.open(request, timeout=timeout) as response:
        return response.status, json.loads(response.read(65536) or b"null")


@dataclass
class Running:
    service: Service
    process: subprocess.Popen
    log: Path
    handle: object = None


class Fixtures:
    """Starts, checks and stops the fixture servers of one group.

    Only processes started here are ever signalled. Each is started in its
    own session so a stop reaches anything it spawned."""

    def __init__(self, paths, owners, logs, record=None, say=print):
        self.paths = {name: str(path) for name, path in paths.items()}
        self.owners = owners
        self.logs = Path(logs)
        self.record = record or (lambda event, value: None)
        self.say = say
        self.running = []

    def command(self, service):
        return [sys.executable, str(ROOT / service.script)] + [argument.format(**self.paths) for argument in service.args]

    def start(self, names, timeout=90):
        busy = busy_ports(names)
        if busy:
            raise FixtureError("These loopback ports are in use, so fixtures cannot start: %s. Stop whatever holds them and try again." % ", ".join(busy))
        for name in names:
            service = SERVICES[name]
            log = self.logs / ("fixture-%s.log" % name)
            handle = open(log, "ab")
            env = child_env({service.owner: self.owners[service.owner]} if service.owner else None)
            process = subprocess.Popen(self.command(service), cwd=str(ROOT / Path(service.script).parent), env=env,
                                       stdin=subprocess.DEVNULL, stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
            running = Running(service, process, log, handle)
            self.running.append(running)
            self.record("process", {"pid": process.pid, "script": service.script, "name": name})
        for running in list(self.running):
            if running.service.name in names:
                self.wait_ready(running, timeout)
                self.say("Fixture %s is ready on 127.0.0.1:%d (pid %d)" % (running.service.name, running.service.port, running.process.pid))

    def wait_ready(self, running, timeout):
        service, process = running.service, running.process
        deadline = time.monotonic() + timeout
        last = "no answer yet"
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise FixtureError("Fixture %s exited with status %s before it was ready. Last output:\n%s" % (service.name, process.returncode, tail(running.log)))
            pids = listener_pids(service.port)
            if pids and pids - {process.pid}:
                raise FixtureError("Port %d is held by another process (%s), not fixture %s." % (service.port, ", ".join(map(str, sorted(pids))), service.name))
            listening = process.pid in pids if pids is not None else True
            if listening:
                try:
                    if self.answers(service):
                        return
                    last = "the listener did not prove it belongs to this run"
                except (OSError, URLError, ValueError) as error:
                    last = str(error)
            time.sleep(0.25)
        raise FixtureError("Fixture %s was not ready on port %d after %ds (%s). Last output:\n%s" % (service.name, service.port, timeout, last, tail(running.log)))

    def answers(self, service):
        if not service.identity_path():
            with socket.create_connection(("127.0.0.1", service.port), timeout=1):
                return True
        owner = self.owners[service.owner]
        status, body = fetch_json("http://127.0.0.1:%d%s" % (service.port, service.identity_path()))
        return status == 200 and isinstance(body, dict) and body.get("kind") == service.identity_kind() \
            and body.get("owner") == owner and body.get("port") == service.port

    def check_alive(self):
        dead = [running for running in self.running if running.process.poll() is not None]
        if dead:
            raise FixtureError("; ".join("Fixture %s stopped with status %s. Last output:\n%s" % (
                running.service.name, running.process.returncode, tail(running.log)) for running in dead))

    def stop(self):
        problems = []
        for running in reversed(self.running):
            try:
                stop_process(running.process)
                self.record("process-stopped", {"pid": running.process.pid})
            except (OSError, subprocess.SubprocessError) as error:
                problems.append("%s: %s" % (running.service.name, error))
            finally:
                if running.handle:
                    running.handle.close()
        self.running = []
        return problems


def stop_process(process, timeout=8):
    """Stop a child started with start_new_session, and its session."""
    if process.poll() is not None:
        return
    for sig, wait in ((signal.SIGTERM, timeout), (signal.SIGKILL, 5)):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            break
        try:
            process.wait(timeout=wait)
            return
        except subprocess.TimeoutExpired:
            continue
    process.wait(timeout=5)


def new_owners():
    """Fresh noncredential owner tokens for this run's fixtures."""
    return {QA_OWNER: secrets.token_hex(24), PARITY_OWNER: secrets.token_hex(24)}


# ---------------------------------------------------------------- self check

def self_check(platform, output_dir, say=print):
    """Generate media, then start and stop every group of one platform."""
    output_dir = Path(output_dir).resolve()
    if output_dir.exists() and any(output_dir.iterdir()):
        raise FixtureError("Use a new or empty output directory.")
    if output_dir == ROOT or ROOT in output_dir.parents:
        raise FixtureError("Use an output directory outside the repository.")
    logs, media = output_dir / "logs", output_dir / "media"
    logs.mkdir(parents=True)
    media.mkdir()
    tests = catalog()
    selections = resolve(platform, "test", [], tests=tests)[0]
    for device in (("tv",) if platform == "tvos" else ("iphone", "ipad")):
        selections += [item for item in resolve(platform, "ui", [], device=device, tests=tests)[0] if item not in selections]
    supported = sorted(key for key in PROFILES if key.startswith(BUNDLES[(platform, "ui")][0] + "/"))
    selections += [Selected(key, *key.split("/")) for key in supported if Selected(key, *key.split("/")) not in selections]
    groups = plan(selections, tests)
    kinds = []
    for group in groups:
        kinds += [kind for kind in group.media() if kind not in kinds]
    paths = prepare_media(kinds, media, logs, say=say)
    owners = new_owners()
    for index, group in enumerate(groups, 1):
        say("Group %d: %s" % (index, ", ".join(group.keys)))
        fixtures = Fixtures(paths, owners, logs, say=say)
        try:
            fixtures.start(group.services)
            fixtures.check_alive()
        finally:
            problems = fixtures.stop()
        if problems:
            raise FixtureError("Stopping fixtures failed: " + "; ".join(problems))
        busy = busy_ports(group.services)
        if busy:
            raise FixtureError("Ports still busy after stopping: " + ", ".join(busy))
    say("All %d fixture groups started, answered as their owner and stopped." % len(groups))


def main(argv):
    parser = argparse.ArgumentParser(description=(__doc__ or "").partition("\n")[0])
    parser.add_argument("platform", choices=("ios", "tvos"))
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        self_check(args.platform, args.output_dir)
    except (FixtureError, SelectionError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
