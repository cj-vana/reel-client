import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("ci_xcresult", Path(__file__).with_name("ci-xcresult.py"))
ci_xcresult = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci_xcresult)

# Shaped like `xcrun xcresulttool get test-results tests --compact` output.
TREE = {
    "devices": [{"deviceName": "Reel QA Apple TV", "platform": "tvOS Simulator"}],
    "testNodes": [{
        "name": "ReelTV", "nodeType": "Test Plan", "result": "Failed",
        "children": [{
            "name": "ReelTVUITests", "nodeType": "UI test bundle", "result": "Failed",
            "children": [{
                "name": "TVJourneys", "nodeType": "Test Suite", "result": "Failed",
                "children": [
                    {
                        "name": "testRemoteSettingsAccountsPrivacyQualityAndRemovalPersist()",
                        "nodeIdentifier": "TVJourneys/testRemoteSettingsAccountsPrivacyQualityAndRemovalPersist()",
                        "nodeIdentifierURL": "test://com.apple.xcode/ReelTV/ReelTVUITests/TVJourneys/testRemoteSettingsAccountsPrivacyQualityAndRemovalPersist",
                        "nodeType": "Test Case", "result": "Failed", "duration": "41s",
                        "children": [
                            {"name": "TVJourneys.swift:2185: Remote focus could not reach gearshape", "nodeType": "Failure Message", "result": "Failed"},
                            {"name": "TVJourneys.swift:2186: caught error: unavailableControl", "nodeType": "Failure Message", "result": "Failed"},
                        ],
                    },
                    {
                        "name": "testRemoteSignInHomeDetailsAndBack()",
                        "nodeIdentifier": "TVJourneys/testRemoteSignInHomeDetailsAndBack()",
                        "nodeType": "Test Case", "result": "Passed",
                    },
                    {
                        "name": "testRemoteHomeScreenIconFocusLaunchesTheQAApp()",
                        "nodeIdentifierURL": "test://com.apple.xcode/ReelTV/ReelTVUITests/TVJourneys/testRemoteHomeScreenIconFocusLaunchesTheQAApp",
                        "nodeType": "Test Case", "result": "Skipped",
                        "children": [{"name": "Test skipped - Needs the Home screen", "nodeType": "Failure Message"}],
                    },
                ],
            }],
        }],
    }],
}

LEGACY = {
    "metrics": {"testsCount": {"_value": "12"}, "testsFailedCount": {"_value": "1"}, "testsSkippedCount": {"_value": "2"}},
    "actions": {"_values": [{"actionResult": {"issues": {"testFailureSummaries": {"_values": [{
        "testCaseName": {"_value": "RemoteSessionsTests.testRemoteCommand()"},
        "message": {"_value": "XCTAssertEqual failed"},
        "documentLocationInCreatingWorkspace": {"url": {"_value": "file:///src/RemoteSessionsTests.swift#CharacterRangeLen=0&EndingLineNumber=41&StartingLineNumber=41"}},
    }]}}}}]},
}


class Completed:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


class FakeTool:
    """Answers xcresulttool calls from a table keyed by the first arguments."""

    def __init__(self, answers):
        self.answers = answers
        self.calls = []

    def __call__(self, command, **kwargs):
        self.calls.append(command)
        for prefix, answer in self.answers.items():
            if tuple(command[2:2 + len(prefix)]) == prefix:
                return answer(command) if callable(answer) else answer
        return Completed(1, "", "unsupported")


