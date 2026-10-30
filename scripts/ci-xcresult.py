#!/usr/bin/env python3
"""Print what an Xcode test run did, and why tests failed, from its result bundle.

Usage: ci-xcresult.py RESULT.xcresult [--attachments DIR] [--max-lines N]

Reads the bundle with `xcrun xcresulttool get test-results` (Xcode 16 and
later) and falls back to the legacy JSON format on older tools. For each
failing test it prints the identifier, every failure message with its file
and line, and the text attachments the test added (for example a UI
hierarchy), cut to a fixed number of lines. Screenshots are exported to the
attachments folder and listed by path.
"""
import argparse
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit

LOCATION = re.compile(r"^(?P<file>[^\s:][^:\n]*?\.(?:swift|m|mm|c|h)):(?P<line>\d+):\s*(?P<message>.*)$", re.S)
TEXT_SUFFIXES = {".txt", ".text", ".log", ".json", ".xml", ".md", ".csv", ".plist"}
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".heic", ".gif", ".tif", ".tiff"}
BUNDLE_TYPES = {"Unit test bundle", "UI test bundle"}
MAX_TEXT_ATTACHMENTS = 4


@dataclass
class Failure:
    message: str
    file: str = ""
    line: int = 0

    def location(self):
        return "%s:%d" % (self.file, self.line) if self.file else ""


@dataclass
class Case:
    identifier: str
    result: str
    failures: list = field(default_factory=list)
    note: str = ""


@dataclass
class Attachment:
    test: str
    path: Path
    name: str
    failure: bool = False


@dataclass
class Report:
    cases: list
    legacy: bool = False
    totals: dict = field(default_factory=dict)
    attachments: list = field(default_factory=list)
    problems: list = field(default_factory=list)

    def count(self, result):
        if self.legacy:
            return self.totals.get(result, 0)
        return sum(1 for case in self.cases if case.result == result)

    def total(self):
        return self.totals.get("total", 0) if self.legacy else len(self.cases)


def parse_failure(text):
    """Split an XCTest failure line of the form File.swift:12: message."""
    text = (text or "").strip()
    match = LOCATION.match(text)
    if not match:
        return Failure(text)
    return Failure(match.group("message").strip(), match.group("file"), int(match.group("line")))


def strip_call(name):
    return name[:-2] if name.endswith("()") else name


def identity(node, bundle, suite):
    """Bundle/Class/method for a Test Case node."""
    url = urlsplit(node.get("nodeIdentifierURL") or "")
    parts = [unquote(part) for part in url.path.split("/") if part]
    if url.scheme == "test" and len(parts) >= 3:
        return "/".join(parts[-3:-1] + [strip_call(parts[-1])])
    pieces = [piece for piece in (node.get("nodeIdentifier") or node.get("name") or "").split("/") if piece]
    method = strip_call(pieces[-1]) if pieces else "unknown"
    owner = pieces[-2] if len(pieces) > 1 else suite or "unknown"
    return "/".join([bundle or "unknown", owner, method])


def descendants(node):
    for child in node.get("children") or []:
        yield child
        yield from descendants(child)


def cases_from_tree(tree):
    cases = []

    def visit(node, bundle, suite):
        kind = node.get("nodeType")
        if kind in BUNDLE_TYPES:
            bundle = node.get("name") or bundle
        elif kind == "Test Suite":
            suite = node.get("name") or suite
        if kind == "Test Case":
            case = Case(identity(node, bundle, suite), node.get("result") or "unknown")
            for child in descendants(node):
                child_kind = child.get("nodeType") or ""
                if child_kind == "Failure Message":
                    case.failures.append(parse_failure(child.get("name")))
                elif not case.note and "Message" in child_kind:
                    case.note = (child.get("name") or "").strip()
            if case.result == "Skipped" and not case.note and case.failures:
                case.note = case.failures.pop(0).message
            cases.append(case)
            return
        for child in node.get("children") or []:
            visit(child, bundle, suite)

    for node in tree.get("testNodes") or []:
        visit(node, "", "")
    return cases


def legacy_value(node, *keys):
    for key in keys:
        if not isinstance(node, dict):
            return None
        node = node.get(key)
    if isinstance(node, dict) and "_value" in node:
        return node["_value"]
    return node


def legacy_location(url):
    """file:///path/File.swift#StartingLineNumber=41&... -> (File.swift, 42)."""
    if not url:
        return "", 0
    parts = urlsplit(url)
    fields = dict(item.split("=", 1) for item in parts.fragment.split("&") if "=" in item)
    line = fields.get("StartingLineNumber") or fields.get("EndingLineNumber") or ""
    return os.path.basename(unquote(parts.path)), int(line) + 1 if line.isdigit() else 0


