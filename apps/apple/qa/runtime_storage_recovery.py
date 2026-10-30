#!/usr/bin/env python3
"""Native storage recovery fault injection, restricted to a disposable Reel QA simulator.

The original manifest is restored before each recovery action and on failure.
Existing media is backed up privately and verified on success and failure.
The selected native test uses only loopback accounts.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request
import uuid

APP_ID = "app.reelclient.ios"
ROOT = Path(__file__).resolve().parent.parent
ORIGIN = "http://127.0.0.1:18766"
AUTH = 'MediaBrowser Token="fixture-storage-coordinator"'


def fixture(values=None):
    request = urllib.request.Request(ORIGIN + ("/qa/hub-state" if values is None else "/qa/hub-control"),
                                    data=None if values is None else json.dumps(values).encode(),
                                    headers={"Authorization": AUTH, "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=3) as response:
        return json.load(response)


def valid_filename(value):
    if not isinstance(value, str) or value.count(".") != 1: return False
    stem, extension = value.split(".")
    try: uuid.UUID(stem)
    except ValueError: return False
    return bool(extension) and len(extension) <= 10 and extension.isascii() and extension.isalnum()


def fresh_artifacts(prefix):
    candidate = Path(prefix)
    if candidate.is_symlink(): raise ValueError("Refusing a redirected QA result prefix.")
    result = candidate.resolve()
    if not result.is_relative_to(Path("/tmp").resolve()):
        raise ValueError("QA result artifacts must stay in /tmp.")
    for suffix in (".xcresult", ".log", ".json", ".cleanup.json", ".private-backup"):
        artifact = Path(str(result) + suffix)
        if artifact.exists() or artifact.is_symlink():
            raise ValueError("Choose a fresh result prefix; existing QA artifacts are preserved: " + artifact.name)
    return result


def exclusive_output(path):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    return os.fdopen(descriptor, "wb")


def write_evidence(path, values):
    with exclusive_output(path) as output:
        output.write((json.dumps(values, indent=2) + "\n").encode())


def shutdown_and_cleanup(process, cleanup):
    shutdown_error = None
    try:
        if process is not None and process.poll() is None:
            process.terminate()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    except BaseException as error:
        shutdown_error = error
    finally:
        cleanup(shutdown_error)
    if shutdown_error is not None: raise shutdown_error


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True, help="UUID of an available disposable simulator named Reel QA or Reel QA …")
    parser.add_argument("--developer-dir", default=os.environ.get("DEVELOPER_DIR"))
    parser.add_argument("--result-prefix", default="/tmp/reel-qa-storage-runtime")
    args = parser.parse_args()
    if not args.developer_dir: parser.error("Set DEVELOPER_DIR or --developer-dir.")
    developer = Path(args.developer_dir).resolve()
    simctl = developer / "usr/bin/simctl"
    xcodebuild = developer / "usr/bin/xcodebuild"
    try: qa_simulator = str(uuid.UUID(args.simulator)).upper()
    except ValueError: parser.error("--simulator must be a simulator UUID.")
    inventory = json.loads(subprocess.check_output([str(simctl), "list", "devices", "available", "--json"], text=True))
    matches = [device for group in inventory.get("devices", {}).values() for device in group
               if device.get("udid", "").upper() == qa_simulator and device.get("isAvailable") is True]
    if len(matches) != 1 or not (matches[0].get("name") == "Reel QA" or matches[0].get("name", "").startswith("Reel QA ")):
        parser.error("Refusing anything except an available disposable simulator named Reel QA or Reel QA …")
    simulator_name = matches[0]["name"]
    try: result = fresh_artifacts(args.result_prefix)
    except ValueError as error: parser.error(str(error))
    bundle = Path(str(result) + ".xcresult")
    subprocess.run([str(simctl), "terminate", qa_simulator, APP_ID], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    expected = (Path.home() / "Library/Developer/CoreSimulator/Devices" / qa_simulator / "data/Containers/Data/Application").resolve()
    containers = []

    def checked_location():
        current = Path(subprocess.check_output([str(simctl), "get_app_container", qa_simulator, APP_ID, "data"], text=True).strip()).resolve()
        if current.parent != expected:
            raise RuntimeError("Refusing a container outside the selected disposable simulator application directory.")
        uuid.UUID(current.name)
        media = current / "Library/Application Support/MediaHub"
        if media.is_symlink() or not media.resolve().is_relative_to(current):
            raise RuntimeError("Refusing a redirected MediaHub directory.")
        media.mkdir(parents=True, exist_ok=True)
        index = media / "files.json"
        if index.is_symlink(): raise RuntimeError("Refusing a redirected manifest.")
        if str(current) not in containers: containers.append(str(current))
        return current, media, index

    container, directory, manifest = checked_location()
    original = manifest.read_bytes() if manifest.exists() else None
    records = json.loads(original) if original is not None else []
    if not isinstance(records, list): raise RuntimeError("The pre-test QA manifest is already invalid; no fault was injected.")
    preserved = {}
    backup_directory = Path(str(result) + ".private-backup")
    backup_directory.mkdir(mode=0o700)
    backup_directory.chmod(0o700)
    for record in records:
        name = record.get("filename")
        if not valid_filename(name): raise RuntimeError("The pre-test QA manifest contains an invalid filename.")
        file = directory / name
        if file.is_symlink(): raise RuntimeError("Refusing a redirected media file.")
        if file.exists():
            content = file.read_bytes()
            preserved[name] = hashlib.sha256(content).hexdigest()
            copy = backup_directory / name
            copy.write_bytes(content); copy.chmod(0o600)
    backup = backup_directory / "original-manifest"
    if original is not None:
        backup.write_bytes(original); backup.chmod(0o600)
    success = False
    process = None
    environment = dict(os.environ, DEVELOPER_DIR=str(developer))

    def refresh_location():
        nonlocal container, directory, manifest
        container, directory, manifest = checked_location()

    def restore():
        refresh_location()
        if original is None: manifest.unlink(missing_ok=True)
        else: manifest.write_bytes(original)

    def inject():
        refresh_location()
        manifest.write_bytes(b"{native-qa-corrupt-manifest")

    try:
        fixture({"reset": True, "storagePhase": 0, "storageRepairRequested": True})
        inject()
        command = [str(xcodebuild), "-project", "Reel.xcodeproj", "-scheme", "Reel", "-configuration", "Debug",
                   "-destination", "platform=iOS Simulator,id=" + qa_simulator, "-derivedDataPath", "build-27-1",
                   "-resultBundlePath", str(bundle), "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-",
                   "-only-testing:ReelUITests/NativeStorageUITests/testCorruptManifestRecoveryThroughSavedAndTransferControls", "test"]
        deadline = time.monotonic() + 240
        handled = set()
        with exclusive_output(Path(str(result) + ".log")) as output:
            process = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=output, stderr=subprocess.STDOUT)
            while process.poll() is None:
                if time.monotonic() > deadline: raise TimeoutError("Native storage journey exceeded its bounded QA deadline.")
                phase = fixture()["mode"].get("storagePhase", 0)
                if phase == 1 and phase not in handled:
                    restore(); fixture({"storagePhase": 2}); handled.add(phase)
                    print("Restored original QA manifest for generic storage recovery.", flush=True)
                elif phase == 3 and phase not in handled:
                    inject(); fixture({"storagePhase": 4}); handled.add(phase)
                    print("Injected the second QA-only fault after the app terminated.", flush=True)
                elif phase == 5 and phase not in handled:
                    restore(); fixture({"storagePhase": 6}); handled.add(phase)
                    print("Restored original QA manifest for transfer-row recovery.", flush=True)
                time.sleep(0.1)
        if process.returncode != 0: raise RuntimeError("The selected native storage test failed; inspect its result bundle.")
        summary = json.loads(subprocess.check_output([str(developer / "usr/bin/xcresulttool"), "get", "test-results", "summary", "--path", str(bundle)], env=environment, text=True))
        if summary.get("totalTestCount") != 1 or summary.get("passedTests") != 1 or summary.get("failedTests") != 0 or summary.get("skippedTests") != 0:
            raise RuntimeError("The storage journey did not execute and pass exactly one native test.")
        if fixture()["mode"].get("storagePhase") != 7:
            raise RuntimeError("The native test did not complete its final storage handshake.")
        refresh_location()
        final = json.loads(manifest.read_bytes())
        final_names = {entry.get("filename") for entry in final}
        for name, digest in preserved.items():
            if name not in final_names or hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest:
                raise RuntimeError("An existing QA media file was not preserved: " + name)
        evidence = {"simulator": qa_simulator, "simulator_name": simulator_name, "container": str(container), "result_bundle": str(bundle), "native_tests_passed": 1,
                    "preserved_media_files": len(preserved), "manifest_sha256_before": hashlib.sha256(original or b"").hexdigest(),
                    "manifest_sha256_after": hashlib.sha256(manifest.read_bytes()).hexdigest(), "completed_phases": sorted(handled), "validated_containers": containers}
        write_evidence(Path(str(result) + ".json"), evidence)
        success = True
        print(json.dumps(evidence), flush=True)
    finally:
        def restore_and_verify(shutdown_error):
            cleanup = {"simulator": qa_simulator, "simulator_name": simulator_name, "success": success and shutdown_error is None,
                       "original_manifest_restored": False, "preserved_media_verified": False, "restored_media_files": [], "stop_errors": []}
            if shutdown_error is not None:
                cleanup["shutdown_error"] = type(shutdown_error).__name__ + ": " + str(shutdown_error)
            try:
                targets = [APP_ID] if cleanup["success"] else ["app.reelclient.ios.uitests.xctrunner", APP_ID]
                for target in targets:
                    try:
                        subprocess.run([str(simctl), "terminate", qa_simulator, target], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                    except BaseException as error:
                        cleanup["stop_errors"].append(type(error).__name__ + ": " + str(error))
                if cleanup["stop_errors"]: cleanup["success"] = False
                if not cleanup["success"]:
                    restore()
                    cleanup["original_manifest_restored"] = (manifest.read_bytes() if manifest.exists() else None) == original
                    if not cleanup["original_manifest_restored"]:
                        raise RuntimeError("QA failure cleanup did not restore the original manifest.")
                    for name, digest in preserved.items():
                        file = directory / name
                        if file.is_symlink(): raise RuntimeError("Refusing redirected media during QA cleanup.")
                        if not file.exists() or hashlib.sha256(file.read_bytes()).hexdigest() != digest:
                            file.write_bytes((backup_directory / name).read_bytes())
                            cleanup["restored_media_files"].append(name)
                else:
                    refresh_location()
                cleanup["preserved_media_verified"] = all(
                    (directory / name).exists() and not (directory / name).is_symlink()
                    and hashlib.sha256((directory / name).read_bytes()).hexdigest() == digest
                    for name, digest in preserved.items())
                if not cleanup["preserved_media_verified"]:
                    raise RuntimeError("QA cleanup could not verify preserved media files.")
                if cleanup["stop_errors"]: raise RuntimeError("QA cleanup restored data but could not stop every owned process.")
            finally:
                cleanup["validated_containers"] = containers
                try: fixture({"storageRepairRequested": False})
                except BaseException as error:
                    cleanup["disarm_error"] = type(error).__name__ + ": " + str(error)
                    raise
                finally:
                    write_evidence(Path(str(result) + ".cleanup.json"), cleanup)
        shutdown_and_cleanup(process, restore_and_verify)


if __name__ == "__main__":
    run()
