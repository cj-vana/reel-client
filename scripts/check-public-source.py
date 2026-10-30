#!/usr/bin/env python3
"""Check public packaging boundaries without reading any local account or keychain."""
from pathlib import Path
import ipaddress
import re
import math
from collections import Counter
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_DIRS = {
    ".git", ".cache", "node_modules", "build", "dist", "dist-tv",
    "webos-package", "DerivedData",
    "__pycache__", "artifacts", "xcuserdata", "playwright-report", "test-results",
}


def artifact_path(relative):
    """Classify a publication file; build-* is a directory convention."""
    return any(
        part in ARTIFACT_DIRS
        or part.endswith((".xcresult", ".xcarchive", ".app", ".dSYM", ".ipk", ".wgt", ".zip", ".asar", ".dmg", ".msi", ".exe"))
        for part in relative.parts
    ) or any(part.startswith("build-") for part in relative.parts[:-1])


def publication_paths(root):
    """Include tracked files even when ignored, plus unignored new source."""
    inventory = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, check=False,
    )
    if inventory.returncode == 0 and Path(inventory.stdout.strip()).resolve() == root.resolve():
        names = subprocess.check_output([
            "git", "-C", str(root), "ls-files", "--cached", "--others",
            "--exclude-standard", "-z",
        ]).decode("utf-8", errors="surrogateescape").split("\0")
        return sorted({root / name for name in names if name})
    # Downloaded source archives have no index or generated local fixtures.
    return sorted(path for path in root.rglob("*") if ".git" not in path.relative_to(root).parts)