class ParseTests(unittest.TestCase):
    def test_failure_line_with_file_and_line(self):
        failure = ci_xcresult.parse_failure("TVJourneys.swift:2185: Remote focus could not reach gearshape")
        self.assertEqual((failure.file, failure.line, failure.message), ("TVJourneys.swift", 2185, "Remote focus could not reach gearshape"))

    def test_failure_line_without_location_keeps_text(self):
        failure = ci_xcresult.parse_failure("Test crashed with signal kill.")
        self.assertEqual((failure.file, failure.line, failure.message), ("", 0, "Test crashed with signal kill."))

    def test_tree_yields_full_identifiers_results_and_messages(self):
        cases = {case.identifier: case for case in ci_xcresult.cases_from_tree(TREE)}
        failed = cases["ReelTVUITests/TVJourneys/testRemoteSettingsAccountsPrivacyQualityAndRemovalPersist"]
        self.assertEqual(failed.result, "Failed")
        self.assertEqual([(item.file, item.line) for item in failed.failures], [("TVJourneys.swift", 2185), ("TVJourneys.swift", 2186)])
        # Without an identifier URL the bundle comes from the enclosing node.
        self.assertEqual(cases["ReelTVUITests/TVJourneys/testRemoteSignInHomeDetailsAndBack"].result, "Passed")
        skipped = cases["ReelTVUITests/TVJourneys/testRemoteHomeScreenIconFocusLaunchesTheQAApp"]
        self.assertEqual((skipped.result, skipped.note), ("Skipped", "Test skipped - Needs the Home screen"))

    def test_legacy_failures_and_counts(self):
        cases, totals = ci_xcresult.cases_from_legacy(LEGACY)
        self.assertEqual(totals, {"total": 12, "Failed": 1, "Skipped": 2, "Passed": 9})
        self.assertEqual(cases[0].identifier, "RemoteSessionsTests/testRemoteCommand")
        self.assertEqual((cases[0].failures[0].file, cases[0].failures[0].line), ("RemoteSessionsTests.swift", 42))