def cases_from_legacy(document):
    """Failures and counts from `xcresulttool get --legacy --format json`."""
    failures = {}
    for action in legacy_value(document, "actions", "_values") or []:
        summaries = legacy_value(action, "actionResult", "issues", "testFailureSummaries", "_values") or []
        for summary in summaries:
            name = legacy_value(summary, "testCaseName") or "unknown"
            name = name.strip("-[]").replace(" ", "/").replace(".", "/")
            file, line = legacy_location(legacy_value(summary, "documentLocationInCreatingWorkspace", "url"))
            failures.setdefault(strip_call(name), []).append(Failure((legacy_value(summary, "message") or "").strip(), file, line))
    metrics = legacy_value(document, "metrics") or {}
    totals = {
        "total": int(legacy_value(metrics, "testsCount") or 0),
        "Failed": int(legacy_value(metrics, "testsFailedCount") or 0),
        "Skipped": int(legacy_value(metrics, "testsSkippedCount") or 0),
    }
    totals["Passed"] = max(totals["total"] - totals["Failed"] - totals["Skipped"], 0)
    cases = [Case(name, "Failed", items) for name, items in failures.items()]
    return cases, totals


def last_lines(text, count=3, width=300):
    lines = [line.strip() for line in (text or "").strip().splitlines() if line.strip()]
    return " / ".join(lines[-count:])[-width:] or "no output"


def run_tool(arguments, runner):
    try:
        completed = runner(["xcrun", "xcresulttool"] + arguments, capture_output=True, text=True, timeout=600)
    except (OSError, subprocess.SubprocessError) as error:
        return 1, "", str(error)
    return completed.returncode, completed.stdout, completed.stderr


def read(bundle, runner=subprocess.run):
    """Return a Report for a result bundle; never raises for unreadable bundles."""
    bundle = str(bundle)
    code, output, error = run_tool(["get", "test-results", "tests", "--path", bundle], runner)
    if code == 0:
        try:
            return Report(cases_from_tree(json.loads(output)))
        except ValueError as problem:
            error = str(problem)
    problems = ["xcresulttool get test-results failed: " + last_lines(error)]
    for arguments in (["get", "--legacy", "--format", "json", "--path", bundle], ["get", "--format", "json", "--path", bundle]):
        code, output, legacy_error = run_tool(arguments, runner)
        if code != 0:
            problems.append("xcresulttool " + " ".join(arguments[:2]) + " failed: " + last_lines(legacy_error))
            continue
        try:
            cases, totals = cases_from_legacy(json.loads(output))
        except ValueError as problem:
            problems.append("Legacy result was not JSON: " + str(problem))
            continue
        return Report(cases, legacy=True, totals=totals, problems=problems)
    return Report([], legacy=True, totals={"total": 0}, problems=problems)


def manifest_test(entry):
    url = urlsplit(entry.get("testIdentifierURL") or "")
    parts = [unquote(part) for part in url.path.split("/") if part]
    if url.scheme == "test" and len(parts) >= 3:
        return "/".join(parts[-3:-1] + [strip_call(parts[-1])])
    return strip_call(entry.get("testIdentifier") or "")


def export_attachments(bundle, destination, runner=subprocess.run):
    """Export every attachment once; return Attachment rows from the manifest."""
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    code, _, error = run_tool(["export", "attachments", "--path", str(bundle), "--output-path", str(destination)], runner)
    manifest = destination / "manifest.json"
    if code != 0 or not manifest.is_file():
        return [], ["Attachments could not be exported: " + (last_lines(error) if code else "no manifest")]
    try:
        entries = json.loads(manifest.read_text())
    except ValueError as problem:
        return [], ["Attachment manifest was not JSON: " + str(problem)]
    rows = []
    for entry in entries if isinstance(entries, list) else []:
        test = manifest_test(entry)
        for item in entry.get("attachments") or []:
            exported = item.get("exportedFileName")
            if not exported:
                continue
            rows.append(Attachment(test, destination / exported, item.get("suggestedHumanReadableName") or exported, bool(item.get("isAssociatedWithFailure"))))
    return rows, []


def belongs(attachment_test, case_identifier):
    """Manifest identifiers may omit the bundle; compare the trailing parts."""
    if not attachment_test:
        return False
    return case_identifier == attachment_test or case_identifier.endswith("/" + attachment_test)


def is_text(path):
    suffix = path.suffix.lower()
    if suffix in TEXT_SUFFIXES:
        return True
    if suffix in IMAGE_SUFFIXES:
        return False
    try:
        sample = path.read_bytes()[:4096]
    except OSError:
        return False
    if b"\0" in sample:
        return False
    try:
        sample.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return True