# Report only the location and category: diagnostics must never repeat a secret.
PRIVATE_KEY = re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----")
PROVIDER_TOKEN = re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9_]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[A-Z0-9]{16}|sk-(?:proj-)?[A-Za-z0-9_-]{30,})\b")
HOME_PATH = re.compile(r"(?:/Users/|/home/|[A-Za-z]:[\\/]+Users[\\/]+)([A-Za-z0-9_.-]+)[\\/]+([A-Za-z0-9_.-]+)")
PRIVATE_TEMP = re.compile(r"/private/(?:tmp|var/folders)/[A-Za-z0-9_.-]+")
SECRET_ASSIGNMENT = re.compile(r"(?i)(?:[\"']?)(?:access[_-]?token|api[_-]?key|token|password|client[_-]?secret)[\"']?\s*[:=]\s*[\"']([A-Za-z0-9_./+=-]{24,})[\"']")
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})\b")
PUBLIC_EMAIL_DOMAINS = {"example.com", "example.org", "example.net", "users.noreply.github.com", "fixture.example", "media.example"}
EXAMPLE_USERS = {"example", "user", "username", "test", "test-user", "fixture"}
JELLYFIN_USER_ROUTES = {"Items", "Policy", "Password", "Configuration", "PlayedItems", "FavoriteItems", "Images"}
# Host addresses only: a CIDR block such as the list below names a range, not a machine.
IPV4 = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d./])")
LOCAL_NETWORKS = tuple(ipaddress.ip_network(net) for net in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16"))
# Tests and docs use addresses from these small blocks; any other private address is likely someone's real network.
TEST_NETWORKS = tuple(ipaddress.ip_network(net) for net in ("192.168.1.0/24", "10.0.0.0/29", "172.16.0.0/29", "100.64.0.0/28"))
LOCAL_STATE_NAMES = {"accounts.json", "connections.json", "cookies.sqlite", "cookies.sqlite-wal", "login data", "cookies", "preferences.json", "secure-store.json"}


def content_errors(relative, raw):
    findings = []
    for label, pattern in (("Private key", PRIVATE_KEY), ("Credential token", PROVIDER_TOKEN)):
        for match in pattern.finditer(raw):
            line = raw.count(b"\n", 0, match.start()) + 1
            findings.append(f"{label} must not be published: {relative}:{line}")
    # Text files, including JSON/YAML settings and generated project files.
    if b"\0" in raw[:8192]:
        return findings
    for number, line in enumerate(raw.decode("utf-8", errors="replace").splitlines(), 1):
        for match in HOME_PATH.finditer(line):
            user, route = match.groups()
            api_example = match.group(0).startswith("/Users/") and (user == "Me" or user.startswith("fixture-")) and route in JELLYFIN_USER_ROUTES
            if user.lower() not in EXAMPLE_USERS and not api_example:
                findings.append(f"Personal home path must not be published: {relative}:{number}")
                break
        for match in EMAIL.finditer(line):
            domain = match.group(1).lower()
            # Third-party license texts name their authors; only project files must stay anonymous.
            if domain not in PUBLIC_EMAIL_DOMAINS and not domain.endswith(".example") and "NOTICES" not in str(relative).upper().replace("_", ""):
                findings.append(f"Email address must not be published: {relative}:{number}")
        if PRIVATE_TEMP.search(line):
            findings.append(f"Machine-local temporary path must not be published: {relative}:{number}")
        for match in IPV4.finditer(line):
            try:
                address = ipaddress.ip_address(match.group(0))
            except ValueError:
                continue  # deliberately invalid test input such as an octet above 255
            if any(address in net for net in LOCAL_NETWORKS) and not any(address in net for net in TEST_NETWORKS):
                findings.append(f"Private network address must not be published: {relative}:{number}")
                break
        for match in SECRET_ASSIGNMENT.finditer(line):
            value = match.group(1)
            counts = Counter(value)
            entropy = -sum((count / len(value)) * math.log2(count / len(value)) for count in counts.values())
            if not value.lower().startswith(("fixture-", "synthetic-", "example-")) and entropy >= 3.5:
                findings.append(f"Possible embedded credential must be reviewed: {relative}:{number}")
    return findings


def collect_errors(root):
    errors = []
    apple = root / "apps/apple"
    for path in publication_paths(root):
        relative = path.relative_to(root)
        if path.is_symlink():
            errors.append(f"Symlink needs explicit review: {relative}")
            continue
        if path.is_dir():
            continue
        if not path.is_file():
            errors.append(f"Missing publication file: {relative}")
            continue
        errors.extend(content_errors(relative, path.read_bytes()))
        if path.name.lower() in LOCAL_STATE_NAMES:
            errors.append(f"Local account/browser state must not be published: {relative}")
        if artifact_path(relative):
            errors.append(f"Runtime/build output must not be published: {relative}")
        if path.suffix.lower() in {".p12", ".p8", ".mobileprovision", ".ipa", ".key", ".pem"}:
            errors.append(f"Signing/key material must not be published: {relative}")
        if path.name.startswith(".env") and path.name != ".env.example":
            errors.append(f"Local environment file must not be published: {relative}")
        if relative.parts[:3] == ("apps", "apple", "qa") and path.suffix.lower() in {".jpg", ".jpeg", ".png", ".mp4", ".ts", ".wav", ".pdf"}:
            errors.append(f"Generated fixture output must remain ignored: {relative}")

    for path in publication_paths(root):
        if path.name not in {"project.yml", "project.pbxproj"} or not path.is_file() or path.is_symlink():
            continue
        if re.search(r"(?:DEVELOPMENT_TEAM\s*[:=]|DevelopmentTeam\s*=)\s*[^\s;]+", path.read_text()):
            errors.append(f"Choose signing team locally, not in source: {path.relative_to(root)}")

    tests = apple / "ReelTests/ReelTests.swift"
    if tests.is_file():
        text = tests.read_text()
        helper = re.search(r"func livePreviewAccount\([^)]*\)[^{]*\{(.*?)(?=\n    (?:@|func)|\n\})", text, re.S)
        helper_prefix = helper.group(1).split("SecureAccount.read()", 1)[0] if helper else ""
        helper_gated = 'guard ProcessInfo.processInfo.environment["REEL_LIVE_PREVIEW_TESTS"] == "1" else' in helper_prefix and 'throw XCTSkip' in helper_prefix
        for name in ["testLivePreviewPlaysWithoutChangingHistory", "testLiveTranscoderDiagnostics", "testLiveServerSessionInventory"]:
            match = re.search(r"func " + name + r"\([^)]*\)[^{]*\{(.*?)(?=\n    (?:@|func)|\n\})", text, re.S)
            if not match:
                continue
            body = match.group(1).strip()
            guarded_helper = helper_gated and body.startswith("let account = try livePreviewAccount()") and "SecureAccount.read()" not in body
            inline_guard = 'guard ProcessInfo.processInfo.environment["REEL_LIVE_PREVIEW_TESTS"] == "1" else' in body.split("SecureAccount.read()", 1)[0]
            if not (guarded_helper or inline_guard):
                errors.append(f"Live test must opt in before reading accounts: {name}")

    for required in ["LICENSE", "PRIVACY.md", "SECURITY.md", "THIRD_PARTY.md"]:
        if not (root / required).is_file():
            errors.append(f"Missing public project document: {required}")
    return errors


def main():
    errors = collect_errors(ROOT)
    if errors:
        print("Public source checks failed:\n" + "\n".join("- " + item for item in errors), file=sys.stderr)
        return 1
    print("Public packaging checks passed. This does not replace a manual review for secrets and personal content.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
