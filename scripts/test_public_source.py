"""Exercise the publication boundary against real temporary Git indexes."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "public_source", Path(__file__).with_name("check-public-source.py")
)
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class PublicationBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="reel-public-check-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        for name in ("LICENSE", "PRIVACY.md", "SECURITY.md", "THIRD_PARTY.md"):
            self.write(name, "Public document\n")

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def git(self, *arguments):
        return subprocess.check_output(
            ["git", "-C", str(self.root), *arguments], stderr=subprocess.STDOUT
        )

    def init(self):
        self.git("init", "--initial-branch=main")

    def errors(self):
        return CHECKER.collect_errors(self.root)

    def test_ignored_fixture_is_not_a_publication_candidate(self):
        self.init()
        self.write(".gitignore", "apps/apple/qa/artwork/\n")
        self.write("apps/apple/qa/artwork/generated.jpg", "Synthetic local fixture")
        self.assertEqual(self.errors(), [])

    def test_force_tracked_ignored_fixture_is_rejected(self):
        self.init()
        self.write(".gitignore", "apps/apple/qa/artwork/\n")
        self.write("apps/apple/qa/artwork/generated.jpg", "Synthetic local fixture")
        self.git("add", "--force", "apps/apple/qa/artwork/generated.jpg")
        self.assertTrue(any("Generated fixture" in item for item in self.errors()))

    def test_force_tracked_build_output_is_rejected(self):
        self.init()
        self.write(".gitignore", "build-ci/\n")
        self.write("build-ci/session.log", "Private runtime output")
        self.git("add", "--force", "build-ci/session.log")
        self.assertTrue(any("Runtime/build output" in item for item in self.errors()))

    def test_build_named_source_files_are_publishable(self):
        self.init()
        names = (
            "apps/roku/scripts/build-assets.py",
            "scripts/build-web.mjs",
            "docs/build-plan.md",
        )
        for name in names:
            self.write(name, "Public source\n")
            self.git("add", name)
        self.assertEqual(self.errors(), [])
        self.assertTrue({self.root / name for name in names}.issubset(
            set(CHECKER.publication_paths(self.root))
        ))

    def test_nested_build_directories_reject_even_source_extensions(self):
        self.init()
        self.write(".gitignore", "apps/roku/build-assets/\nother/build-stage/\n")
        for name in (
            "apps/roku/build-assets/output.png",
            "other/build-stage/source.py",
        ):
            self.write(name, "Generated output\n")
            self.git("add", "--force", name)
            self.assertTrue(any(
                "Runtime/build output" in item and name in item
                for item in self.errors()
            ))

    def test_path_classifier_distinguishes_source_names_from_directories(self):
        for name in (
            "apps/roku/scripts/build-assets.py",
            "scripts/build-web.mjs",
            "docs/build-plan.md",
        ):
            with self.subTest(source=name):
                self.assertFalse(CHECKER.artifact_path(Path(name)))
        for name in (
            "build-stage/source.py",
            "apps/roku/build-assets/output.png",
            "other/nested/build-result/readme.md",
            ".cache/source.py", "node_modules/source.py",
            "Reel.app/Reel", "reel.ipk", "run.xcresult/Info.plist",
        ):
            with self.subTest(artifact=name):
                self.assertTrue(CHECKER.artifact_path(Path(name)))

    def test_cli_accepts_source_but_rejects_force_tracked_build_directory(self):
        self.init()
        checker = self.write(
            "scripts/check-public-source.py", Path(CHECKER.__file__).read_text()
        )
        self.write("apps/roku/scripts/build-assets.py", "Public source\n")
        result = subprocess.run(
            [sys.executable, "-B", str(checker)], capture_output=True,
            text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Public packaging checks passed", result.stdout)
        self.write(".gitignore", "apps/roku/build-stage/\n")
        name = "apps/roku/build-stage/source.py"
        self.write(name, "Generated output\n")
        self.git("add", "--force", name)
        result = subprocess.run(
            [sys.executable, "-B", str(checker)], capture_output=True,
            text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Runtime/build output", result.stderr)
        self.assertIn(name, result.stderr)

    def test_force_tracked_platform_packages_are_rejected(self):
        self.init()
        self.write(".gitignore", "apps/web/dist-tv/\napps/web/webos-package/\n*.ipk\n*.app/\n*.dSYM/\n")
        for name in (
            "apps/web/dist-tv/reel.js", "apps/web/webos-package/reel.js",
            "reel.ipk", "reel.wgt", "reel.zip", "app.asar", "reel.dmg", "reel.msi", "reel.exe",
            "Reel.app/Reel", "Reel.dSYM/Contents/Info.plist",
        ):
            with self.subTest(path=name):
                path = self.write(name, "Generated output")
                self.git("add", "--force", name)
                self.assertTrue(any(
                    "Runtime/build output" in item and name in item
                    for item in self.errors()
                ))
                self.git("rm", "--cached", "--force", name)
                path.unlink()

    def test_key_and_local_environment_are_rejected(self):
        self.init()
        self.write("signing.p8", "Not an actual key")
        self.write(".env.local", "PLACEHOLDER=example")
        errors = self.errors()
        self.assertTrue(any("Signing/key material" in item for item in errors))
        self.assertTrue(any("Local environment" in item for item in errors))

    def test_symlink_is_rejected_without_following_target(self):
        self.init()
        (self.root / "external.txt").symlink_to("/does-not-exist/reel-private")
        self.assertTrue(any("Symlink needs explicit review" in item for item in self.errors()))

    def test_clean_archive_without_git_is_checkable(self):
        self.write("apps/apple/project.yml", "name: Reel\n")
        self.assertEqual(self.errors(), [])

    def test_unrelated_parent_git_does_not_hide_archive_files(self):
        self.init()
        self.write(".gitignore", "archive/\n")
        archive = self.root / "archive"
        for name in ("LICENSE", "PRIVACY.md", "SECURITY.md", "THIRD_PARTY.md"):
            self.write("archive/" + name, "Public document\n")
        self.write("archive/signing.p8", "Not an actual key")
        self.assertTrue(any("Signing/key material" in item for item in CHECKER.collect_errors(archive)))

    def test_personal_signing_team_is_rejected(self):
        self.init()
        self.write("apps/apple/project.yml", "DEVELOPMENT_TEAM: EXAMPLE123\n")
        self.assertTrue(any("Choose signing team locally" in item for item in self.errors()))

    def test_live_test_reads_require_explicit_opt_in(self):
        self.init()
        self.write("apps/apple/ReelTests/ReelTests.swift", """