def escape_data(text):
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def escape_property(text):
    return escape_data(text).replace(":", "%3A").replace(",", "%2C")


def annotation(case, failure, sources):
    path = sources.get(failure.file, "") if failure.file else ""
    properties = ["title=" + escape_property(case.identifier)]
    if path:
        properties.insert(0, "file=" + escape_property(path))
        if failure.line:
            properties.insert(1, "line=%d" % failure.line)
    return "::error " + ",".join(properties) + "::" + escape_data(failure.message or "Test failed")


def indent(text, prefix):
    return "\n".join(prefix + line for line in (text or "").splitlines() or [""])


def render(report, *, max_lines=300, sources=None, annotate=False, base=None):
    """Plain text for the job log. Every line is indented or prefixed so test
    output can never be read as a workflow command."""
    sources = sources or {}
    lines = []
    passed, failed, skipped = report.count("Passed"), report.count("Failed"), report.count("Skipped")
    expected = report.count("Expected Failure")
    summary = "%d passed, %d failed, %d skipped" % (passed, failed, skipped)
    if expected:
        summary += ", %d expected failures" % expected
    lines.append("Tests: %s (%d run)" % (summary, report.total()))
    if report.legacy:
        lines.append("  (read with the legacy result format; test identifiers may be partial)")
    for problem in report.problems:
        lines.append("  Note: " + problem)
    for case in [case for case in report.cases if case.result == "Failed"]:
        lines.append("")
        lines.append("FAILED " + case.identifier)
        for failure in case.failures or [Failure("No failure message was recorded.")]:
            where = failure.location()
            lines.append(indent((where + ": " if where else "") + failure.message, "    "))
        mine = [item for item in report.attachments if belongs(item.test, case.identifier)]
        texts = [item for item in mine if is_text(item.path)]
        for item in texts[:MAX_TEXT_ATTACHMENTS]:
            try:
                body = item.path.read_text(errors="replace").splitlines()
            except OSError as error:
                lines.append("    Attachment %s could not be read: %s" % (item.name, error))
                continue
            shown = body[:max_lines]
            cut = " (first %d of %d lines)" % (len(shown), len(body)) if len(body) > len(shown) else " (%d lines)" % len(body)
            lines.append("    Attachment: " + item.name + cut)
            lines.extend("    | " + line for line in shown)
        if len(texts) > MAX_TEXT_ATTACHMENTS:
            lines.append("    %d more text attachments are in the result bundle." % (len(texts) - MAX_TEXT_ATTACHMENTS))
        for item in mine:
            if not is_text(item.path):
                shown = os.path.relpath(item.path, base) if base else str(item.path)
                lines.append("    Screenshot: " + shown + (" (at failure)" if item.failure else ""))
    for case in [case for case in report.cases if case.result == "Skipped"]:
        lines.append("SKIPPED " + case.identifier + (": " + case.note if case.note else ""))
    if annotate:
        for case in [case for case in report.cases if case.result == "Failed"]:
            for failure in case.failures[:3] or [Failure("Test failed")]:
                lines.append(annotation(case, failure, sources))
    return "\n".join(lines)


def matches(selection, identifier):
    return identifier == selection or identifier.startswith(selection + "/")


def problems(report, selected, *, named_methods=(), allow_skips=True):
    """Reasons a run must count as failed, beyond xcodebuild's exit status."""
    if report.total() == 0:
        return list(report.problems) + ["No tests ran. Check the selected test identifiers."]
    reasons = []
    if report.count("Failed"):
        reasons.append("%d of %d tests failed." % (report.count("Failed"), report.total()))
    if not report.legacy:
        missing = [item for item in selected if not any(matches(item, case.identifier) for case in report.cases)]
        if missing:
            reasons.append("Selected but not run: " + ", ".join(missing))
        skipped = [case.identifier for case in report.cases if case.result == "Skipped"]
        if named_methods:
            named_skips = [item for item in skipped if item in set(named_methods)]
            if named_skips:
                reasons.append("Selected tests were skipped: " + ", ".join(named_skips))
        if not allow_skips and skipped and len(skipped) == len(report.cases):
            reasons.append("Every selected test was skipped.")
    return reasons


def main(argv):
    parser = argparse.ArgumentParser(description=(__doc__ or "").partition("\n")[0])
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--attachments", type=Path, help="Folder for exported attachments")
    parser.add_argument("--max-lines", type=int, default=300)
    args = parser.parse_args(argv)
    report = read(args.bundle)
    if args.attachments:
        report.attachments, notes = export_attachments(args.bundle, args.attachments)
        report.problems.extend(notes)
    print(render(report, max_lines=args.max_lines))
    return 1 if report.count("Failed") or report.total() == 0 else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
