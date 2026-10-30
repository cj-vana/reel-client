import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

spec = importlib.util.spec_from_file_location("ci_changed_areas", Path(__file__).with_name("ci-changed-areas.py"))
ci_changed_areas = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci_changed_areas)
select = ci_changed_areas.select

NONE = {"apple": False, "web": False, "roku": False}
ALL = {"apple": True, "web": True, "roku": True}


class ChangedAreasTests(unittest.TestCase):
    def test_documentation_alone_selects_nothing(self):
        self.assertEqual(select(["README.md", "docs/platforms.md", "docs/screenshots/ipad.jpg", "apps/roku/README.md", "branding/mark.svg"]), NONE)

    def test_each_app_folder_selects_its_own_area(self):
        self.assertEqual(select(["apps/apple/Reel/Views/MainView.swift"]), {**NONE, "apple": True})
        self.assertEqual(select(["apps/tvos/ReelTV/TVDesign.swift"]), {**NONE, "apple": True})
        self.assertEqual(select(["apps/roku/channel/source/Core.brs"]), {**NONE, "roku": True})
        for path in ["apps/web/src/main.ts", "apps/desktop/src/store.mjs", "apps/tizen/src/adapter.js", "docker/compose.yml", "Dockerfile"]:
            self.assertEqual(select([path]), {**NONE, "web": True}, path)

    def test_paths_outside_every_area_select_everything(self):
        for path in ["scripts/ci-xcode.py", ".github/workflows/verify.yml", "LICENSE", "package.json", "new-folder/file.txt"]:
            self.assertEqual(select([path]), ALL, path)

    def test_a_prefix_must_end_at_a_folder_boundary(self):
        self.assertEqual(select(["apps/webview/index.ts"]), ALL)
        self.assertEqual(select(["Dockerfile.dev"]), ALL)

    def test_mixed_changes_select_the_union(self):
        self.assertEqual(select(["apps/web/src/main.ts", "apps/roku/manifest", "docs/features.md", ""]), {**NONE, "web": True, "roku": True})

    def test_command_line_prints_github_outputs(self):
        script = str(Path(__file__).with_name("ci-changed-areas.py"))
        run = subprocess.run([sys.executable, "-B", script], input="apps/roku/manifest\n", capture_output=True, text=True, check=True)
        self.assertEqual(run.stdout.splitlines(), ["apple=false", "web=false", "roku=true"])
        run = subprocess.run([sys.executable, "-B", script, "--all"], capture_output=True, text=True, check=True)
        self.assertEqual(run.stdout.splitlines(), ["apple=true", "web=true", "roku=true"])
        self.assertEqual(subprocess.run([sys.executable, "-B", script, "--bogus"], capture_output=True, text=True).returncode, 2)


if __name__ == "__main__":
    unittest.main()