final class Example {
    func testLivePreviewPlaysWithoutChangingHistory() throws {
        let account = try SecureAccount.read()
    }
}
""")
        self.assertTrue(any("Live test must opt in" in item for item in self.errors()))

    def test_content_scan_reports_location_without_repeating_credentials(self):
        self.init()
        secret = "gh" + "p_" + "AbcDef1234567890" * 3
        self.write("settings.json", '{"token":"' + secret + '"}')
        errors = self.errors()
        self.assertTrue(any("Credential token" in item and "settings.json:1" in item for item in errors))
        self.assertNotIn(secret, "\n".join(errors))

    def test_cli_rejects_credential_content_without_disclosing_it(self):
        self.init()
        checker = self.write("scripts/check-public-source.py", Path(CHECKER.__file__).read_text())
        secret = "gh" + "p_" + "AbcDef1234567890" * 3
        self.write("settings.json", '{"token":"' + secret + '"}')
        result = subprocess.run([sys.executable, "-B", str(checker)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Credential token", result.stderr)
        self.assertNotIn(secret, result.stdout + result.stderr)

    def test_content_scan_rejects_embedded_key_in_binary(self):
        self.init()
        marker = "-----BEGIN " + "PRIVATE KEY-----"
        self.write("image.png", "\0image\n" + marker + "\nfictional")
        self.assertTrue(any("Private key" in item for item in self.errors()))

    def test_personal_paths_are_rejected_on_mac_linux_and_windows(self):
        self.init()
        for prefix in ("/Users/", "/home/", "C:\\Users\\"):
            with self.subTest(prefix=prefix):
                self.write("config.txt", prefix + "private-person/Library/credentials")
                self.assertTrue(any("Personal home path" in item for item in self.errors()))

    def test_api_routes_and_explicit_example_home_are_allowed(self):
        self.init()
        self.write("api.txt", "/Users/Me/Items\n/Users/fixture-id/Images\n" + "/Users/" + "example/Library/Reel")
        self.assertEqual(self.errors(), [])

    def test_api_exception_cannot_hide_an_ordinary_home_directory(self):
        self.init()
        for prefix in ("/Users/", "/home/", "C:\\Users\\"):
            self.write("config.txt", prefix + "private-person/Items/preferences")
            self.assertTrue(any("Personal home path" in item for item in self.errors()))

    def test_personal_email_is_rejected_but_noreply_and_examples_are_allowed(self):
        self.init()
        self.write("contact.txt", "someone" + "@" + "private-host.test")
        self.assertTrue(any("Email address" in item for item in self.errors()))
        self.write("contact.txt", "1234+name@users.noreply.github.com\nuser@example.com\nuser@fixture.example\n")
        self.assertEqual(self.errors(), [])
        self.write("THIRD_PARTY_NOTICES.txt", "Copyright Author <author" + "@" + "vendor.test>")
        self.assertEqual(self.errors(), [])

    def test_private_network_address_is_rejected_outside_test_blocks(self):
        self.init()
        for address in ("192.168." + "50.10", "10.20." + "30.40", "172.20." + "0.5"):
            self.write("settings.json", '{"server":"http://' + address + ':8096"}')
            self.assertTrue(any("Private network address" in item for item in self.errors()), address)
        self.write("settings.json", "127.0.0.1 192.168.1.20 10.0.0.2 172.16.0.2 100.64.0.10 192.0.2.10 8.8.8.8 192.168.999.1 1.2.3\n")
        self.assertEqual(self.errors(), [])

    def test_machine_private_temp_path_is_rejected(self):
        self.init()
        self.write("receipt.json", '{"path":"' + "/private/" + 'tmp/private-run/result"}')
        self.assertTrue(any("Machine-local temporary path" in item for item in self.errors()))

    def test_high_entropy_embedded_credential_is_rejected(self):
        self.init()
        secret = "q8V3x4A1m7R0c6K9p2N5w3Y8"
        self.write("settings.json", '{"AccessToken":"' + secret + '"}')
        self.assertTrue(any("Possible embedded credential" in item for item in self.errors()))
        self.assertNotIn(secret, "\n".join(self.errors()))

    def test_obviously_synthetic_credential_and_source_key_are_allowed(self):
        self.init()
        self.write("fixture.json", '{"token":"synthetic-' + 'abcdefghijklmnopqrstuvwxyz0123456789"}')
        self.write("keys.py", 'token = "' + 'a' * 32 + '"')
        self.assertEqual(self.errors(), [])

    def test_local_account_state_files_are_rejected_when_force_tracked(self):
        self.init()
        self.write(".gitignore", "profile/\n")
        self.write("profile/accounts.json", "{}")
        self.git("add", "--force", "profile/accounts.json")
        self.assertTrue(any("Local account/browser state" in item for item in self.errors()))

    def test_tvos_and_probe_signing_teams_are_rejected(self):
        self.init()
        for name in ("apps/tvos/project.yml", "apps/apple/qa/probe/project.yml"):
            self.write(name, "DEVELOPMENT_TEAM: EXAMPLE123\n")
        errors = self.errors()
        self.assertEqual(sum("Choose signing team locally" in item for item in errors), 2)

    def test_missing_indexed_file_is_rejected(self):
        self.init()
        file = self.write("source.swift", "// Example\n")
        self.git("add", "source.swift")
        file.unlink()
        self.assertTrue(any("Missing publication file" in item for item in self.errors()))


if __name__ == "__main__":
    unittest.main()