class ReadTests(unittest.TestCase):
    def test_reads_the_test_results_api_first(self):
        tool = FakeTool({("get", "test-results", "tests"): Completed(0, json.dumps(TREE))})
        report = ci_xcresult.read("Run.xcresult", runner=tool)
        self.assertFalse(report.legacy)
        self.assertEqual((report.count("Passed"), report.count("Failed"), report.count("Skipped"), report.total()), (1, 1, 1, 3))
        self.assertEqual(tool.calls[0], ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", "Run.xcresult"])

    def test_falls_back_to_the_legacy_format(self):
        tool = FakeTool({
            ("get", "test-results"): Completed(64, "", "Unknown subcommand"),
            ("get", "--legacy"): Completed(0, json.dumps(LEGACY)),
        })
        report = ci_xcresult.read("Run.xcresult", runner=tool)
        self.assertTrue(report.legacy)
        self.assertEqual((report.total(), report.count("Failed")), (12, 1))
        self.assertIn("Unknown subcommand", report.problems[0])

    def test_unreadable_bundle_reports_zero_tests_instead_of_raising(self):
        report = ci_xcresult.read("Missing.xcresult", runner=FakeTool({}))
        self.assertEqual(report.total(), 0)
        self.assertTrue(report.problems)


class AttachmentTests(unittest.TestCase):
    def export(self, folder):
        def answer(command):
            destination = Path(command[command.index("--output-path") + 1])
            (destination / "A1.txt").write_text("\n".join("line %d" % number for number in range(1, 6)))
            (destination / "A2.png").write_bytes(b"\x89PNG\r\n\x1a\n\0\0")
            (destination / "manifest.json").write_text(json.dumps([{
                "testIdentifier": "TVJourneys/testRemoteSettingsAccountsPrivacyQualityAndRemovalPersist()",
                "attachments": [
                    {"exportedFileName": "A1.txt", "suggestedHumanReadableName": "Remote focus hierarchy", "isAssociatedWithFailure": False},
                    {"exportedFileName": "A2.png", "suggestedHumanReadableName": "Settings", "isAssociatedWithFailure": True},
                ],
            }]))
            return Completed(0)
        return ci_xcresult.export_attachments("Run.xcresult", folder, runner=FakeTool({("export", "attachments"): answer}))

    def test_manifest_rows_point_at_exported_files(self):
        with tempfile.TemporaryDirectory() as folder:
            rows, notes = self.export(Path(folder))
            self.assertEqual(notes, [])
            self.assertEqual([(row.name, row.path.name, row.failure) for row in rows],
                             [("Remote focus hierarchy", "A1.txt", False), ("Settings", "A2.png", True)])
            self.assertTrue(ci_xcresult.is_text(rows[0].path))
            self.assertFalse(ci_xcresult.is_text(rows[1].path))

    def test_render_prints_failures_attachments_and_annotations(self):
        with tempfile.TemporaryDirectory() as folder:
            report = ci_xcresult.Report(ci_xcresult.cases_from_tree(TREE))
            report.attachments, _ = self.export(Path(folder))
            text = ci_xcresult.render(report, max_lines=3, annotate=True, base=Path(folder),
                                      sources={"TVJourneys.swift": "apps/tvos/ReelTVUITests/TVJourneys.swift"})
        lines = text.splitlines()
        self.assertEqual(lines[0], "Tests: 1 passed, 1 failed, 1 skipped (3 run)")
        self.assertIn("FAILED ReelTVUITests/TVJourneys/testRemoteSettingsAccountsPrivacyQualityAndRemovalPersist", lines)
        self.assertIn("    TVJourneys.swift:2185: Remote focus could not reach gearshape", lines)
        self.assertIn("    Attachment: Remote focus hierarchy (first 3 of 5 lines)", lines)
        self.assertEqual([line for line in lines if line.startswith("    | ")], ["    | line 1", "    | line 2", "    | line 3"])
        self.assertIn("    Screenshot: A2.png (at failure)", lines)
        self.assertIn("SKIPPED ReelTVUITests/TVJourneys/testRemoteHomeScreenIconFocusLaunchesTheQAApp: Test skipped - Needs the Home screen", lines)
        self.assertIn("::error file=apps/tvos/ReelTVUITests/TVJourneys.swift,line=2185,"
                      "title=ReelTVUITests/TVJourneys/testRemoteSettingsAccountsPrivacyQualityAndRemovalPersist"
                      "::Remote focus could not reach gearshape", lines)

    def test_test_output_cannot_start_a_workflow_command(self):
        report = ci_xcresult.Report([ci_xcresult.Case("B/C/testX", "Failed", [ci_xcresult.Failure("::error::forged\n::stop-commands::x")])])
        for line in ci_xcresult.render(report).splitlines():
            self.assertFalse(line.startswith("::"), line)

    def test_annotation_escapes_properties_and_data(self):
        case = ci_xcresult.Case("B/C/testX", "Failed")
        line = ci_xcresult.annotation(case, ci_xcresult.Failure("50% done,\nnext", "C.swift", 9), {"C.swift": "apps/x/C.swift"})
        self.assertEqual(line, "::error file=apps/x/C.swift,line=9,title=B/C/testX::50%25 done,%0Anext")


class ProblemTests(unittest.TestCase):
    def report(self, *cases):
        return ci_xcresult.Report([ci_xcresult.Case(identifier, result) for identifier, result in cases])

    def test_zero_tests_is_a_failure(self):
        self.assertIn("No tests ran. Check the selected test identifiers.", ci_xcresult.problems(self.report(), ["ReelTests"]))

    def test_selection_that_ran_nothing_is_reported(self):
        reasons = ci_xcresult.problems(self.report(("ReelUITests/HomeCompactUITests/testA", "Passed")),
                                       ["ReelUITests/HomeCompactUITests", "ReelUITests/ReelUITests/testB"])
        self.assertEqual(reasons, ["Selected but not run: ReelUITests/ReelUITests/testB"])

    def test_class_selection_matches_its_methods_only(self):
        self.assertTrue(ci_xcresult.matches("B/TVJourneys", "B/TVJourneys/testA"))
        self.assertFalse(ci_xcresult.matches("B/TVJourneys", "B/TVJourneysExtra/testA"))

    def test_named_skips_fail_but_class_skips_do_not(self):
        report = self.report(("B/C/testA", "Skipped"), ("B/C/testB", "Passed"))
        self.assertEqual(ci_xcresult.problems(report, ["B/C"], named_methods=()), [])
        self.assertEqual(ci_xcresult.problems(report, ["B/C/testA"], named_methods=["B/C/testA"]),
                         ["Selected tests were skipped: B/C/testA"])

    def test_all_skipped_fails_when_skips_are_not_allowed(self):
        report = self.report(("B/C/testA", "Skipped"))
        self.assertEqual(ci_xcresult.problems(report, ["B/C"], allow_skips=True), [])
        self.assertEqual(ci_xcresult.problems(report, ["B/C"], allow_skips=False), ["Every selected test was skipped."])

    def test_failures_are_counted(self):
        self.assertEqual(ci_xcresult.problems(self.report(("B/C/testA", "Failed")), ["B"]), ["1 of 1 tests failed."])


if __name__ == "__main__":
    unittest.main()
